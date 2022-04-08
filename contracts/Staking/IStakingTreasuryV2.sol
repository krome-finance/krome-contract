// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStakingTreasuryV2 {
    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }

    function userStakedUsdk(address account) external view returns (uint256);
    function usdkPerLPToken() external view returns (uint256);
    function totalLiquidityLocked() external view returns (uint256);
    function lockedStakesOf(address account) external view returns (LockedStake[] memory);
    function lockedLiquidityOf(address account) external view returns (uint256);
    function boost_controller() external view returns (address);
    function veKromeMultiplier(address account) external view returns (uint256 ve_multiplier, uint256 slope, uint256 stay_time);

    function sync() external;
}