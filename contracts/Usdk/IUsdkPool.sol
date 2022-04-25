// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IUsdkPool {
    function getKromePrice() external view returns (uint256);
    function getUsdkPrice() external view returns (uint256);
    function buybackAvailableCollat() external view returns (uint256);
    function collateralAddrToIdx(address) external view returns (uint256);
    function enabled_collaterals(address) external view returns (bool);
    function collateral_prices(uint256) external view returns (uint256);
    function amoMinterBorrow(uint256 collateral_amount) external;

    // // by UsdkPoolHelper
    // function getUsdkInCollateral(uint256 col_idx, uint256 usdk_amount) external view returns (uint256);
    // function getKromePrice() external view returns (uint256);
    // function minting_fee(uint256 col_idx) external view returns (uint256);
}