// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

// =========================================================================
//    __ __                              _______
//   / //_/_________  ____ ___  ___     / ____(_)___  ____ _____  ________
//  / ,<  / ___/ __ \/ __ `__ \/ _ \   / /_  / / __ \/ __ `/ __ \/ ___/ _ \
// / /| |/ /  / /_/ / / / / / /  __/  / __/ / / / / / /_/ / / / / /__/  __/
///_/ |_/_/   \____/_/ /_/ /_/\___/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/
//
// =========================================================================
// ================== KromeUnifiedFarmTemplate (USDK) ======================
// =========================================================================
// clone of FraxUnifiedFarmTemplate of Frax Finance
//
// Migratable Farming contract that accounts for veKROME
// Overrideable for UniV3, ERC20s, etc
// New for V2
//      - Two reward tokens possible
//      - Can extend or add to existing locked stakes
//      - Contract is aware of boosted veKROME (veKromeBoost)
//      - veKROME multiplier formula changed
//      - Contract uses only 1 (large) NFT
// Apes together strong

// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian
// Dennis: github.com/denett
// Sam Sun: https://github.com/samczsun

// Originally inspired by Synthetix.io, but heavily modified by the Frax team
// (Locked, veKROME, and UniV3 portions are new)
// https://raw.githubusercontent.com/Synthetixio/synthetix/develop/contracts/StakingRewards.sol

import "../Math/Math.sol";
import "./IGaugeController.sol";
import "./IGaugeRewardsDistributor.sol";
import "../ERC20/IERC20.sol";
// import "../ERC20/SafeERC20.sol";
import "../Common/ReentrancyGuard.sol";
import "../Common/TimelockOwned.sol";
import "./IStakingTreasuryV2.sol";
import "../Libs/TransferHelper.sol";
import "./IStakingBoostController.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface ISourceComptroller {
    function rewardClaimed(uint256 idx) external view returns (uint256);
    function rewardAccumulated(uint256 idx) external view returns (uint256);
    function totalCombinedWeight() external view returns (uint256);
    function combinedWeightOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256[] memory new_earned);
    function rewardsPerWeight() external view returns (uint256[] memory newRewardsPerWeightStored);
}

struct VeKromeMultiplier {
    uint256 multiplier;
    uint256 dslope;
    uint256 staytime;
    uint256 timestamp;
}

interface IVeMultiplierSource {
    function veMultipliers(address account) external view returns (VeKromeMultiplier memory);
}

