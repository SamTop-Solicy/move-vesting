module Vesting::message {
    // use std::error;
    // use std::signer;
    use std::string;
    use std::vector;
    
    // use aptos_framework::account;
    // use aptos_framework::event;
    // use aptos_framework::coin::{Self, Coin, MintCapability, FreezeCapability, BurnCapability};
    use aptos_framework::timestamp;
    
    const HUNDRED_PERCENT: u64             = 1000;
    const MIN_BURN_RATE: u64               = 500;
    const MAX_VESTING_SCHEDULE_STATES: u64 = 100;
   
    const FEE_COLLECTOR_1: address         = @FeeCollector1;
    const FEE_COLLECTOR_2: address         = @FeeCollector2;
    const DEPLOYER_ADDRESS: address        = @Vesting;

    struct User {
        totalTokens: u128,
        totalClaimedFromUnlocked: u128,
        firstUnlockTokens: u128,
        linearVestingOffset: u64,
        linearVestingPeriod: u64,
        linearUnlocksCount: u64,
        vestingScheduleUpdatedIndex: u64,
        totalExtraClaimed: u128,
        totalFee: u128,
    }

    struct VestingScheduleState has store {
        timestamp: u64,
        linearVestingOffset: u64,
        linearVestingPeriod: u64,
        linearUnlocksCount: u64,
    }

    struct AdminData has key {
        roundName: string::String,
        startTime: u64,
        feeCollector1: address,
        feeCollector2: address,
        feeSplitPercentage: u64,
        firstUnlockPercentage: u64,
        vestingScheduleStates: vector<VestingScheduleState>,
    }

    fun init_module(sender: &signer) {
        let vec = vector::empty<VestingScheduleState>();
        let startTime = 123123;
        let linearVestingOffset = 1000;
        let linearVestingPeriod = 1000;
        let linearUnlocksCount = 5;

        vector::push_back(&mut vec, VestingScheduleState {
            timestamp: startTime,
            linearVestingOffset: linearVestingOffset,
            linearVestingPeriod: linearVestingPeriod,
            linearUnlocksCount: linearUnlocksCount,
        });
        
        let feeSplitPercentage = 100;
        let feeUnloclPercentage = 100;
        move_to(sender, AdminData {
            roundName: string::utf8(b"HelloWorld"),
            startTime: startTime,
            feeCollector1: FEE_COLLECTOR_1,
            feeCollector2: FEE_COLLECTOR_2,
            feeSplitPercentage: feeSplitPercentage,
            firstUnlockPercentage: feeUnloclPercentage,
            vestingScheduleStates: move vec,
        });
    }

    public entry fun prolongLinearVestingOffset(account: &signer, _linearVestingOffset: u64) acquires AdminData {
        let linearUnlocksPassed: u64 = p_getLinearUnlocksPassedDefault(0);
        let linearUnlocksCountCurrent: u64 = getLinearUnlocksCount();
        let linearVestingPeriod = getLinearVestingPeriod();

        vector::push_back(
            &mut borrow_global_mut<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates,
            VestingScheduleState {
                timestamp: timestamp::now_seconds(),
                linearVestingOffset: _linearVestingOffset,
                linearVestingPeriod: linearVestingPeriod,
                linearUnlocksCount: (linearUnlocksCountCurrent - linearUnlocksPassed),
            }
        )
    }
    
    fun p_calculateTotalVestingTime(linearVestingOffset: u64, linearVestingPeriod: u64, linearUnlocksCount: u64) : u64 {
        if (linearUnlocksCount == 0) {
            return 0
        };
        return linearVestingOffset + linearVestingPeriod * (linearUnlocksCount - 1)
    }

    fun p_validateVestingSchedule() acquires AdminData {
        let linearVestingOffset = getLinearVestingOffset();
        let linearVestingPeriod = getLinearVestingPeriod();
        let linearUnlocksCount  = getLinearUnlocksCount();

        let previous: &VestingScheduleState = vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 2
        );

        let totalVestingTime: u64 = p_calculateTotalVestingTime(
            linearVestingOffset,
            linearVestingPeriod,
            linearUnlocksCount,
        );

        let totalVestingTimePrevious: u64 = p_calculateTotalVestingTime(
            previous.linearVestingOffset, 
            previous.linearVestingPeriod, 
            previous.linearUnlocksCount,
        );
        
        // require(totalVestingTime > totalVestingTimePrevious, "shortened");
        // require(totalVestingTime <= totalVestingTimePrevious + 52 weeks, "prolonged too much");
    }

    fun p_getLinearUnlocksPassed(user: &User, timestampAt: u64) : u64 acquires AdminData {
        let linearVestingPeriod;
        if (user.totalTokens > 0) {
            linearVestingPeriod = user.linearVestingPeriod;
        } else {
            linearVestingPeriod = getLinearVestingPeriod();
        };

        if (linearVestingPeriod == 0) {
            if (user.totalTokens > 0) {
                return user.linearUnlocksCount
            } else {
                return getLinearUnlocksCount()
            }
        };

        let linearVestingOffset: u64;
        let linearUnlocksCount: u64;
        if (user.totalTokens > 0) { 
            linearVestingOffset = user.linearVestingOffset;
            linearUnlocksCount = user.linearUnlocksCount;
        } else {
            linearVestingOffset = getLinearVestingOffset();
            linearUnlocksCount = getLinearUnlocksCount();
        };

        let vestedTime: u64 = p_getVestedTime(timestampAt);
        let linearVestedTime: u64 = 0;
        if (vestedTime > linearVestingOffset) {
            linearVestedTime = vestedTime - linearVestingOffset;
        };

        let linearUnlocksPassed: u64 = linearVestedTime / linearVestingPeriod;
        if(linearVestedTime > 0) {
            linearUnlocksPassed = linearUnlocksPassed + 1;
        };

        if(linearUnlocksPassed > linearUnlocksCount) {
            linearUnlocksPassed = linearUnlocksCount;
        };

        return linearUnlocksPassed
    }

    fun p_getLinearUnlocksPassedDefault(timestampAt: u64) : u64 acquires AdminData {
        let linearVestingPeriod = getLinearVestingPeriod();

        if (linearVestingPeriod == 0) {
            return getLinearUnlocksCount()
        };

        let linearVestingOffset: u64 = getLinearVestingOffset();

        let vestedTime: u64 = p_getVestedTime(timestampAt);
        let linearVestedTime: u64 = 0;
        if (vestedTime > linearVestingOffset) {
            linearVestedTime = vestedTime - linearVestingOffset;
        };

        let linearUnlocksPassed: u64 = linearVestedTime / linearVestingPeriod;
        if(linearVestedTime > 0) {
            linearUnlocksPassed = linearUnlocksPassed + 1;
        };

        return linearUnlocksPassed
    }

    fun p_getVestedTime(timestampAt: u64) : u64 {
        let currentTime: u64;
        if (timestampAt > 0) {
            currentTime = timestampAt;
        } else {
            currentTime = timestamp::now_seconds();
        };
        currentTime
    }

    fun getLinearVestingPeriod() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearVestingPeriod
    }

    fun getLinearUnlocksCount() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearUnlocksCount
    }

    fun getLinearVestingOffset() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearVestingOffset
    }

}
