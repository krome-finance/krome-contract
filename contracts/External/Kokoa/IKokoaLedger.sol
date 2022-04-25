// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKokoaLedger {
    function accountInfo(bytes32,address) external view returns (uint256 lockedCollateral, uint256 loan);
}
 