contract StakingRewardComptrollerV3 is TimelockOwned, ReentrancyGuard {
    // using SafeERC20 for IERC20;

    // Constant for various precisions
    uint256 public constant MULTIPLIER_PRECISION = 1e18;

    /* ========== STATE VARIABLES ========== */

    // Instances
    IStakingTreasuryV2 private immutable treasury;
    IGaugeRewardsDistributor private rewards_distributor;
    // uint256 private immutable LPTokenPrecision;

    // Usdk related
    // address public usdk_address = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    // bool public usdk_is_token0;
    // uint256 public usdkPerLPStored;

    // Time tracking
    uint256 public periodFinish;
    uint256 public lastUpdateTime;

    // veKROME related
    // mapping(address => uint256) public _vekromeMultiplierStored;

    // Reward addresses, gauge addresses, reward rates, and reward managers
    mapping(address => address) public rewardManagers; // token addr -> manager addr
    address[] public rewardTokens;
    address[] public gaugeControllers;
    uint256[] public rewardRatesManual;
    string[] public rewardSymbols;
    mapping(address => uint256) public rewardTokenAddrToIdx; // token addr -> token index
    uint256[] public rewardAccumulated;
    uint256[] public rewardClaimed;
    // accumulated syned earnings
    uint256[] public earningsAccumulated;
    
    // Reward period
    uint256 public rewardsDuration = 604800; // 7 * 86400  (7 days)

    // Reward tracking
    uint256[] private rewardsPerWeightStored;

    // rewardsPerWeightStored when user checkpointed
    mapping(address => mapping(uint256 => uint256)) private userRewardsPerWeightPaid; // staker addr -> token id -> paid amount

    // current rewards checkpointed, reset on claim
    mapping(address => mapping(uint256 => uint256)) private rewards; // staker addr -> token id -> reward amount
    mapping(address => uint256) public lastRewardClaimTime; // staker addr -> timestamp
    
    mapping(address => VeKromeMultiplier) public veMultipliers;

    // Gauge tracking
    uint256[] private last_gauge_relative_weights;
    uint256[] private last_gauge_time_totals;
    uint256[] private last_gauge_reward_rates;

    // Balance tracking
    uint256 internal _total_combined_weight;
    mapping(address => uint256) internal _combined_weights;

    // List of valid migrators (set by governance)
    mapping(address => bool) public valid_migrators;

    // comptroller migration
    ISourceComptroller public source_comptroller;
    IVeMultiplierSource public ve_multiplier_source;
    bool public source_synced;
    mapping(address => bool) public user_source_synced;

    /* ========== STRUCTURE ========== */

    /* ========== MODIFIERS ========== */

    function _onlyTknMgrs(address reward_token_address) internal view {
        require(msg.sender == owner || isTokenManagerFor(msg.sender, reward_token_address), "Not owner or tkn mgr");
    }

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    modifier onlyValidMigrator() {
        require(valid_migrators[msg.sender], "Not valid migrator");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _owner,
        address _timelock_address,
        address _treasury_address,
        address _rewards_distributor,
        uint256 _initial_time,
        address _source_comptroller, // to migrate comproller without changing treasury or address(0)
        address _ve_multiplier_source, // to migrate comproller without changing treasury or address(0)
        address[] memory _rewardTokens,
        address[] memory _rewardManagers,
        uint256[] memory _rewardRatesManual,
        address[] memory _gaugeControllers
    ) TimelockOwned(_owner, _timelock_address) {
        treasury = IStakingTreasuryV2(_treasury_address);
        rewards_distributor = IGaugeRewardsDistributor(_rewards_distributor);
        // LPTokenPrecision = 10 ** IERC20Decimals(_staking_token).decimals();

        // Address arrays
        rewardTokens = _rewardTokens;
        gaugeControllers = _gaugeControllers;
        rewardRatesManual = _rewardRatesManual;

        source_comptroller = ISourceComptroller(_source_comptroller);
        ve_multiplier_source = IVeMultiplierSource(_ve_multiplier_source);

        for (uint256 i = 0; i < _rewardTokens.length; i++){ 
            // For fast token address -> token ID lookups later
            rewardTokenAddrToIdx[_rewardTokens[i]] = i;

            // Initialize the stored rewards
            rewardsPerWeightStored.push(0);

            // Initialize the reward managers
            rewardManagers[_rewardTokens[i]] = _rewardManagers[i];

            // Push in empty relative weights to initialize the array
            last_gauge_relative_weights.push(0);

            // Push in empty time totals to initialize the array
            last_gauge_time_totals.push(0);

            last_gauge_reward_rates.push(0);

            rewardAccumulated.push(0);
            rewardClaimed.push(0);

            if (address(source_comptroller) != address(0)) {
                rewardAccumulated[i] = Math.max(source_comptroller.rewardAccumulated(i), source_comptroller.rewardClaimed(i));
                rewardClaimed[i] = source_comptroller.rewardClaimed(i);
            }

            earningsAccumulated.push(0);
        }

        // Initialization
        lastUpdateTime = 0;
        periodFinish = _initial_time;
    }

    /* ============= VIEWS ============= */

    // ------ REWARD RELATED ------

    function _multiplier_on(VeKromeMultiplier memory ve, uint256 ts) internal pure returns (uint256) {
        require(ts >= ve.timestamp, "Invalid timestamp");
        uint256 decrese = ve.dslope * (ve.staytime >= ts - ve.timestamp ? 0 : ts - ve.timestamp - ve.staytime);
        return ve.multiplier >= decrese ? ve.multiplier - decrese : 0;
    }

    function calcCurCombinedWeight(address account) public view returns (uint256 cur_combined_weight)
    {
        VeKromeMultiplier memory veMultiplier = address(ve_multiplier_source) != address(0) && !user_source_synced[account]
            ? ve_multiplier_source.veMultipliers(account)
            : veMultipliers[account];

        uint256 cur_ve_multiplier = _multiplier_on(veMultiplier, block.timestamp);

        IStakingTreasuryV2.LockedStake[] memory lockedStakes = treasury.lockedStakesOf(account);
        // Loop through the locked stakes, first by getting the liquidity * lock_multiplier portion
        for (uint256 i = 0; i < lockedStakes.length; i++) {
            IStakingTreasuryV2.LockedStake memory thisStake = lockedStakes[i];

            uint256 lock_multiplier = thisStake.lock_multiplier;
            uint256 cur_boost_multiplier;
            if (thisStake.ending_timestamp > block.timestamp) {
                cur_boost_multiplier = lock_multiplier + cur_ve_multiplier;
            } else {
                cur_boost_multiplier = MULTIPLIER_PRECISION;
            }
            uint256 liquidity = thisStake.liquidity;
            cur_combined_weight += ((liquidity * cur_boost_multiplier) / MULTIPLIER_PRECISION);
        }
    }

    // Calculated the combined weight to reward in reward period for an account
    function calcRewardCombinedWeight(address account) public view returns (
        uint256 avg_combined_weight, // average between checkpointed time and now, to calculate earnings
        uint256 start_timestamp,
        uint256 end_timestamp
    ) {
        VeKromeMultiplier memory veMultiplier = address(ve_multiplier_source) != address(0) && !user_source_synced[account]
            ? ve_multiplier_source.veMultipliers(account)
            : veMultipliers[account];

        start_timestamp = veMultiplier.timestamp;
        end_timestamp = lastTimeRewardApplicable();

        IStakingTreasuryV2.LockedStake[] memory lockedStakes = treasury.lockedStakesOf(account);
        // Loop through the locked stakes, first by getting the liquidity * lock_multiplier portion
        for (uint256 i = 0; i < lockedStakes.length; i++) {
            IStakingTreasuryV2.LockedStake memory thisStake = lockedStakes[i];

            uint256 lock_multiplier = thisStake.lock_multiplier;

            uint256 avg_boost_multiplier;
            if (thisStake.ending_timestamp > end_timestamp) { // If not expired
                uint256 avg_ve_multiplier = _avg_ve_multiplier(Math.max(thisStake.start_timestamp, start_timestamp), end_timestamp, veMultiplier);

                avg_boost_multiplier = lock_multiplier + avg_ve_multiplier;
            } else if (thisStake.ending_timestamp > start_timestamp) { // If the lock is expired within period
                uint256 avg_ve_multiplier = _avg_ve_multiplier(Math.max(thisStake.start_timestamp, start_timestamp), thisStake.ending_timestamp, veMultiplier);

                uint256 time_before_expiry = thisStake.ending_timestamp - start_timestamp;
                uint256 time_after_expiry = end_timestamp - thisStake.ending_timestamp;

                // Get the weighted-average multiplier
                uint256 numerator = ((lock_multiplier + avg_ve_multiplier) * time_before_expiry) + (MULTIPLIER_PRECISION * time_after_expiry);
                avg_boost_multiplier = numerator / (time_before_expiry + time_after_expiry);
            } else { // Otherwise, it needs to just be 1x
                avg_boost_multiplier = MULTIPLIER_PRECISION;
            }

            uint256 liquidity = thisStake.liquidity;
            avg_combined_weight += ((liquidity * avg_boost_multiplier) / MULTIPLIER_PRECISION);
        }
    }
    function _avg_ve_multiplier(uint256 start_time, uint256 end_time, VeKromeMultiplier memory ve) internal pure returns (uint256 avg_ve_multiplier) {
        if (ve.multiplier == 0) return 0;
        if (end_time < start_time || start_time < ve.timestamp) return 0;

        uint256 period = end_time - start_time;
        uint256 ve_multiplier_start = _multiplier_on(ve, start_time);
        if (period == 0) {
            return ve_multiplier_start;
        }
        uint256 ve_multiplier_end = _multiplier_on(ve, end_time);

        uint staytime;
        if (ve.timestamp + ve.staytime >= end_time) {
            staytime = end_time - start_time;
        } else if (ve.timestamp + ve.staytime >= start_time) {
            staytime = 0;
        } else {
            staytime = ve.timestamp + ve.staytime - start_time;
        }

        // period = dtime + staytime + (time that multiplier is 0)
        avg_ve_multiplier = (((ve_multiplier_start + ve_multiplier_end) / 2) * (period - staytime) + ve.multiplier * staytime) / period;
    }

    // See if the caller_addr is a manager for the reward token 
    function isTokenManagerFor(address caller_addr, address reward_token_addr) public view returns (bool){
        if (caller_addr == owner) return true; // Contract owner
        else if (rewardManagers[reward_token_addr] == caller_addr) return true; // Reward manager
        return false; 
    }

    // All the reward tokens
    function getAllRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    // Last time the reward was applicable
    function lastTimeRewardApplicable() internal view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardRates(uint256 token_idx) public view returns (uint256 rwd_rate) {
        address gauge_controller_address = gaugeControllers[token_idx];
        if (gauge_controller_address != address(0)) {
            rwd_rate = last_gauge_reward_rates[token_idx];
        }
        else {
            rwd_rate = rewardRatesManual[token_idx];
        }
    }

    // Amount of reward tokens per LP token / liquidity unit
    function rewardsPerWeight() public view returns (uint256[] memory newRewardsPerWeightStored) {
        if (!source_synced && address(source_comptroller) != address(0)) {
            return source_comptroller.rewardsPerWeight();
        }
        if (treasury.totalLiquidityLocked() == 0 || _total_combined_weight == 0 || lastUpdateTime == 0) {
            return rewardsPerWeightStored;
        }
        else {
            newRewardsPerWeightStored = new uint256[](rewardTokens.length);
            for (uint256 i = 0; i < rewardsPerWeightStored.length; i++){ 
                newRewardsPerWeightStored[i] = rewardsPerWeightStored[i] + (
                    ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRates(i) * 1e18) / _total_combined_weight
                );
            }
            return newRewardsPerWeightStored;
        }
    }

    // Amount of reward tokens an account has earned / accrued
    // Note: In the edge-case of one of the account's stake expiring since the last claim, this will
    // return a slightly inflated number
    function earned(address account) public view returns (uint256[] memory new_earned) {
        if (address(source_comptroller) != address(0) && !user_source_synced[account]) {
            return _getSourceEarned(account);
        }
        (uint256 avg_combined_weight,,) = calcRewardCombinedWeight(account);
        // It could be smaller if some stakes are expired
        uint256 combined_weight = Math.min(avg_combined_weight, _combined_weights[account]);
        uint256[] memory reward_arr = rewardsPerWeight();
        new_earned = new uint256[](rewardTokens.length);
        
        for (uint256 i = 0; i < rewardTokens.length; i++){ 
            uint256 paidReward = userRewardsPerWeightPaid[account][i];

            new_earned[i] = ((combined_weight * (reward_arr[i] - paidReward)) / 1e18)
                            + rewards[account][i];
        }
    }

    function _getSourceEarned(address account) public view returns (uint256[] memory new_earned) {
        // global source infromations should be synced, thus syncEarned should be called after source_sycned
        require(source_synced, "source not synced");

        (uint256 avg_combined_weight,,) = calcRewardCombinedWeight(account);
        // It could be smaller if some stakes are expired
        uint256 combined_weight = Math.min(avg_combined_weight, _getSourceCombinedWeightOf(account));
        uint256[] memory reward_arr = rewardsPerWeight();

        uint256[] memory source_earned = source_comptroller.earned(account);
        uint256[] memory source_reward_arr = source_comptroller.rewardsPerWeight();
        new_earned = new uint256[](rewardTokens.length);
        
        for (uint256 i = 0; i < rewardTokens.length; i++){ 
            uint256 paidReward = source_reward_arr[i];
            // reward_arr should be gte source_reward, but for safety
            uint256 rewardPerWeight = reward_arr[i] > paidReward ? reward_arr[i] - paidReward : 0;

            new_earned[i] = ((combined_weight * rewardPerWeight) / 1e18)
                            + source_earned[i];
        }
    }

    // Total reward tokens emitted in the given period
    function getRewardForDuration() external view returns (uint256[] memory rewards_per_duration_arr) {
        rewards_per_duration_arr = new uint256[](rewardRatesManual.length);

        for (uint256 i = 0; i < rewardRatesManual.length; i++){ 
            rewards_per_duration_arr[i] = rewardRates(i) * rewardsDuration;
        }
    }


    // ------ LIQUIDITY AND WEIGHTS ------

    // Total combined weight
    function totalCombinedWeight() external view returns (uint256) {
        return source_synced ? _total_combined_weight : _getSourceTotalCombinedWeight();
    }

    // Total 'balance' used for calculating the percent of the pool the account owns
    // Takes into account the locked stake time multiplier and veKROME multiplier
    function combinedWeightOf(address account) external view returns (uint256) {
        return user_source_synced[account] ? _combined_weights[account] : _getSourceCombinedWeightOf(account);
    }

    /* =============== MUTATIVE FUNCTIONS =============== */

    // ------ REWARDS SYNCING ------

    function checkpoint() external {
        updateRewardAndBalance(msg.sender, true);
    }

    function updateRewardAndBalance(address account, bool sync_too) public {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        if (sync_too || !source_synced){
            sync();
        }

        if (account != address(0)) {
            // Calculate the earnings first
            _syncEarned(account);

            // To keep the math correct, the user's combined weight must be recomputed to account for their
            // ever-changing veKROME balance.
            (uint256 ve_multiplier, uint256 dslope, uint256 staytime)
                = IStakingBoostController(treasury.boost_controller()).veKromeMultiplier(account, treasury.userStakedUsdk(account));
            veMultipliers[account] = VeKromeMultiplier(
                ve_multiplier,
                dslope,
                staytime,
                block.timestamp
            );

            uint256 new_combined_weight = calcCurCombinedWeight(account);
            uint256 old_combined_weight = _combined_weights[account];

            // Update the user's and the global combined weights
            _total_combined_weight = _total_combined_weight + new_combined_weight - old_combined_weight;
            _combined_weights[account] = new_combined_weight;
        }
    }

    // should be called after rewardsPerWeightStored updated
    function _syncEarned(address account) internal {
        // Calculate the earnings
        uint256[] memory earned_arr = earned(account);

        // Update the rewards array
        for (uint256 i = 0; i < earned_arr.length; i++){ 
            earningsAccumulated[i] = earningsAccumulated[i] + earned_arr[i] - rewards[account][i];
            rewards[account][i] = earned_arr[i];
        }

        // Update the rewards paid array
        for (uint256 i = 0; i < earned_arr.length; i++){ 
            userRewardsPerWeightPaid[account][i] = rewardsPerWeightStored[i];
        }

        if (address(source_comptroller) != address(0) && !user_source_synced[account]) {
            _combined_weights[account] = _getSourceCombinedWeightOf(account);
            user_source_synced[account] = true;
        }
    }

    // ------ REWARDS CLAIMING ------

    function _collectRewardExtraLogic(address /* rewardee */, address /* destination_address */) internal virtual {}
    //     revert("Need _getRewardExtraLogic logic");
    // }

    // No withdrawer == msg.sender check needed since this is only internally callable
    function collectRewardFor(address rewardee, address destination_address) external nonReentrant returns (uint256[] memory rewards_before) {
        require(address(treasury) != address(0) && msg.sender == address(treasury), "Only treasury can perform this action");

        if (treasury.lockedLiquidityOf(rewardee) > 0) {
            updateRewardAndBalance(rewardee, true);
        }
        // Update the rewards array and distribute rewards
        rewards_before = new uint256[](rewardTokens.length);

        for (uint256 i = 0; i < rewardTokens.length; i++){ 
            rewards_before[i] = rewards[rewardee][i];
            earningsAccumulated[i] += rewards_before[i];
            rewards[rewardee][i] = 0;
            rewardClaimed[i] += rewards_before[i];
            TransferHelper.safeTransfer(rewardTokens[i], destination_address, rewards_before[i]);
            // IERC20(rewardTokens[i]).safeTransfer(destination_address, rewards_before[i]);
        }

        // Handle additional reward logic
        _collectRewardExtraLogic(rewardee, destination_address);

        // Update the last reward claim time
        lastRewardClaimTime[rewardee] = block.timestamp;
    }


    // ------ FARM SYNCING ------

    // If the period expired, renew it
    function retroCatchUp() internal {
        if (lastUpdateTime == 0) {
            lastUpdateTime = periodFinish;
        }

        // Update the rewards for the finished period and time
        _updateStoredRewardsAndTime();

        // Pull in rewards from the rewards distributor
        rewards_distributor.distributeReward(address(this));

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerWeight functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 num_periods_elapsed = ((block.timestamp - periodFinish) / rewardsDuration) + 1; // Floor division to the nearest period

        // Make sure there are enough tokens to renew the reward period
        for (uint256 i = 0; i < rewardTokens.length; i++) { 
            // update only when reward distributed
            address gauge_controller_address = gaugeControllers[i];
            if (gauge_controller_address != address(0)) {
                last_gauge_reward_rates[i] = IGaugeController(gauge_controller_address).global_emission_rate() * last_gauge_relative_weights[i] / 1e18;
            }

            // rewards should be include thos period's
            uint256 newReward = rewardRates(i) * rewardsDuration * num_periods_elapsed;
            require(rewardAccumulated[i] + newReward <= IERC20(rewardTokens[i]).balanceOf(address(this)) + rewardClaimed[i], string(abi.encodePacked("Not enough reward tokens available: ", addressToString(rewardTokens[i]))) );
            rewardAccumulated[i] += newReward;
        }

        // uint256 old_lastUpdateTime = lastUpdateTime;
        // uint256 new_lastUpdateTime = block.timestamp;

        // lastUpdateTime = periodFinish;
        periodFinish = periodFinish + (num_periods_elapsed * rewardsDuration);

        // Update the usdkPerLPStored
        treasury.sync();
    }

    function _updateStoredRewardsAndTime() internal {
        // Get the rewards
        uint256[] memory rewards_per_weight = rewardsPerWeight();

        // Update the rewardsPerWeightStored
        for (uint256 i = 0; i < rewardsPerWeightStored.length; i++){ 
            rewardsPerWeightStored[i] = rewards_per_weight[i];
        }

        if (lastUpdateTime > 0) {
            // Update the last stored time
            lastUpdateTime = lastTimeRewardApplicable();
        }
    }

    function sync_gauge_weights(bool force_update) public {
        // Loop through the gauge controllers
        for (uint256 i = 0; i < gaugeControllers.length; i++){ 
            address gauge_controller_address = gaugeControllers[i];
            if (gauge_controller_address != address(0)) {
                if (force_update || (block.timestamp > last_gauge_time_totals[i])){
                    // Update the gauge_relative_weight
                    last_gauge_relative_weights[i] = IGaugeController(gauge_controller_address).gauge_relative_weight_write(address(this), block.timestamp);
                    last_gauge_time_totals[i] = IGaugeController(gauge_controller_address).time_total();
                }
            }
        }
    }

    function sync() public {
        // Sync the gauge weight, if applicable
        sync_gauge_weights(false);

        if (block.timestamp >= periodFinish) {
            retroCatchUp();
        }
        else {
            // this is also called in retroChatUp(), but order is important
            _updateStoredRewardsAndTime();
        }
        if (!source_synced) {
            _total_combined_weight = _getSourceTotalCombinedWeight();
            source_synced = true;
        }
    }

    function syncRewardRateForce() external onlyByOwnGov { // only ownerOrTimelock
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address gauge_controller_address = gaugeControllers[i];
            if (gauge_controller_address != address(0)) {
                last_gauge_reward_rates[i] = IGaugeController(gauge_controller_address).global_emission_rate() * last_gauge_relative_weights[i] / 1e18;
            }

            uint256 tokenBalance = IERC20(rewardTokens[i]).balanceOf(address(this));
            if (rewardAccumulated[i] < tokenBalance + rewardClaimed[i]) {
                rewardAccumulated[i] = tokenBalance + rewardClaimed[i];
            }
        }

    }

    /* ========== RESTRICTED FUNCTIONS - Owner or timelock only ========== */
    
    // ------ PAUSES ------

    // Added to support recovering LP Rewards and other mistaken tokens from other systems to be distributed to holders

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external {
        _onlyTknMgrs(tokenAddress);
        // Check if the desired token is a reward token
        bool isRewardToken = false;
        for (uint256 i = 0; i < rewardTokens.length; i++){ 
            if (rewardTokens[i] == tokenAddress) {
                isRewardToken = true;
                break;
            }
        }

        // Only the reward managers can take back their reward tokens
        if (isRewardToken && rewardManagers[tokenAddress] == msg.sender){
            // IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
            TransferHelper.safeTransfer(tokenAddress, msg.sender, tokenAmount);
            return;
        }

        // Other tokens, like the staking token, airdrops, or accidental deposits, can be withdrawn by the owner
        else if (!isRewardToken && (msg.sender == owner)){
            // IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
            TransferHelper.safeTransfer(tokenAddress, msg.sender, tokenAmount);
            return;
        }

        // If none of the above conditions are true
        else {
            revert("No valid tokens to recover");
        }
    }

    // The owner or the reward token managers can set reward rates 
    function setRewardRate(address reward_token_address, uint256 new_rate) external {
        _onlyTknMgrs(reward_token_address);
        rewardRatesManual[rewardTokenAddrToIdx[reward_token_address]] = new_rate;
    }

    // The owner or the reward token managers can set reward rates 
    function setGaugeController(address reward_token_address, address _rewards_distributor_address, address _gauge_controller_address) external {
        _onlyTknMgrs(reward_token_address);
        gaugeControllers[rewardTokenAddrToIdx[reward_token_address]] = _gauge_controller_address;
        rewards_distributor = IGaugeRewardsDistributor(_rewards_distributor_address);
    }

    // The owner or the reward token managers can change managers
    function changeTokenManager(address reward_token_address, address new_manager_address) external {
        _onlyTknMgrs(reward_token_address);
        rewardManagers[reward_token_address] = new_manager_address;
    }

    function addressToString(address _address) public pure returns(string memory) {
       bytes32 _bytes = bytes32(uint256(uint160(bytes20(_address))));
       bytes memory HEX = "0123456789abcdef";
       bytes memory _string = new bytes(42);
       _string[0] = '0';
       _string[1] = 'x';
       for(uint i = 0; i < 20; i++) {
           _string[2+i*2] = HEX[uint8(_bytes[i + 12] >> 4)];
           _string[3+i*2] = HEX[uint8(_bytes[i + 12] & 0x0f)];
       }
       return string(_string);
    }

    // ------ MIGRATION ------

    // Adds supported migrator address
    function setMigrator(address migrator_address, bool v) external onlyByOwnGov {
        valid_migrators[migrator_address] = v;

        emit SetMigrator(migrator_address, valid_migrators[migrator_address]);
    }

    function migrate_earned(address _account, uint256[] calldata _earned_arr) external onlyValidMigrator {
       for (uint256 i = 0; i < _earned_arr.length; i++){ 
            rewards[_account][i] += _earned_arr[i];
            earningsAccumulated[i] += _earned_arr[i];
        }
    }

    //  source migrations
    function _getSourceTotalCombinedWeight() internal view returns (uint256) {
        return address(source_comptroller) != address(0) ? source_comptroller.totalCombinedWeight() : _total_combined_weight;
    }

    //  source migrations
    function _getSourceCombinedWeightOf(address account) internal view returns (uint256) {
        return address(source_comptroller) != address(0) ? source_comptroller.combinedWeightOf(account) : _combined_weights[account] ;
    }

    /* ========== EVENTS ========== */
    event SetMigrator(address migrator_address, bool v);

    /* ========== A CHICKEN ========== */
    //
    //         ,~.
    //      ,-'__ `-,
    //     {,-'  `. }              ,')
    //    ,( a )   `-.__         ,',')~,
    //   <=.) (         `-.__,==' ' ' '}
    //     (   )                      /)
    //      `-'\   ,                    )
    //          |  \        `~.        /
    //          \   `._        \      /
    //           \     `._____,'    ,'
    //            `-.             ,'
    //               `-._     _,-'
    //                   77jj'
    //                  //_||
    //               __//--'/`
    //             ,--'/`  '
    //
    // [hjw] https://textart.io/art/vw6Sa3iwqIRGkZsN1BC2vweF/chicken
}
