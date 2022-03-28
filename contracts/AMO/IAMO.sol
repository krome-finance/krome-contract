// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAMO {
    function dollarBalances() external view returns (uint256 usdk_val_e18, uint256 collat_val_e18);
}
