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
import "./IStakingTreasury.sol";
import "../Libs/TransferHelper.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract StakingRewardComptrollerR1 is TimelockOwned, ReentrancyGuard {
    // using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Instances
    IStakingTreasury private immutable treasury;
    IGaugeRewardsDistributor private rewards_distributor;
    // uint256 private immutable LPTokenPrecision;

    // Usdk related
    // address public usdk_address = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    // bool public usdk_is_token0;
    uint256 public usdkPerLPStored;

    // Time tracking
    uint256 public periodFinish;
    uint256 public lastUpdateTime;

    // veKROME related
    mapping(address => uint256) public _vekromeMultiplierStored;

    // Reward addresses, gauge addresses, reward rates, and reward managers
    mapping(address => address) public rewardManagers; // token addr -> manager addr
    address[] public rewardTokens;
    address[] public gaugeControllers;
    uint256[] public rewardRatesManual;
    string[] public rewardSymbols;
    mapping(address => uint256) public rewardTokenAddrToIdx; // token addr -> token index
    uint256[] public rewardAccumulated;
    uint256[] public rewardClaimed;
    
    // Reward period
    uint256 public rewardsDuration = 604800; // 7 * 86400  (7 days)

    // Reward tracking
    uint256[] private rewardsPerWeightStored;
    mapping(address => mapping(uint256 => uint256)) private userRewardsPerTokenPaid; // staker addr -> token id -> paid amount
    mapping(address => mapping(uint256 => uint256)) private rewards; // staker addr -> token id -> reward amount
    mapping(address => uint256) public lastRewardClaimTime; // staker addr -> timestamp
    
    // Gauge tracking
    uint256[] private last_gauge_relative_weights;
    uint256[] private last_gauge_time_totals;
    uint256[] private last_gauge_reward_rates;

    // Balance tracking
    uint256 internal _total_combined_weight;
    mapping(address => uint256) internal _combined_weights;

    /* ========== STRUCTS ========== */
    // In children...


    /* ========== MODIFIERS ========== */

    function _onlyTknMgrs(address reward_token_address) internal view {
        require(msg.sender == owner || isTokenManagerFor(msg.sender, reward_token_address), "Not owner or tkn mgr");
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _owner,
        address _timelock_address,
        address _treasury_address,
        address _rewards_distributor,
        uint256 _initial_time,
        address[] memory _rewardTokens,
        address[] memory _rewardManagers,
        uint256[] memory _rewardRatesManual,
        address[] memory _gaugeControllers
    ) TimelockOwned(_owner, _timelock_address) {
        treasury = IStakingTreasury(_treasury_address);
        rewards_distributor = IGaugeRewardsDistributor(_rewards_distributor);
        // LPTokenPrecision = 10 ** IERC20Decimals(_staking_token).decimals();

        // Address arrays
        rewardTokens = _rewardTokens;
        gaugeControllers = _gaugeControllers;
        rewardRatesManual = _rewardRatesManual;

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
        }

        // Initialization
        lastUpdateTime = 0;
        periodFinish = _initial_time;
    }

    /* ============= VIEWS ============= */

    // ------ REWARD RELATED ------

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
        (uint256 avg_combined_weight, ) = treasury.calcCurCombinedWeight(account);
        // It could be smaller if some stakes are expired
        uint256 combined_weight = Math.min(avg_combined_weight, _combined_weights[account]);
        uint256[] memory reward_arr = rewardsPerWeight();
        new_earned = new uint256[](rewardTokens.length);

        if (_combined_weights[account] == 0){
            for (uint256 i = 0; i < rewardTokens.length; i++){ 
                new_earned[i] = 0;
            }
        }
        else {
            for (uint256 i = 0; i < rewardTokens.length; i++){ 
                new_earned[i] = ((combined_weight * (reward_arr[i] - userRewardsPerTokenPaid[account][i])) / 1e18)
                                + rewards[account][i];
            }
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
        return _total_combined_weight;
    }

    // Total 'balance' used for calculating the percent of the pool the account owns
    // Takes into account the locked stake time multiplier and veKROME multiplier
    function combinedWeightOf(address account) external view returns (uint256) {
        return _combined_weights[account];
    }

    /* =============== MUTATIVE FUNCTIONS =============== */

    // ------ REWARDS SYNCING ------

    function checkpoint() external {
        updateRewardAndBalance(msg.sender, true);
    }

    function calcCurCombinedWeight(address account) external view returns (uint256 new_combined_weight)
    {
        (, new_combined_weight) = treasury.calcCurCombinedWeight(account);
    }

    function updateRewardAndBalance(address account, bool sync_too) public {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        if (sync_too){
            sync();
        }
        
        if (account != address(0)) {
            // Calculate the earnings first
            _syncEarned(account);

            // To keep the math correct, the user's combined weight must be recomputed to account for their
            // ever-changing veKROME balance.
            uint256 new_combined_weight = treasury.calcCurCombinedWeightWrite(account);

            uint256 old_combined_weight = _combined_weights[account];

            // Update the user's and the global combined weights
            _total_combined_weight = _total_combined_weight + new_combined_weight - old_combined_weight;
            _combined_weights[account] = new_combined_weight;
        }
    }

    function _syncEarned(address account) internal {
        // Calculate the earnings
        uint256[] memory earned_arr = earned(account);

        // Update the rewards array
        for (uint256 i = 0; i < earned_arr.length; i++){ 
            rewards[account][i] = earned_arr[i];
        }

        // Update the rewards paid array
        for (uint256 i = 0; i < earned_arr.length; i++){ 
            userRewardsPerTokenPaid[account][i] = rewardsPerWeightStored[i];
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
            require(rewardAccumulated[i] - rewardClaimed[i] + newReward <= IERC20(rewardTokens[i]).balanceOf(address(this)), string(abi.encodePacked("Not enough reward tokens available: ", addressToString(rewardTokens[i]))) );
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
            // if (_total_liquidity_locked != 0 && _total_combined_weight != 0) {
            //     rewardsPerWeightStored[i] = (rewardAccumulated[i] - rewardClaimed[i]) * 1e18 / _total_combined_weight;
            // }
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
            _updateStoredRewardsAndTime();
        }
    }

    function syncRewardRateForce() external { // only ownerOrTimelock
        require(msg.sender == owner || msg.sender == timelock_address, "Not the owner or the governance timelock");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address gauge_controller_address = gaugeControllers[i];
            if (gauge_controller_address != address(0)) {
                last_gauge_reward_rates[i] = IGaugeController(gauge_controller_address).global_emission_rate() * last_gauge_relative_weights[i] / 1e18;
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
