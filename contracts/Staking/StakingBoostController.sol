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
// ======================= StakingBoostController ==========================
// =========================================================================

import "../Common/TimelockOwned.sol";
import "../VeKrome/IveKrome.sol";
import "../VeKrome/veBoost/IDelegationProxy.sol";

contract StakingBoostController is TimelockOwned {
    /* =========== CONSTANTS ================== */
    // Constant for various precisions
    uint256 public constant MULTIPLIER_PRECISION = 1e18;

    /* =========== IMMUTABLES ================== */
    IveKrome immutable veKROME;
    IDelegationProxy private veKromeBoostDlgPxy;

    /* =========== SETTINGS ================== */

    // Lock time and multiplier settings
    uint256 public lock_max_multiplier = uint256(3e18); // E18. 1x = e18
    uint256 public lock_time_for_max_multiplier = 3 * 365 * 86400; // 3 years
    uint256 public lock_time_min = 86400; // 1 * 86400  (1 day)

    // veKROME related
    uint256 public vekrome_boost_scale_factor = uint256(4e18); // E18. 4x = 4e18; 100 / scale_factor = % vekrome supply needed for max boost
    uint256 public vekrome_max_multiplier = uint256(2e18); // E18. 1x = 1e18
    uint256 public vekrome_per_usdk_for_max_boost = uint256(24e18); // E18. 24e18 means 24 veKROME must be held by the staker per 1 USDK

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _timelock_address,
        address _veKrome,
        address _delegation_proxy
    ) TimelockOwned(_owner, _timelock_address) {
        veKROME = IveKrome(_veKrome);
        veKromeBoostDlgPxy = IDelegationProxy(_delegation_proxy);
    }

    /* =============== VIEWS =============== */

    // Multiplier amount, given the length of the lock 1x ~ (1 + lock_max_multiplier)x
    function lockMultiplier(uint256 secs) external view returns (uint256) {
        require(secs >= lock_time_min, "Minimum stake time not met");
        require(secs <= lock_time_for_max_multiplier, "Trying to lock for too long");

        uint256 lock_multiplier =
            uint256(MULTIPLIER_PRECISION) + (
                (secs * (lock_max_multiplier - MULTIPLIER_PRECISION)) / lock_time_for_max_multiplier
            );
        if (lock_multiplier > lock_max_multiplier) lock_multiplier = lock_max_multiplier;
        return lock_multiplier;
    }

    function minVeKromeForMaxBoost(uint256 stakedUsdk) public view returns (uint256) {
        return (stakedUsdk * vekrome_per_usdk_for_max_boost) / MULTIPLIER_PRECISION;
    }

    // vekrome_multiplier will be max value for max_value_period, then decreased to 0 by dslope/sec
    function veKromeMultiplier(address account, uint256 stakedUsdk) external view returns (uint256 vekrome_multiplier, uint256 dslope, uint256 stay_time) {
        // uint256 vekrome_balance = veKromeBoostDlgPxy.adjusted_balance_of(account);
        uint256 vekrome_balance = veKROME.balanceOf(account);
        if (vekrome_balance == 0) return (0, 0, 0);

        uint256 lock_time = veKROME.locked__end(account) - block.timestamp;
        // First option based on fraction of total veKROME supply, with an added scale factor
        uint256 mult_op_1 = (vekrome_balance * vekrome_max_multiplier * vekrome_boost_scale_factor) 
                            / (veKROME.totalSupply() * MULTIPLIER_PRECISION);

        // Second based on old method, where the amount of USDK staked comes into play
        uint256 mult_op_2;
        {
            uint256 veKROME_needed_for_max_boost = minVeKromeForMaxBoost(stakedUsdk);
            if (veKROME_needed_for_max_boost > 0){ 
                uint256 user_vekrome_fraction = vekrome_balance * MULTIPLIER_PRECISION / veKROME_needed_for_max_boost;
                
                mult_op_2 = (user_vekrome_fraction * vekrome_max_multiplier) / MULTIPLIER_PRECISION;
            } else {
                mult_op_2 = 0; // This will happen with the first stake, when user_staked_usdk is 0
            }
        }

        // Select the higher of the two
        vekrome_multiplier = mult_op_1 > mult_op_2 ? mult_op_1 : mult_op_2;

        dslope = lock_time > 0 ? vekrome_multiplier / lock_time : 0;
        stay_time = vekrome_multiplier > vekrome_max_multiplier && dslope > 0 ? lock_time - (vekrome_max_multiplier / dslope) : 0;

        // Cap the boost to the vekrome_max_multiplier
        if (vekrome_multiplier > vekrome_max_multiplier) vekrome_multiplier = vekrome_max_multiplier;
    }

    /* =============== MUTATIVE FUNCTIONS =============== */

    function setLockMaxMultiplier(uint256 _lock_max_multiplier) external onlyByOwnGov {
        require(_lock_max_multiplier >= MULTIPLIER_PRECISION, "Mult must be >= MULTIPLIER_PRECISION");
        lock_max_multiplier = _lock_max_multiplier;
    }

    function setVeKromeMaxMultiplier(uint256 _vekrome_max_multiplier) external onlyByOwnGov {
        require(_vekrome_max_multiplier >= 0, "veKROME mul must be >= 0");
        vekrome_max_multiplier = _vekrome_max_multiplier;
    }

    function setVeKromePerUsdkForMaxBoost(uint256 _vekrome_per_usdk_for_max_boost) external onlyByOwnGov {
        require(_vekrome_per_usdk_for_max_boost > 0, "veKROME pct max must be > 0");
        vekrome_per_usdk_for_max_boost = _vekrome_per_usdk_for_max_boost;
    }

    function setVeKromeBoostScaleFactor(uint256 _vekrome_boost_scale_factor) external onlyByOwnGov {
        require(_vekrome_boost_scale_factor > 0, "veKROME boost scale factor must be > 0");
        vekrome_boost_scale_factor = _vekrome_boost_scale_factor;
    }

    function setMultipliers(
        uint256 _lock_max_multiplier, 
        uint256 _vekrome_max_multiplier, 
        uint256 _vekrome_per_usdk_for_max_boost,
        uint256 _vekrome_boost_scale_factor
    ) external onlyByOwnGov {
        require(_lock_max_multiplier >= MULTIPLIER_PRECISION, "Mult must be >= MULTIPLIER_PRECISION");
        require(_vekrome_max_multiplier >= 0, "veKROME mul must be >= 0");
        require(_vekrome_per_usdk_for_max_boost > 0, "veKROME pct max must be > 0");
        require(_vekrome_boost_scale_factor > 0, "veKROME boost scale factor must be > 0");

        lock_max_multiplier = _lock_max_multiplier;
        vekrome_max_multiplier = _vekrome_max_multiplier;
        vekrome_per_usdk_for_max_boost = _vekrome_per_usdk_for_max_boost;
        vekrome_boost_scale_factor = _vekrome_boost_scale_factor;
    }

    function setLockedStakeTimeForMinAndMaxMultiplier(uint256 _lock_time_for_max_multiplier, uint256 _lock_time_min) external onlyByOwnGov {
        require(_lock_time_for_max_multiplier >= 1, "Mul max time must be >= 1");
        require(_lock_time_min >= 1, "Mul min time must be >= 1");

        lock_time_for_max_multiplier = _lock_time_for_max_multiplier;
        lock_time_min = _lock_time_min;
    }

    // Set the veKromeBoostDelegationProxy
    function setBoostDelegationProxy(address _dlg_pxy_addr) external onlyByOwnGov {
        veKromeBoostDlgPxy = IDelegationProxy(_dlg_pxy_addr);
    }

}