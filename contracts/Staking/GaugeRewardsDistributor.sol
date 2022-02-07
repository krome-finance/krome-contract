// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// =========================================================================
//    __ __                              _______
//   / //_/_________  ____ ___  ___     / ____(_)___  ____ _____  ________
//  / ,<  / ___/ __ \/ __ `__ \/ _ \   / /_  / / __ \/ __ `/ __ \/ ___/ _ \
// / /| |/ /  / /_/ / / / / / /  __/  / __/ / / / / / /_/ / / / / /__/  __/
///_/ |_/_/   \____/_/ /_/ /_/\___/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/
//
// =========================================================================
// =============== GaugeRewardsDistributor (USDK) =====================
// =========================================================================
// Looks at the gauge controller contract and pushes out KROME rewards once
// a week to the gauges (farms)

// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian

import "../Math/Math.sol";
import "../ERC20/IERC20.sol";
import "./IGaugeController.sol";
import "./IKromeMiddlemanGauge.sol";
import '../Libs/TransferHelper.sol';
import "../Common/TimelockOwned.sol";
import "../Common/ReentrancyGuard.sol";

contract GaugeRewardsDistributor is TimelockOwned, ReentrancyGuard {
    // using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    // Instances and addresses
    address public reward_token_address;
    IGaugeController public gauge_controller;

    // Admin addresses
    address public curator_address;

    // Constants
    uint256 private constant MULTIPLIER_PRECISION = 1e18;
    uint256 private constant ONE_WEEK = 604800;

    // Gauge controller related
    mapping(address => bool) public gauge_whitelist;
    mapping(address => bool) public is_middleman; // For cross-chain farms, use a middleman contract to push to a bridge
    mapping(address => uint256) public gauge_period_finish_time;
    mapping(address => uint256) public gauge_duration;

    // Booleans
    bool public distributionsOn;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnerOrCuratorOrGovernance() {
        require(msg.sender == owner || msg.sender == curator_address || msg.sender == timelock_address, "Not owner, curator, or timelock");
        _;
    }

    modifier isDistributing() {
        require(distributionsOn == true, "Distributions are off");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _owner,
        address _timelock_address,
        address _curator_address,
        address _reward_token_address,
        address _gauge_controller_address
    ) TimelockOwned(_owner, _timelock_address) {
        curator_address = _curator_address;

        reward_token_address = _reward_token_address;
        gauge_controller = IGaugeController(_gauge_controller_address);

        distributionsOn = true;

    }

    /* ========== VIEWS ========== */

    // Current weekly reward amount
    function currentReward(address gauge_address) public view returns (uint256 reward_amount) {
        uint256 rel_weight = gauge_controller.gauge_relative_weight(gauge_address, block.timestamp);
        uint256 rwd_rate = (gauge_controller.global_emission_rate()) * (rel_weight) / (1e18);
        reward_amount = rwd_rate * (ONE_WEEK);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // Callable by anyone
    function distributeReward(address gauge_address) public isDistributing nonReentrant returns (uint256 weeks_elapsed, uint256 reward_tally) {
        require(gauge_whitelist[gauge_address], "Gauge not whitelisted");
        
        uint256 _gauge_duration = gauge_duration[gauge_address];
        uint256 _period_finish = gauge_period_finish_time[gauge_address];

        // Return early here for 0 weeks instead of throwing, as it could have bad effects in other contracts
        if (block.timestamp < _period_finish) {
            return (0, 0);
        }

        // Truncation desired
        weeks_elapsed = ((block.timestamp - _period_finish) / _gauge_duration) + 1;

        // NOTE: This will always use the current global_emission_rate()
        reward_tally = 0;
        for (uint i = 0; i < weeks_elapsed; i++) { 
            uint256 rel_weight_at_week;
            if (i == 0) {
                // Mutative, for the current week. Makes sure the weight is checkpointed. Also returns the weight.
                rel_weight_at_week = gauge_controller.gauge_relative_weight_write(gauge_address, block.timestamp);
            }
            else {
                // View
                rel_weight_at_week = gauge_controller.gauge_relative_weight(gauge_address, block.timestamp - (_gauge_duration * i));
            }
            uint256 rwd_rate_at_week = gauge_controller.global_emission_rate() * rel_weight_at_week / 1e18;
            reward_tally = reward_tally + (rwd_rate_at_week * _gauge_duration);
        }

        // Update the last time paid
        gauge_period_finish_time[gauge_address] += weeks_elapsed * _gauge_duration;

        if (is_middleman[gauge_address]){
            // Cross chain: Pay out the rewards to the middleman contract
            // Approve for the middleman first
            IERC20(reward_token_address).approve(gauge_address, reward_tally);

            // Trigger the middleman
            IKromeMiddlemanGauge(gauge_address).pullAndBridge(reward_tally);
        }
        else {
            // Mainnet: Pay out the rewards directly to the gauge
            TransferHelper.safeTransfer(reward_token_address, gauge_address, reward_tally);
        }

        emit RewardDistributed(gauge_address, reward_tally);
    }

    /* ========== RESTRICTED FUNCTIONS - Curator / migrator callable ========== */

    // For emergency situations
    function toggleDistributions() external onlyByOwnerOrCuratorOrGovernance {
        distributionsOn = !distributionsOn;

        emit DistributionsToggled(distributionsOn);
    }

    /* ========== RESTRICTED FUNCTIONS - Owner or timelock only ========== */
    
    // Added to support recovering LP Rewards and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        // Only the owner address can ever receive the recovery withdrawal
        TransferHelper.safeTransfer(tokenAddress, owner, tokenAmount);
        emit RecoveredERC20(tokenAddress, tokenAmount);
    }

    function setGaugeState(address _gauge_address, bool _is_middleman, bool _is_active) external onlyByOwnGov {
        require(_gauge_address != address(0));
        require(gauge_period_finish_time[_gauge_address] > 0);
        is_middleman[_gauge_address] = _is_middleman;
        gauge_whitelist[_gauge_address] = _is_active;

        emit GaugeStateChanged(_gauge_address, _is_middleman, _is_active);
    }

    function setGaugeDuration(address _gauge_address, uint256 _duration) external onlyByOwnGov {
        require(_gauge_address != address(0) && gauge_duration[_gauge_address] > 0);
        require(_duration >= 0);
        gauge_duration[_gauge_address] = _duration;
    }

    function addGauge(address _gauge_address, uint256 _initial_period_finish_time, uint256 _duration) external onlyByOwnGov {
        require(_gauge_address != address(0));
        require(gauge_period_finish_time[_gauge_address] == 0);
        // require(_initial_period_finish_time >= block.timestamp);
        require(_duration > 0);
        gauge_whitelist[_gauge_address] = true;
        gauge_period_finish_time[_gauge_address] = _initial_period_finish_time;
        gauge_duration[_gauge_address] = _duration;
    }

    function setCurator(address _new_curator_address) external onlyByOwnGov {
        curator_address = _new_curator_address;
    }

    function setGaugeController(address _gauge_controller_address) external onlyByOwnGov {
        gauge_controller = IGaugeController(_gauge_controller_address);
    }

    /* ========== EVENTS ========== */

    event RewardDistributed(address indexed gauge_address, uint256 reward_amount);
    event RecoveredERC20(address token, uint256 amount);
    event GaugeStateChanged(address gauge_address, bool is_middleman, bool is_active);
    event DistributionsToggled(bool distibutions_state);
}
