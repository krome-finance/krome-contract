// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IStakingTreasury {
    function calcCurCombinedWeight(address /* account */) external view 
        returns (
            uint256,  //  avg_combined_weight
            uint256   //  new_combined_weight
        );
    function calcCurCombinedWeightWrite(address /* account */) external
        returns (
            uint256   //  new_combined_weight
        );

    function usdkPerLPToken() external view returns (uint256);
    function totalLiquidityLocked() external view returns (uint256);
    function lockedLiquidityOf(address account) external view returns (uint256);

    function sync() external;
}