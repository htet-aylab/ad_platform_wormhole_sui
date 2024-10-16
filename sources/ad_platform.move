module ad_platform::main {
    use sui::table::{Self, Table};
    use sui::event;
    use sui::clock::{Self, Clock};
    use wormhole::state::State as WormholeState;
    use wormhole::vaa;
    use wormhole::external_address::ExternalAddress;

    // Error codes
    const E_INVALID_CALLER: u64 = 1;
    const E_INVALID_CHAIN_ID: u64 = 2;
    const E_UNEXPECTED_RESULT_LENGTH: u64 = 3;
    const E_STALE_UPDATE: u64 = 4;
    const E_OBSOLETE_UPDATE: u64 = 6;
    const E_INVALID_VAA: u64 = 7;

    // Structs
    public struct AdPlatform has key {
        id: UID,
        owner: address,
        my_chain_id: u64,
        impressions: Table<u64, ChainImpressions>,
        foreign_chain_ids: vector<u64>,
    }

    public struct ChainImpressions has store {
        chain_id: u64,
        impressions_count: u64,
        campaign_id: u64,
        block_num: u64,
        block_time: u64,
    }

    // Events
    public struct ImpressionTracked has copy, drop {
        chain_id: u64,
        campaign_id: u64,
    }

    public struct ImpressionsUpdated has copy, drop {
        chain_id: u64,
        impressions_count: u64,
    }

    // Functions
    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        let mut ad_platform = AdPlatform {
            id: object::new(ctx),
            owner: sender,
            my_chain_id: 21, //replace with actual chain id
            impressions: table::new(ctx),
            foreign_chain_ids: vector::empty(),
        };
        
        table::add(&mut ad_platform.impressions, 1, ChainImpressions {
            chain_id: 1,
            impressions_count: 0,
            campaign_id: 0,
            block_num: 0,
            block_time: 0,
        });

        transfer::share_object(ad_platform);
    }

    public entry fun update_registration(
        platform: &mut AdPlatform,
        chain_id: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == platform.owner, E_INVALID_CALLER);
        
        if (!table::contains(&platform.impressions, chain_id)) {
            vector::push_back(&mut platform.foreign_chain_ids, chain_id);
            table::add(&mut platform.impressions, chain_id, ChainImpressions {
                chain_id,
                impressions_count: 0,
                campaign_id: 0,
                block_num: 0,
                block_time: 0,
            });
        };
    }

    public entry fun track_ad_impression(
        platform: &mut AdPlatform,
        campaign_id: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let impressions = table::borrow_mut(&mut platform.impressions, platform.my_chain_id);
        impressions.impressions_count = impressions.impressions_count + 1;
        impressions.campaign_id = campaign_id;
        impressions.block_num = tx_context::epoch(ctx);
        impressions.block_time = clock::timestamp_ms(clock) / 1000; // Convert to seconds

        event::emit(ImpressionTracked {
            chain_id: platform.my_chain_id,
            campaign_id,
        });
    }

    public fun get_impressions_count(platform: &AdPlatform): u64 {
        let impressions = table::borrow(&platform.impressions, platform.my_chain_id);
        impressions.impressions_count
    }

    public fun get_campaign_id(platform: &AdPlatform): u64 {
        let impressions = table::borrow(&platform.impressions, platform.my_chain_id);
        impressions.campaign_id
    }

    public entry fun update_impressions(
        platform: &mut AdPlatform,
        wormhole_state: &WormholeState,
        vaa_bytes: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Verify and parse the VAA, immediately extracting the necessary information
        let (emitter_chain, emitter_address, payload) = {
            let vaa = vaa::parse_and_verify(wormhole_state, vaa_bytes, clock);
            let emitter_chain = vaa::emitter_chain(&vaa);
            let emitter_address = vaa::emitter_address(&vaa);
            let payload = vaa::payload(&vaa);
            vaa::destroy(vaa); // Destroy the VAA struct
            (emitter_chain, emitter_address, payload)
        };
        
        // Verify the emitter is a trusted source
        assert!(is_trusted_emitter(emitter_chain, emitter_address), E_INVALID_VAA);

        let (foreign_chain_ids, foreign_impressions, foreign_block_nums, foreign_block_times) = parse_payload(payload);
        
        assert!(vector::length(&foreign_chain_ids) == vector::length(&platform.foreign_chain_ids), E_UNEXPECTED_RESULT_LENGTH);
        
        let mut i = 0;
        while (i < vector::length(&foreign_chain_ids)) {
            let chain_id = *vector::borrow(&foreign_chain_ids, i);
            let impressions_count = *vector::borrow(&foreign_impressions, i);
            let block_num = *vector::borrow(&foreign_block_nums, i);
            let block_time = *vector::borrow(&foreign_block_times, i);

            assert!(table::contains(&platform.impressions, chain_id), E_INVALID_CHAIN_ID);
            
            let foreign_impressions = table::borrow_mut(&mut platform.impressions, chain_id);
            assert!(block_num > foreign_impressions.block_num, E_OBSOLETE_UPDATE);

            let current_time = clock::timestamp_ms(clock) / 1000; // Convert to seconds
            assert!(current_time > block_time - 300, E_STALE_UPDATE); // 5 minutes tolerance

            foreign_impressions.impressions_count = impressions_count;
            foreign_impressions.block_num = block_num;
            foreign_impressions.block_time = block_time;

            event::emit(ImpressionsUpdated {
                chain_id,
                impressions_count,
            });

            i = i + 1;
        };

        // Increment local impressions
        let local_impressions = table::borrow_mut(&mut platform.impressions, platform.my_chain_id);
        local_impressions.impressions_count = local_impressions.impressions_count + 1;
        local_impressions.block_num = tx_context::epoch(ctx);
        local_impressions.block_time = clock::timestamp_ms(clock) / 1000; // Convert to seconds
    }

    // Helper function to get all foreign chain IDs
    public fun get_foreign_chain_ids(platform: &AdPlatform): vector<u64> {
        platform.foreign_chain_ids
    }

    // Helper function to check if the emitter is trusted
    fun is_trusted_emitter(_emitter_chain: u16, _emitter_address: ExternalAddress): bool {
        // Implement your logic to verify trusted emitters
        // This is a placeholder and should be replaced with actual verification logic
        true
    }

    // Helper function to parse the payload from Wormhole VAA
    fun parse_payload(_payload: vector<u8>): (vector<u64>, vector<u64>, vector<u64>, vector<u64>) {
        // Implement parsing logic here
        // This is a placeholder and should be replaced with actual parsing logic
        let foreign_chain_ids = vector::empty();
        let foreign_impressions = vector::empty();
        let foreign_block_nums = vector::empty();
        let foreign_block_times = vector::empty();

        // Parse the payload and populate the vectors
        // ... (implement your parsing logic here)

        (foreign_chain_ids, foreign_impressions, foreign_block_nums, foreign_block_times)
    }
}
