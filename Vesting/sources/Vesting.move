module Vesting::message {
    // use std::error;
    use std::string;
    use std::vector;
    
    // use aptos_framework::event;
    use aptos_framework::coin::{Self, Coin, MintCapability, FreezeCapability, BurnCapability};
    use aptos_framework::timestamp;
    use aptos_framework::signer;

    use MoonCoin::moon_coin::MoonCoin;
    
    const HUNDRED_PERCENT: u64             = 1000;
    const MIN_BURN_RATE: u64               = 500;
    const MAX_VESTING_SCHEDULE_STATES: u64 = 100;
   
    const FEE_COLLECTOR_1: address         = @FeeCollector1;
    const FEE_COLLECTOR_2: address         = @FeeCollector2;
    const DEPLOYER_ADDRESS: address        = @Vesting;

    struct User has key {
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
        totalTokens:  u128,
        totalClaimed: u128,
        totalBurned:  u128,
        totalFee:     u128,

        whitelistingAllowed: bool,
        feeRateStart: u64,
        feeRateEnd:   u64,

        roundName: string::String,
        startTime: u64,
        feeCollector1: address,
        feeCollector2: address,
        feeSplitPercentage: u64,
        firstUnlockPercentage: u64,
        vestingScheduleStates: vector<VestingScheduleState>,

        burnCap: BurnCapability<MoonCoin>,
        freezeCap: FreezeCapability<MoonCoin>,
        mintCap: MintCapability<MoonCoin>,
           
    }

    struct UserAddressesTotalTokens has drop {
        userAddresses: vector<address>,
        userTotalTokens: vector<u128>,
    }

    fun init_module(sender: signer) {
        let (burnCap, freezeCap, mintCap) = coin::initialize<MoonCoin>(&sender, string::utf8(b"MoonCoin"), string::utf8(b"MoonCoin"), 8, true);
        
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
        let firstUnlockPercentage = 100;
        move_to(&sender, AdminData {
            totalTokens: 0,
            totalClaimed: 0,
            totalBurned:0,
            totalFee: 0,
            
            feeRateStart: 1,
            feeRateEnd: 10,
            whitelistingAllowed: true,
            roundName: string::utf8(b"HelloWorld"),
            startTime: startTime,
            feeCollector1: FEE_COLLECTOR_1,
            feeCollector2: FEE_COLLECTOR_2,
            feeSplitPercentage: feeSplitPercentage,
            firstUnlockPercentage: firstUnlockPercentage,
            vestingScheduleStates: move vec,

            burnCap: burnCap,
            mintCap: mintCap,
            freezeCap: freezeCap,
        });
    }

    public entry fun prolong_linear_vesting_offset(account: &signer, _linearVestingOffset: u64) acquires AdminData {
        let linearUnlocksPassed: u64 = p_get_linear_unlocks_passed_default(0);
        let linearUnlocksCountCurrent: u64 = get_linear_unlocks_count();
        let linearVestingPeriod = get_linear_vesting_period();

        vector::push_back(
            &mut borrow_global_mut<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates,
            VestingScheduleState {
                timestamp: timestamp::now_seconds(),
                linearVestingOffset: _linearVestingOffset,
                linearVestingPeriod: linearVestingPeriod,
                linearUnlocksCount: (linearUnlocksCountCurrent - linearUnlocksPassed),
            }
        );

        p_validate_vesting_schedule();
    }

    // The user should call this to acquire User resource.
    public entry fun init(account: &signer) {
        move_to(account, User {
                totalTokens: 0,
                totalClaimedFromUnlocked: 0,
                firstUnlockTokens: 0,
                linearVestingOffset: 0,
                linearVestingPeriod: 0,
                linearUnlocksCount: 0,
                vestingScheduleUpdatedIndex: 0,
                totalExtraClaimed: 0,
                totalFee: 0,
            });
    }

    public entry fun whitelist(usersInfo: UserAddressesTotalTokens, last: bool) acquires AdminData, User {
        let totalTokens: u128 = 0;
        let len: u64 = vector::length(&usersInfo.userAddresses);
        let i: u64 = 0;
        let firstUnlockPercentage;
        {
            firstUnlockPercentage = (borrow_global<AdminData>(DEPLOYER_ADDRESS).firstUnlockPercentage as u128);
        };
        
        let userTotalTokens;
        let firstUnlockTokens;
        let linearVestingOffset = get_linear_vesting_offset();
        let linearVestingPeriod = get_linear_vesting_period();
        let linearUnlocksCount = get_linear_unlocks_count();
        while (i < len) { 
            userTotalTokens = *vector::borrow(&usersInfo.userTotalTokens, i);
            firstUnlockTokens = p_apply_percentage(userTotalTokens, firstUnlockPercentage);

            let userInfo = borrow_global_mut<User>(*vector::borrow(&usersInfo.userAddresses, i));
            userInfo.totalTokens = userTotalTokens;
            userInfo.firstUnlockTokens = firstUnlockTokens;
            userInfo.linearVestingOffset = linearVestingOffset;
            userInfo.linearVestingPeriod = linearVestingPeriod;
            userInfo.linearUnlocksCount = linearUnlocksCount;

            totalTokens = totalTokens + userTotalTokens;
        };

        let adminData = borrow_global_mut<AdminData>(DEPLOYER_ADDRESS);
        adminData.totalTokens = totalTokens;

        if (last) {
            adminData.whitelistingAllowed = false;
        }
    }

    public entry fun burn_user_tokens(account: &signer, userAddress: address, amount: u128) acquires User, AdminData {
        p_update_user_vesting_schedule(userAddress);
        let burned: u128 = p_update_user_total_tokens(userAddress, amount);

        let adminData = borrow_global_mut<AdminData>(DEPLOYER_ADDRESS);
        adminData.totalBurned = adminData.totalBurned + burned;
        
        let a = coin::withdraw<MoonCoin>(account, (burned as u64));
        coin::burn<MoonCoin>(a, &adminData.burnCap);
    }

    public entry fun claim(account: &signer) acquires User, AdminData {
        p_claim(account, 0);
    }

    public fun get_unlocked(userAddress: address): u128 acquires User, AdminData {
        p_update_user_vesting_schedule(userAddress);
        return p_get_unlocked(borrow_global_mut<User>(userAddress), 0)
    }

    public fun get_locked(userAddress: address): u128 acquires User, AdminData {
        let user = borrow_global_mut<User>(userAddress);
        return user.totalTokens - get_unlocked(userAddress)
    }

    public fun get_fee_rate() : u64 acquires AdminData {
        let linearUnlocksCount: u64 = get_linear_unlocks_count();
        let adminData = borrow_global<AdminData>(DEPLOYER_ADDRESS);
        let feeRateStart = adminData.feeRateStart;
        let feeRateEnd = adminData.feeRateEnd;

        if (adminData.feeRateStart == adminData.feeRateEnd || linearUnlocksCount == 0) {
            return adminData.feeRateEnd
        };

        let vestedTime = p_get_vested_time(0);
        let linearVestingOffset = get_linear_vesting_offset();
        let linearVestingPeriod = get_linear_vesting_period();
        let totalVestingTime = p_calculate_total_vesting_time(linearVestingOffset, linearVestingPeriod, linearUnlocksCount);

        let res: u64;
        if (vestedTime < totalVestingTime && totalVestingTime > 0) {
            let feeRate = feeRateStart;
            let feeRateDiff = feeRateStart - feeRateEnd;
            feeRate = feeRate - vestedTime * feeRateDiff / totalVestingTime;
            res = feeRate;
        } else {
            res = feeRateEnd;
        };
        return res
    }

    public fun get_claimable(userAddress: address): u128 acquires User, AdminData {
        let user = borrow_global_mut<User>(userAddress);
        let totalClaimedFromUnlocked = user.totalClaimedFromUnlocked;
        return get_unlocked(userAddress) - totalClaimedFromUnlocked
    }

    fun p_claim(account: &signer, extraClaimAmount: u128) acquires User, AdminData {
        let userAddress = signer::address_of(account);
        p_update_user_vesting_schedule(userAddress);

        let maxExtraClaimAmount = p_get_claimable_from_locked(userAddress);

        let baseClaimAmount = get_claimable(userAddress);
        let feeRate = get_fee_rate();
        
        let fee: u128 = 0;
        if (feeRate < HUNDRED_PERCENT) {
            fee = (extraClaimAmount * (feeRate as u128)) / ((HUNDRED_PERCENT as u128) - (feeRate as u128));
        };

        p_update_user_total_tokens(userAddress, extraClaimAmount + fee);
        
        let user = borrow_global_mut<User>(userAddress);
        user.totalClaimedFromUnlocked = user.totalClaimedFromUnlocked + baseClaimAmount;
        user.totalExtraClaimed        = user.totalExtraClaimed + extraClaimAmount;
        user.totalFee                 = user.totalFee + fee;

        let claimAmount = baseClaimAmount + extraClaimAmount;

        let adminData = borrow_global_mut<AdminData>(DEPLOYER_ADDRESS);
        adminData.totalClaimed = adminData.totalClaimed + claimAmount;
        adminData.totalFee     = adminData.totalFee + fee;

    }

    fun p_get_claimable_from_locked(userAddress: address): u128 acquires User, AdminData {
        return p_apply_percentage(get_locked(userAddress), ((HUNDRED_PERCENT - get_fee_rate()) as u128))
    }

    fun p_update_user_total_tokens(userAddress: address, amount: u128): u128 acquires User, AdminData {
        let unlocked: u128  = get_unlocked(userAddress);
        let user: &mut User = borrow_global_mut<User>(userAddress);
        let maxAmount: u128 = user.totalTokens - unlocked;
        if (amount > maxAmount) {
            amount = maxAmount;
        };

        if (amount == 0) {
            return 0
        };

        let linearUnlocksPassed = p_get_linear_unlocks_passed(user, 0);
        user.firstUnlockTokens = unlocked;
        user.linearVestingOffset = user.linearVestingOffset + (get_linear_vesting_period() * linearUnlocksPassed);
        user.linearUnlocksCount = user.linearUnlocksCount - linearUnlocksPassed;
        user.totalTokens = user.totalTokens - amount;

        return amount
    }

    fun p_update_user_vesting_schedule(userAddress: address) acquires User, AdminData {
        let user = borrow_global_mut<User>(userAddress);
        let userLastIndex = user.vestingScheduleUpdatedIndex;

        let length;
        {
            length = vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1;
        };

        while (userLastIndex < length) {
            userLastIndex = userLastIndex + 1;
            let state;
            {
                let states = &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates;
                state = vector::borrow(states, userLastIndex);
            };
            user.linearVestingOffset = state.linearVestingOffset;
            user.linearVestingPeriod = state.linearVestingPeriod;
            user.linearUnlocksCount = state.linearUnlocksCount;
            user.vestingScheduleUpdatedIndex = userLastIndex;
            user.firstUnlockTokens = p_get_unlocked(user, state.timestamp);
        }
    }

    fun p_get_unlocked(user: &mut User, timestampAt: u64): u128 acquires AdminData {
        let vestedTime: u64 = p_get_vested_time(timestampAt);
        if (vestedTime == 0) {
            return 0
        };
        
        let unlocked: u128;
        if (user.linearUnlocksCount > 0) {
            let firstUnlockTokens: u128 = user.firstUnlockTokens;
            let linearUnlocksTokens: u128 = user.totalTokens - firstUnlockTokens;
            let linearUnlocksPassed: u128 = (p_get_linear_unlocks_passed(user, timestampAt) as u128);
            unlocked = firstUnlockTokens + linearUnlocksTokens * linearUnlocksPassed / (user.linearUnlocksCount as u128);
        } else {
            unlocked = user.totalTokens;
        };

        if (unlocked > user.totalTokens) {
            unlocked = user.totalTokens;
        };

        return unlocked
    }
    
    fun p_calculate_total_vesting_time(linearVestingOffset: u64, linearVestingPeriod: u64, linearUnlocksCount: u64) : u64 {
        if (linearUnlocksCount == 0) {
            return 0
        };
        return linearVestingOffset + linearVestingPeriod * (linearUnlocksCount - 1)
    }

    fun p_validate_vesting_schedule() acquires AdminData {
        let linearVestingOffset = get_linear_vesting_offset();
        let linearVestingPeriod = get_linear_vesting_period();
        let linearUnlocksCount  = get_linear_unlocks_count();

        let previous: &VestingScheduleState = vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 2
        );

        let totalVestingTime: u64 = p_calculate_total_vesting_time(
            linearVestingOffset,
            linearVestingPeriod,
            linearUnlocksCount,
        );

        let totalVestingTimePrevious: u64 = p_calculate_total_vesting_time(
            previous.linearVestingOffset, 
            previous.linearVestingPeriod, 
            previous.linearUnlocksCount,
        );
        
        // require(totalVestingTime > totalVestingTimePrevious, "shortened");
        // require(totalVestingTime <= totalVestingTimePrevious + 52 weeks, "prolonged too much");
    }

    fun p_get_linear_unlocks_passed(user: &User, timestampAt: u64) : u64 acquires AdminData {
        let linearVestingPeriod;
        if (user.totalTokens > 0) {
            linearVestingPeriod = user.linearVestingPeriod;
        } else {
            linearVestingPeriod = get_linear_vesting_period();
        };

        if (linearVestingPeriod == 0) {
            if (user.totalTokens > 0) {
                return user.linearUnlocksCount
            } else {
                return get_linear_unlocks_count()
            }
        };

        let linearVestingOffset: u64;
        let linearUnlocksCount: u64;
        if (user.totalTokens > 0) { 
            linearVestingOffset = user.linearVestingOffset;
            linearUnlocksCount = user.linearUnlocksCount;
        } else {
            linearVestingOffset = get_linear_vesting_offset();
            linearUnlocksCount = get_linear_unlocks_count();
        };

        let vestedTime: u64 = p_get_vested_time(timestampAt);
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

    fun p_get_linear_unlocks_passed_default(timestampAt: u64) : u64 acquires AdminData {
        let linearVestingPeriod = get_linear_vesting_period();

        if (linearVestingPeriod == 0) {
            return get_linear_unlocks_count()
        };

        let linearVestingOffset: u64 = get_linear_vesting_offset();

        let vestedTime: u64 = p_get_vested_time(timestampAt);
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

    fun p_get_vested_time(timestampAt: u64) : u64 {
        let currentTime: u64;
        if (timestampAt > 0) {
            currentTime = timestampAt;
        } else {
            currentTime = timestamp::now_seconds();
        };
        currentTime
    }

    fun p_apply_percentage(value: u128, percentage: u128): u128 {
        let t = HUNDRED_PERCENT;

        value * percentage / (t as u128)
    }

    fun get_linear_vesting_period() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearVestingPeriod
    }

    fun get_linear_unlocks_count() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearUnlocksCount
    }

    fun get_linear_vesting_offset() : u64 acquires AdminData {
        vector::borrow(
            &borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates, 
            vector::length(&borrow_global<AdminData>(DEPLOYER_ADDRESS).vestingScheduleStates) - 1
        ).linearVestingOffset
    }

}
