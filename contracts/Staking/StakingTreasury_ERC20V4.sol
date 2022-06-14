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

abstract contract StakingTreasury_ERC20V4 is ContextUpgradeable, ReentrancyGuardUpgradeable, LocatorBasedProxyV2 {
    // using SafeERC20 for IERC20;

    // Constant for various precisions
    uint256 public constant MULTIPLIER_PRECISION = 1e18;

    /* ========== STATE VARIABLES ========== */

    IStakingBoostController public boost_controller;
    IRewardComptroller public reward_comptroller;

    address public lp_token_address;
    uint256 private lp_token_precision;

    uint256 public usdkPerLPStored;

    // Stake tracking
    mapping(address => LockedStake[]) public lockedStakes;
    mapping(address => uint256) public _locked_liquidity;
    // mapping(address => VeKromeMultiplier) public veMultipliers;
    uint256 internal _total_liquidity_locked;

    // Greylists
    mapping(address => bool) public greylist;

    // List of valid migrators (set by governance)
    mapping(address => bool) public valid_migrators;

    // Stakers set which migrator(s) they want to use
    mapping(address => mapping(address => bool)) public staker_allowed_migrators;

    // Admin booleans for emergencies, migrations, and overrides
    bool public stakesUnlocked; // Release locked stakes in case of emergency
    bool public migrationsOn; // Used for migrations. Prevents new stakes, but allows LP and reward withdrawals
    bool public withdrawalsPaused; // For emergencies
    bool public stakingPaused; // For emergencies
    bool public updateStakingPaused; // For emergencies
    bool public rewardsCollectionPaused; // For emergencies

    bool public allowUnlockedStake; // = false;

    address public collect_reward_delegator;

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

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == local_manager_address, "Not owner or timelock");
        _;
    }

    modifier updateRewardAndBalance(address account, bool sync_too) {
        _require_reward_comptroller();
        if (_locked_liquidity[account] > 0) {
            reward_comptroller.updateRewardAndBalance(account, sync_too);
        }
        _;
    }

    function _isMigrating() internal view {
        require(migrationsOn == true, "Not in migration");
    }

    /* ========== INITIALIZER ========== */

    function __StakingTreasury_init(
        address _locator_address,
        address _staking_boost_controller,
        address _staking_token
    ) internal onlyInitializing {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator_address);
        __StakingTreasury_init_unchained(_staking_boost_controller, _staking_token);
    }

    function __StakingTreasury_init_unchained(
        address _staking_boost_controller,
        address _staking_token
    ) internal onlyInitializing {
        boost_controller = IStakingBoostController(_staking_boost_controller);
        lp_token_address = _staking_token;
        lp_token_precision = 10 ** IERC20Decimals(_staking_token).decimals();

        // Other booleans
        stakesUnlocked = false;
        allowUnlockedStake = false;
    }

    /* ============ ABSTRACT =========== */

    function usdkPerLPToken() public virtual view returns (uint256);
    function getVirtualPrice() public virtual view returns (uint256);

    /* ============= VIEWS ============= */

    // ------ LIQUIDITY AND WEIGHTS ------

    // ------ LOCK RELATED ------

    // All the locked stakes for a given account
    function lockedStakesOf(address account) external view returns (LockedStake[] memory) {
        return lockedStakes[account];
    }

    // // All the locked stakes for a given account [old-school method]
    // function lockedStakesOfMultiArr(address account) external view returns (
    //     bytes32[] memory kek_ids,
    //     uint256[] memory start_timestamps,
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
        return lockedStakes[account].length;
    }

    function veKromeMultiplier(address account) external view returns (uint256 ve_multiplier, uint256 slope, uint256 stay_time) {
        return boost_controller.veKromeMultiplier(account, userStakedUsdk(account));
    }

    // ------ USDK RELATED ------

    function usdkForStake(uint256 liquidity) internal view returns (uint256) {
        return (usdkPerLPStored * liquidity) / lp_token_precision;
    }

    function userStakedUsdk(address account) public view returns (uint256) {
        return usdkForStake(_locked_liquidity[account]);
    }

    // ------ LIQUIDITY RELATED ------

    // Total locked liquidity / LP tokens
    function totalLiquidityLocked() external view returns (uint256) {
        return _total_liquidity_locked;
    }

    // User locked liquidity / LP tokens
    function lockedLiquidityOf(address account) external view returns (uint256) {
        return _locked_liquidity[account];
    }

    /* =============== MUTATIVE FUNCTIONS =============== */

    // ------ STAKING ------

    function _getStake(address staker_address, bytes32 kek_id) internal view returns (LockedStake memory locked_stake, uint256 arr_idx) {
        for (uint256 i = 0; i < lockedStakes[staker_address].length; i++){ 
            if (kek_id == lockedStakes[staker_address][i].kek_id){
                locked_stake = lockedStakes[staker_address][i];
                arr_idx = i;
                break;
            }
        }
        require(locked_stake.kek_id == kek_id, "Stake not found");
        
    }

    // Extends the lock of an existing stake
    function extendLockTime(bytes32 kek_id, uint256 secs) updateRewardAndBalance(msg.sender, true) public {
        require(stakingPaused == false && updateStakingPaused == false && migrationsOn == false, "Staking paused or in migration");
        require(greylist[msg.sender] == false, "Address has been greylisted");

        // Get the stake and its index
        (LockedStake memory thisStake, uint256 theArrayIndex) = _getStake(msg.sender, kek_id);

        // Check 
        require(secs > 0, "Must be in the future");
        require(secs >= thisStake.ending_timestamp - thisStake.start_timestamp, "Cannot shorten lock time");

        uint256 new_ending_ts = block.timestamp + secs;

        // Calculate the new seconds
        uint256 new_secs = new_ending_ts - block.timestamp;

        // Update the stake
        lockedStakes[msg.sender][theArrayIndex] = LockedStake(
            kek_id,
            block.timestamp,
            thisStake.liquidity,
            new_ending_ts,
            boost_controller.lockMultiplier(new_secs)
        );

        // Need to call to update the combined weights
        reward_comptroller.updateRewardAndBalance(msg.sender, false);
    }

    // Add additional LPs to an existing locked stake
    function lockAdditional(bytes32 kek_id, uint256 addl_liq) updateRewardAndBalance(msg.sender, true) public {
        require(stakingPaused == false && updateStakingPaused == false && migrationsOn == false, "Staking paused or in migration");
        require(greylist[msg.sender] == false, "Address has been greylisted");

        // Checks
        require(addl_liq > 0, "Must be nonzero");

        // Get the stake and its index
        (LockedStake memory thisStake, uint256 theArrayIndex) = _getStake(msg.sender, kek_id);

        // Calculate the new amount
        uint256 new_amt = thisStake.liquidity + addl_liq;

        // Pull the tokens from the sender
        TransferHelper.safeTransferFrom(lp_token_address, msg.sender, address(this), addl_liq);

        // Update the stake
        lockedStakes[msg.sender][theArrayIndex] = LockedStake(
            kek_id,
            thisStake.start_timestamp,
            new_amt,
            thisStake.ending_timestamp,
            thisStake.lock_multiplier
        );

        // Update liquidities
        _total_liquidity_locked = _total_liquidity_locked + addl_liq;
        _locked_liquidity[msg.sender] = _locked_liquidity[msg.sender] + addl_liq;

        _onAfterStake(msg.sender, addl_liq);

        // Need to call to update the combined weights
        reward_comptroller.updateRewardAndBalance(msg.sender, false);
    }

    // Two different stake functions are needed because of delegateCall and msg.sender issues (important for migration)
    function stakeLocked(uint256 liquidity, uint256 secs) nonReentrant external {
        _stakeLocked(msg.sender, msg.sender, liquidity, secs, block.timestamp);
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
        require((stakingPaused == false && migrationsOn == false) || valid_migrators[msg.sender] == true, "Staking paused or in migration");
        require(greylist[staker_address] == false, "Address has been greylisted");

        // Get the lock multiplier and kek_id
        uint256 lock_multiplier = !allowUnlockedStake || secs > 0 ? boost_controller.lockMultiplier(secs) : MULTIPLIER_PRECISION;
        bytes32 kek_id = keccak256(abi.encodePacked(staker_address, start_timestamp, liquidity, _locked_liquidity[staker_address]));

        // Pull in the required token(s)
        // Varies per farm
        // IERC20(lp_token_address).safeTransferFrom(source_address, address(this), liquidity);
        TransferHelper.safeTransferFrom(lp_token_address, source_address, address(this), liquidity);

        // Create the locked stake
        lockedStakes[staker_address].push(LockedStake(
            kek_id,
            start_timestamp,
            liquidity,
            start_timestamp + secs,
            lock_multiplier
        ));

        // Update liquidities
        _total_liquidity_locked = _total_liquidity_locked + liquidity;
        _locked_liquidity[staker_address] = _locked_liquidity[staker_address] + liquidity;

        _onAfterStake(staker_address, liquidity);

        // Need to call again to make sure everything is correct
        reward_comptroller.updateRewardAndBalance(staker_address, false);

        emit StakeLocked(staker_address, liquidity, secs, kek_id, source_address);
    }

    // ------ WITHDRAWING ------

    // Two different withdrawLocked functions are needed because of delegateCall and msg.sender issues (important for migration)
    function withdrawLocked(bytes32 kek_id) nonReentrant external {
        require(withdrawalsPaused == false, "Withdrawals paused");
        _withdrawLocked(msg.sender, msg.sender, kek_id);
    }

    function withdrawLockedFor(address account, bytes32 kek_id) nonReentrant external {
        require(collect_reward_delegator != address(0) && collect_reward_delegator == msg.sender, "Only reward collecting delegator can perform this action");
        require(withdrawalsPaused == false, "Withdrawals paused");
        _withdrawLocked(account, account, kek_id);
    }

    // No withdrawer == msg.sender check needed since this is only internally callable and the checks are done in the wrapper
    // functions like migrator_withdraw_locked() and withdrawLocked()
    function _withdrawLocked(
        address staker_address,
        address destination_address,
        bytes32 kek_id
    ) internal updateRewardAndBalance(staker_address, true) {
        _require_reward_comptroller();

        // Get the stake and its index
        (LockedStake memory thisStake, uint256 theArrayIndex) = _getStake(staker_address, kek_id);
        require(block.timestamp >= thisStake.ending_timestamp || stakesUnlocked == true || valid_migrators[msg.sender] == true, "Stake is still locked!");
        uint256 liquidity = thisStake.liquidity;

        if (liquidity > 0) {
            _onBeforeUnstake(staker_address, liquidity);

            // Update liquidities
            _total_liquidity_locked = _total_liquidity_locked - liquidity;
            _locked_liquidity[staker_address] = _locked_liquidity[staker_address] - liquidity;

            // Remove the stake from the array
            delete lockedStakes[staker_address][theArrayIndex];
            uint256 lastIndex = lockedStakes[staker_address].length - 1;
            if (theArrayIndex != lastIndex) {
                lockedStakes[staker_address][theArrayIndex] = lockedStakes[staker_address][lastIndex];
            }
            lockedStakes[staker_address].pop();

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

    function sync() external {
        _require_reward_comptroller();
        usdkPerLPStored = usdkPerLPToken();
        reward_comptroller.sync();
        _onSync();
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

    // ------ MIGRATIONS ------

    // Staker can allow a migrator 
    function stakerToggleMigrator(address migrator_address) external {
        require(valid_migrators[migrator_address], "Invalid migrator address");
        staker_allowed_migrators[msg.sender][migrator_address] = !staker_allowed_migrators[msg.sender][migrator_address]; 
    }

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

    function setAllowUnlockedStake(bool _allowUnlockedStake) external onlyByOwnGov {
        allowUnlockedStake = _allowUnlockedStake;

        emit ToggleUnlockedStakeAllowance(allowUnlockedStake);
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        // Cannot recover the staking token or the rewards token except timelock
        // require(_token != lp_token_address || _msgSender() == timelock_address, "Invalid token");
        TransferHelper.safeTransfer(_token, _msgSender(), amount);
        emit RecoverERC20(_token, _msgSender(), amount);
    }

     /* ========== RESTRICTED FUNCTIONS - Curator / migrator callable ========== */

    // Migrator can stake for someone else (they won't be able to withdraw it back though, only staker_address can). 
    function migrator_stakeLocked_for(address staker_address, uint256 amount, uint256 secs, uint256 start_timestamp) external {
        require(valid_migrators[msg.sender], "Mig. invalid or unapproved");
        _stakeLocked(staker_address, msg.sender, amount, secs, start_timestamp);
    }

    // Used for migrations
    function migrator_withdraw_locked(address staker_address, bytes32 kek_id) external {
        require(staker_allowed_migrators[staker_address][msg.sender] && valid_migrators[msg.sender], "Mig. invalid or unapproved");
        _withdrawLocked(staker_address, msg.sender, kek_id);
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