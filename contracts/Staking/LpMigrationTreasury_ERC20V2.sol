// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../Common/LocatorBasedProxyV2.sol";
import "../Math/Math.sol";
// import "../ERC20/IERC20.sol";
import "../ERC20/SafeERC20.sol";
import "../Common/ReentrancyGuard.sol";
import "../Libs/TransferHelper.sol";
import "./IStakingBoostController.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IRewardComptroller {
    function updateRewardAndBalance(address account, bool sync_too) external;
    function collectRewardFor(address rewardee, address destination_address) external returns (uint256[] memory);
    function sync() external;
}

abstract contract LpMigrationTreasury_ERC20 is ContextUpgradeable, ReentrancyGuardUpgradeable, LocatorBasedProxyV2 {
    // using SafeERC20 for IERC20;

    // Constant for various precisions
    uint256 public constant MULTIPLIER_PRECISION = 1e18;

    /* ========== CONFIG VARIABLES ========== */

    IStakingBoostController public boost_controller;
    IRewardComptroller public reward_comptroller;

    address public lp_token_address;
    uint256 private lp_token_precision;

    uint256 public closed_at; // after closed, no stake/add/extend allowed
    uint256 public lock_end; // minimum lock end time that stakes should be locked

    // Admin booleans for emergencies, migrations, and overrides
    bool public stakesUnlocked; // Release locked stakes in case of emergency
    bool public migrationsOn; // Used for migrations. Prevents new stakes, but allows LP and reward withdrawals
    bool public withdrawalsPaused; // For emergencies
    bool public stakingPaused; // For emergencies
    bool public updateStakingPaused; // For emergencies
    bool public rewardsCollectionPaused; // For emergencies

    /* ========== STATE VARIABLES ========== */

    uint256 public usdkPerLPStored;

    // Stake tracking
    mapping(address => LockedStake) public lockedStakes;
    mapping(address => uint256) public _locked_liquidity;
    // mapping(address => VeKromeMultiplier) public veMultipliers;
    uint256 internal _total_liquidity_locked;

    // Greylists
    mapping(address => bool) public greylist;

    // List of valid migrators (set by governance)
    mapping(address => bool) public valid_migrators;

    address public collect_reward_delegator;

    StakeMigration[] public stakes_to_migrate_array;
    uint256 public index_to_migrate;
    uint256 public migrated_liquidity;

    mapping(address => uint256) public migrated_user_liquidity;

    uint256 lpRewardDueTimestamp;
    uint256 totalLpWeightSynced;
    uint256 totalLpWeightSyncTimestamp;

    mapping(address => uint256) userLpWeightSynced;
    mapping(address => uint256) userLpWeightSyncTimestamp;

    LpReward[] public totalLpRewards;

    /* ========== STRUCTS ========== */

    struct VeKromeMultiplier {
        uint256 multiplier;
        uint256 dslope;
        uint256 staytime;
        uint256 timestamp;
    }

    // Struct for the stake
    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }

    struct StakeMigration {
        address account;
        bytes32 kek_id;
    }

    struct LpReward {
        address token_address;
        uint256 amount;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == local_manager_address, "Not owner or timelock");
        _;
    }

    modifier updateRewardAndBalance(address account, bool sync_too) {
        _require_reward_comptroller();
        syncInternal();
        syncUserLpWeight(account);
        if (_locked_liquidity[account] > 0) {
            reward_comptroller.updateRewardAndBalance(account, sync_too);
        }
        _;
    }

    function _isMigrating() internal view {
        require(migrationsOn == true, "Not in migration");
    }

    /* ========== INITIALIZER ========== */

    function __LpMigrationTreasury_init(
        address _locator_address,
        address _staking_boost_controller,
        address _staking_token,
        uint256 _closed_at,
        uint256 _lockend
    ) internal onlyInitializing {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator_address);
        __LpMigrationTreasury_init_unchained(_staking_boost_controller, _staking_token, _closed_at, _lockend);
    }

    function __LpMigrationTreasury_init_unchained(
        address _staking_boost_controller,
        address _staking_token,
        uint256 _closed_at,
        uint256 _lockend
    ) internal onlyInitializing {
        boost_controller = IStakingBoostController(_staking_boost_controller);
        lp_token_address = _staking_token;
        lp_token_precision = 10 ** IERC20Decimals(_staking_token).decimals();

        closed_at = _closed_at;
        lock_end = _lockend;

        // Other booleans
        stakesUnlocked = false;

        // withdrawal is puased for default options.
        // allow withdrawal on emmergency situation before migrated
        withdrawalsPaused = true;
    }

    /* ============ ABSTRACT =========== */

    function usdkPerLPToken() public virtual view returns (uint256);
    function getVirtualPrice() public virtual view returns (uint256);

    /* ============= VIEWS ============= */

    // ------ LIQUIDITY AND WEIGHTS ------

    // ------ LOCK RELATED ------

    // All the locked stakes for a given account
    function lockedStakesOf(address account) external view returns (LockedStake[] memory stakes) {
        if (_locked_liquidity[account] > migrated_user_liquidity[account]) {
            stakes = new LockedStake[](1);
            stakes[0] = lockedStakes[account];
        }
    }

    function lockedStakesOfRaw(address account) external view returns (LockedStake[] memory stakes) {
        if (_locked_liquidity[account] > 0) {
            stakes = new LockedStake[](1);
            stakes[0] = lockedStakes[account];
        }
    }

    // // All the locked stakes for a given account [old-school method]
    // function lockedStakesOfMultiArr(address account) external view returns (
    //     bytes32[] memory kek_ids,
    //     uint256[] memory start_timestamps,]a
    //     uint256[] memory liquidities,
    //     uint256[] memory ending_timestamps,
    //     uint256[] memory lock_multipliers
    // ) {
    //     for (uint256 i = 0; i < lockedStakes[account].length; i++){ 
    //         LockedStake memory thisStake = lockedStakes[account][i];
    //         kek_ids[i] = thisStake.kek_id;
    //         start_timestamps[i] = thisStake.start_timestamp;
    //         liquidities[i] = thisStake.liquidity;
    //         ending_timestamps[i] = thisStake.ending_timestamp;
    //         lock_multipliers[i] = thisStake.lock_multiplier;
    //     }
    // }

    // Returns the length of the locked stakes for a given account
    function lockedStakesOfLength(address account) external view returns (uint256) {
        return _locked_liquidity[account] > migrated_user_liquidity[account] ? 1 : 0;
    }

    function lockedStakesOfLengthRaw(address account) external view returns (uint256) {
        return _locked_liquidity[account] > 0 ? 1 : 0;
    }

    function veKromeMultiplier(address account) external view returns (uint256 ve_multiplier, uint256 slope, uint256 stay_time) {
        return userStakedUsdk(account) > 0 ? boost_controller.veKromeMultiplier(account, userStakedUsdk(account)) : (0, 0, 0);
    }

    // ------ USDK RELATED ------

    function usdkForStake(uint256 liquidity) internal view returns (uint256) {
        return (usdkPerLPStored * liquidity) / lp_token_precision;
    }

    function userStakedUsdk(address account) public view returns (uint256) {
        return _locked_liquidity[account] > migrated_user_liquidity[account] ? usdkForStake(_locked_liquidity[account]) : 0;
    }

    // ------ LIQUIDITY RELATED ------

    // Total locked liquidity / LP tokens
    function totalLiquidityLocked() external view returns (uint256) {
        return _total_liquidity_locked - migrated_liquidity;
    }

    // Total locked liquidity / LP tokens
    function totalLiquidityLockedRaw() external view returns (uint256) {
        return _total_liquidity_locked;
    }

    // User locked liquidity / LP tokens
    function lockedLiquidityOf(address account) external view returns (uint256) {
        return _locked_liquidity[account] - migrated_user_liquidity[account];
    }

    function lockedLiquidityOfRaw(address account) external view returns (uint256) {
        return _locked_liquidity[account];
    }

    function getStakesToMigrateCount() external view returns (uint256) {
        return stakes_to_migrate_array.length - index_to_migrate;
    }

    function getStakesToMigrate(uint256 length) external view returns (address[] memory stakers, LockedStake[] memory stakes) {
        uint256 queue_length = stakes_to_migrate_array.length;
        uint256 start_idx = index_to_migrate;
        uint256 result_length = queue_length > start_idx ? Math.min(queue_length - start_idx, length) : 0;

        stakers = new address[](result_length);
        stakes = new LockedStake[](result_length);

        for (uint256 i = 0; i < result_length; i++) {
            StakeMigration memory migration = stakes_to_migrate_array[start_idx + i];
            stakers[i] = migration.account;
            stakes[i] = lockedStakes[migration.account];
            require(lockedStakes[migration.account].kek_id == migration.kek_id, "invalid kek_id");
        }
    }

    function getMigrationsLength() external view returns (uint256) {
        return stakes_to_migrate_array.length;
    }

    function getMigrations(uint256 start_idx, uint256 length) external view returns (StakeMigration[] memory migrations) {
        uint256 queue_length = stakes_to_migrate_array.length;
        uint256 result_length = queue_length > start_idx ? Math.min(queue_length - start_idx, length) : 0;

        migrations = new StakeMigration[](result_length);
        for (uint256 i = 0; i < result_length; i++) {
            migrations[i] = stakes_to_migrate_array[start_idx + i];
        }
    }

    function lpWeightFor(address account) public view returns (uint256 userWeight, uint256 totalWeight) {
        totalWeight = totalLpWeightSynced;
        userWeight = userLpWeightSynced[account];

        uint256 timeCriteria = lpRewardDueTimestamp > 0 ? Math.min(lpRewardDueTimestamp, block.timestamp) : block.timestamp;

        if (_total_liquidity_locked > 0 && totalLpWeightSyncTimestamp > 0) {
            totalWeight += _total_liquidity_locked * (timeCriteria - totalLpWeightSyncTimestamp);
        }
        if (_locked_liquidity[account] > 0 && userLpWeightSyncTimestamp[account] > 0) {
            userWeight += _locked_liquidity[account] * (timeCriteria - userLpWeightSyncTimestamp[account]);
        }
    }

    function lpRewardsFor(address account) public view returns (LpReward[] memory rewards) {
        rewards = new LpReward[](totalLpRewards.length);

        (uint256 userWeight, uint256 totalWeight) = lpWeightFor(account);

        for (uint256 i = 0; i < rewards.length; i++) {
            rewards[i] = LpReward({
                token_address: totalLpRewards[i].token_address,
                amount: totalWeight > 0 ? totalLpRewards[i].amount * userWeight / totalWeight : 0
            });
        }
    }

    /* =============== MUTATIVE FUNCTIONS =============== */

    // ------ STAKING ------

    function _getStake(address staker_address, bytes32 kek_id) internal view returns (LockedStake memory locked_stake, uint256 arr_idx) {
        require(lockedStakes[staker_address].kek_id == kek_id, "Stake not found");

        locked_stake = lockedStakes[staker_address];
        arr_idx = 0;
    }

    // Extends the lock of an existing stake
    // function extendLockTime(bytes32 kek_id, uint256 secs) updateRewardAndBalance(msg.sender, true) public {
    //     require(stakingPaused == false && updateStakingPaused == false && migrationsOn == false, "Staking paused or in migration");
    //     require(block.timestamp < closed_at, "closed");
    //     require(greylist[msg.sender] == false, "Address has been greylisted");

    //     require(secs > 0, "Must be in the future");
    //     require(block.timestamp + secs >= lock_end, "too short lock time");
    //     require(migrated_user_liquidity[msg.sender] == 0, "already migrated");

    //     // Get the stake and its index
    //     (LockedStake memory thisStake,) = _getStake(msg.sender, kek_id);

    //     // Check 
    //     require(secs >= thisStake.ending_timestamp - thisStake.start_timestamp, "Cannot shorten lock time");

    //     uint256 new_ending_ts = block.timestamp + secs;

    //     // Calculate the new seconds
    //     uint256 new_secs = new_ending_ts - block.timestamp;

    //     // Update the stake
    //     lockedStakes[msg.sender] = LockedStake(
    //         kek_id,
    //         block.timestamp,
    //         thisStake.liquidity,
    //         new_ending_ts,
    //         boost_controller.lockMultiplier(new_secs)
    //     );

    //     // Need to call to update the combined weights
    //     reward_comptroller.updateRewardAndBalance(msg.sender, false);
    // }


    // Add additional LPs to an existing locked stake
    function _lockAdditional(bytes32 kek_id, uint256 addl_liq) updateRewardAndBalance(msg.sender, true) internal {
        require(stakingPaused == false && updateStakingPaused == false && migrationsOn == false, "Staking paused or in migration");
        require(block.timestamp < closed_at, "closed");
        require(greylist[msg.sender] == false, "Address has been greylisted");
        require(migrated_user_liquidity[msg.sender] == 0, "already migrated");

        // Checks
        require(addl_liq > 0, "Must be nonzero");

        // Get the stake and its index
        (LockedStake memory thisStake, ) = _getStake(msg.sender, kek_id);

        // Calculate the new amount
        uint256 new_amt = thisStake.liquidity + addl_liq;

        // Pull the tokens from the sender
        TransferHelper.safeTransferFrom(lp_token_address, msg.sender, address(this), addl_liq);

        // Update the stake
        lockedStakes[msg.sender] = LockedStake(
            kek_id,
            thisStake.start_timestamp,
            new_amt,
            thisStake.ending_timestamp,
            thisStake.lock_multiplier
        );

        // Update liquidities
        _total_liquidity_locked += addl_liq;
        _locked_liquidity[msg.sender] += addl_liq;

        _onAfterStake(msg.sender, addl_liq);

        // Need to call to update the combined weights
        reward_comptroller.updateRewardAndBalance(msg.sender, false);
    }

    // Two different stake functions are needed because of delegateCall and msg.sender issues (important for migration)
    function stakeLocked(uint256 liquidity) nonReentrant external {
        // require(block.timestamp + secs >= lock_end, "too short lock time");

        if (_locked_liquidity[msg.sender] == 0) {
            _stakeLocked(msg.sender, msg.sender, liquidity, lock_end - block.timestamp, block.timestamp);
        } else {
            _lockAdditional(lockedStakes[msg.sender].kek_id, liquidity);
        }
    }

    // function _stakeLockedInternalLogic(
    //     address source_address,
    //     uint256 liquidity
    // ) internal virtual;

    // If this were not internal, and source_address had an infinite approve, this could be exploitable
    // (pull funds from source_address and stake for an arbitrary staker_address)
    function _stakeLocked(
        address staker_address,
        address source_address,
        uint256 liquidity,
        uint256 secs,
        uint256 start_timestamp
    ) internal updateRewardAndBalance(staker_address, true) {
        require(block.timestamp < closed_at, "closed");
        require((stakingPaused == false && migrationsOn == false) || valid_migrators[msg.sender] == true, "Staking paused or in migration");
        require(greylist[staker_address] == false, "Address has been greylisted");
        require(lockedStakes[staker_address].liquidity == 0, "Already have stake. use add or extend");
        require(migrated_user_liquidity[staker_address] == 0, "already migrated");

        require(liquidity > 0, "Invalid liquidity");

        // Get the lock multiplier and kek_id
        uint256 lock_multiplier = secs > 0 ? boost_controller.lockMultiplier(secs) : MULTIPLIER_PRECISION;
        bytes32 kek_id = keccak256(abi.encodePacked(staker_address, start_timestamp, liquidity, _locked_liquidity[staker_address]));

        stakes_to_migrate_array.push(StakeMigration(staker_address, kek_id));

        // Pull in the required token(s)
        // Varies per farm
        // IERC20(lp_token_address).safeTransferFrom(source_address, address(this), liquidity);
        TransferHelper.safeTransferFrom(lp_token_address, source_address, address(this), liquidity);

        // Create the locked stake
        lockedStakes[staker_address] = LockedStake(
            kek_id,
            start_timestamp,
            liquidity,
            start_timestamp + secs,
            lock_multiplier
        );

        // Update liquidities
        _total_liquidity_locked += liquidity;
        _locked_liquidity[staker_address] += liquidity;

        _onAfterStake(staker_address, liquidity);

        // Need to call again to make sure everything is correct
        reward_comptroller.updateRewardAndBalance(staker_address, false);

        emit StakeLocked(staker_address, liquidity, secs, kek_id, source_address);
    }

    // ------ WITHDRAWING ------

    // Two different withdrawLocked functions are needed because of delegateCall and msg.sender issues (important for migration)
    function withdrawLocked() nonReentrant external {
        require(withdrawalsPaused == false, "Withdrawals paused");
        _withdrawLocked(msg.sender, msg.sender, lockedStakes[msg.sender].kek_id);
    }

    function withdrawLockedFor(address account) nonReentrant external {
        require(collect_reward_delegator != address(0) && collect_reward_delegator == msg.sender, "Only reward collecting delegator can perform this action");
        require(withdrawalsPaused == false, "Withdrawals paused");
        _withdrawLocked(account, account, lockedStakes[msg.sender].kek_id);
    }

    // No withdrawer == msg.sender check needed since this is only internally callable and the checks are done in the wrapper
    // functions like migrator_withdraw_locked() and withdrawLocked()
    function _withdrawLocked(
        address staker_address,
        address destination_address,
        bytes32 kek_id
    ) internal updateRewardAndBalance(staker_address, true) {
        _require_reward_comptroller();
        require(migrated_user_liquidity[staker_address] == 0, "already migrated");

        // Get the stake and its index
        (LockedStake memory thisStake,) = _getStake(staker_address, kek_id);
        require(block.timestamp >= thisStake.ending_timestamp || stakesUnlocked == true || valid_migrators[msg.sender] == true, "Stake is still locked!");
        uint256 liquidity = thisStake.liquidity;

        if (liquidity > 0) {
            _onBeforeUnstake(staker_address, liquidity);

            // Update liquidities
            _total_liquidity_locked = _total_liquidity_locked - liquidity;
            _locked_liquidity[staker_address] = _locked_liquidity[staker_address] - liquidity;

            // Remove the stake from the array
            delete lockedStakes[staker_address];

            require(lockedStakes[staker_address].liquidity == 0);

            // Give the tokens to the destination_address
            // Should throw if insufficient balance
            // IERC20(lp_token_address).safeTransfer(destination_address, liquidity);
            TransferHelper.safeTransfer(lp_token_address, destination_address, liquidity);

            // Need to call again to make sure everything is correct
            reward_comptroller.updateRewardAndBalance(staker_address, false);

            emit WithdrawLocked(staker_address, liquidity, kek_id, destination_address);
        }
    }

    // ------ REWARDS CLAIMING ------
    // Two different collectReward functions are needed because of delegateCall and msg.sender issues
    function collectReward() external nonReentrant returns (uint256[] memory) {
        _require_reward_comptroller();
        require(collect_reward_delegator == address(0) || owner == msg.sender, "Only reward collecting delegator can perform this action");
        require(rewardsCollectionPaused == false, "Rewards collection paused");
        return reward_comptroller.collectRewardFor(msg.sender, msg.sender);
    }

    function collectRewardFor(address rewardee) external nonReentrant returns (uint256[] memory) {
        _require_reward_comptroller();
        require(collect_reward_delegator != address(0) && collect_reward_delegator == msg.sender, "Only reward collecting delegator can perform this action");
        require(rewardsCollectionPaused == false, "Rewards collection paused");
        return reward_comptroller.collectRewardFor(rewardee, msg.sender);
    }

    // function _beforeCalculateCombinedWeight(address account) internal {
    //     if (account == address(0)) {
    //         return;
    //     }

    //     uint256 ve_multiplier = boost_controller.veKromeMultiplier(account, userStakedUsdk(account));
    //     for (uint256 i = 0; i < lockedStakes[account].length; i++) {
    //         LockedStake storage thisStake = lockedStakes[account][i];
    //         if (thisStake.ve_multiplier < ve_multiplier) {
    //             thisStake.ve_multiplier = ve_multiplier;
    //         }
    //     }
    // }

    function checkpoint() external {
        _require_reward_comptroller();
        reward_comptroller.updateRewardAndBalance(msg.sender, true);
    }

    function syncInternal() internal {
        usdkPerLPStored = usdkPerLPToken();
    }

    function sync() external {
        _require_reward_comptroller();
        syncInternal();
        reward_comptroller.sync();
        _onSync();
    }

    function _syncTotalLpWeight(uint256 syncTime) internal {
        if (_total_liquidity_locked > 0 && totalLpWeightSyncTimestamp > 0) {
            totalLpWeightSynced += _total_liquidity_locked * (syncTime - totalLpWeightSyncTimestamp);
        }
        totalLpWeightSyncTimestamp = syncTime;
    }

    // function syncTotalLpWeight() external {
    //     uint256 syncTime = lpRewardDueTimestamp > 0 ? Math.min(lpRewardDueTimestamp, block.timestamp) : block.timestamp;

    //     _syncTotalLpWeight(syncTime);
    // }

    function syncUserLpWeight(address _account) internal {
        uint256 syncTime = lpRewardDueTimestamp > 0 ? Math.min(lpRewardDueTimestamp, block.timestamp) : block.timestamp;

        _syncTotalLpWeight(syncTime);

        uint256 lockedLiquidity = _locked_liquidity[_account];
        uint256 userSyncTimestamp = userLpWeightSyncTimestamp[_account];
        if (lockedLiquidity > 0 && userSyncTimestamp > 0) {
            userLpWeightSynced[_account] += lockedLiquidity * (syncTime - userSyncTimestamp);
        }
        userLpWeightSyncTimestamp[_account] = syncTime;
    }

    function _collectRewardExtraLogic(address rewardee, address destination_address) internal virtual {
        // Do nothing
    }

    function _onAfterStake(address account, uint256 amount) internal virtual {
        // Do nothing
    }

    function _onBeforeUnstake(address account, uint256 amount) internal virtual {
        // Do nothing
    }

    function _onSync() internal virtual {
        // Do nothing
    }

    function _getPendingLpRewards() internal view returns (uint[] memory rewards) {
    }

    // ------ MIGRATIONS ------

    // Dummy method for compatibility
    function stakerToggleMigrator(address migrator_address) external {}

    /* ========== RESTRICTED FUNCTIONS - Owner or timelock only ========== */
    
    function setRewardComptroller(address _reward_comptroller) external onlyByOwnGov {
        require(_reward_comptroller != address(0));
        reward_comptroller = IRewardComptroller(_reward_comptroller);
    }

    function setPauses(
        bool _stakingPaused,
        bool _updateStakingPaused,
        bool _withdrawalsPaused,
        bool _rewardsCollectionPaused
    ) external onlyByOwnGov {
        stakingPaused = _stakingPaused;
        updateStakingPaused = _updateStakingPaused;
        withdrawalsPaused = _withdrawalsPaused;
        rewardsCollectionPaused = _rewardsCollectionPaused;

        emit SetPause(_stakingPaused, _updateStakingPaused, _withdrawalsPaused, _rewardsCollectionPaused);
    }

    function setCollectRewardDelegator(address _delegator_address) external onlyByOwnGov {
        collect_reward_delegator = _delegator_address;

        emit SetCollectRewardDelegator(_delegator_address);
    }

    function greylistAddress(address _address) external onlyByOwnGov {
        greylist[_address] = !(greylist[_address]);

        emit SetGreylist(_address, greylist[_address]);
    }

    function unlockStakes() external onlyByOwnGov {
        stakesUnlocked = !stakesUnlocked;

        emit UnlockAllStakes(stakesUnlocked);
    }

    function toggleMigrations() external onlyByOwnGov {
        migrationsOn = !migrationsOn;

        emit ToggleMigration(migrationsOn);
    }

    function setBoostController(address _boost_controller) external onlyByOwnGov {
        boost_controller = IStakingBoostController(_boost_controller);

        emit SetBoostController(_boost_controller);
    }

    // Adds supported migrator address
    function toggleMigrator(address migrator_address) external onlyByOwnGov {
        valid_migrators[migrator_address] = !valid_migrators[migrator_address];

        emit ToggleMigrator(migrator_address, valid_migrators[migrator_address]);
    }

    function setLpRewardDue(uint256 _timestamp) external onlyByOwnGov {
        require(migrated_liquidity == 0, "already migrated");
        require(_timestamp >= closed_at, "due should be greater than closing time");
        require(_timestamp >= totalLpWeightSyncTimestamp, "due should be greater than last sync timestamp");
        lpRewardDueTimestamp = _timestamp;
    }

    function setTotalLpRewardAmount(uint256 idx, uint256 amount) external onlyByOwnGov {
        require(migrated_liquidity == 0, "already migrated");

        totalLpRewards[idx].amount = amount;
    }

    function addLpReward(address token_address, uint256 amount) external onlyByOwnGov {
        require(migrated_liquidity == 0, "already migrated");

        totalLpRewards.push(LpReward(token_address, amount));
    }

    function getLpRewardsLength() external view returns (uint256) {
        return totalLpRewards.length;
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        // Cannot recover the staking token or the rewards token except timelock
        // require(_token != lp_token_address || _msgSender() == timelock_address, "Invalid token");
        TransferHelper.safeTransfer(_token, _msgSender(), amount);
        emit RecoverERC20(_token, _msgSender(), amount);
    }

    /* ========== RESTRICTED FUNCTIONS - Curator / migrator callable ========== */

    // it should be migrated in order
    function migrator_set_migrated(address staker_address, bytes32 kek_id) external {
        require(valid_migrators[msg.sender] || msgByManager(), "Mig. invalid or unapproved");
        require(_locked_liquidity[staker_address] > migrated_user_liquidity[staker_address], "already migrated");

        StakeMigration memory migration = stakes_to_migrate_array[index_to_migrate];
        require(migration.account == staker_address && migration.kek_id == kek_id, "invalid migration");

        LpReward[] memory userLpRewards = lpRewardsFor(staker_address);
        if (userLpRewards.length > 0) {
            require(lpRewardDueTimestamp > 0 && block.timestamp > lpRewardDueTimestamp, "lpWeight due time");
        }
        for (uint i = 0; i < userLpRewards.length; i++) {
            if (userLpRewards[i].amount > 0) {
                TransferHelper.safeTransfer(userLpRewards[i].token_address, staker_address, userLpRewards[i].amount);
            }
        }

        index_to_migrate++;

        uint256 liquidity = lockedStakes[staker_address].liquidity;

        migrated_liquidity += liquidity;
        migrated_user_liquidity[staker_address] += liquidity;
    }
   
    /* ========== RESTRICTED FUNCTIONS - Owner or timelock only ========== */

    function _require_reward_comptroller() internal view {
        require(address(reward_comptroller) != address(0), "reward_comptroller not set");
    }
    // Inherited...

    /* ========== EVENTS ========== */

    event StakeLocked(address indexed user, uint256 amount, uint256 secs, bytes32 kek_id, address source_address);
    event WithdrawLocked(address indexed user, uint256 liquidity, bytes32 kek_id, address destination_address);
    event RecoverERC20(address token, address to, uint256 amount);
    event SetPause(bool staking, bool updateStaking, bool withdraw, bool collectReward);
    event SetCollectRewardDelegator(address delegator_address);
    event SetBoostController(address boost_controller);
    event SetGreylist(address addr, bool v);
    event UnlockAllStakes(bool v);
    event ToggleMigration(bool v);
    event ToggleMigrator(address migrator_address, bool v);
    event ToggleUnlockedStakeAllowance(bool allowUnlockedStake);

    uint256[100] private __gap;
}