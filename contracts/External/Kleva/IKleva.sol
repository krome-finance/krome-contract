// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKleva {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function calcUnlockableAmount(address account) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function paused() external view returns (bool);
    function endReleaseBlock() external view returns (uint256);
    function lastUnlockBlock() external view returns (uint256);
    function lockOf(address account) external view returns (uint256);
    function manualMinted() external view returns (uint256);
    function rightMinter() external view returns (address);
    function startReleaseBlock() external view returns (uint256);
    function totalLock() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function unlockedSupply() external view returns (uint256);
} 