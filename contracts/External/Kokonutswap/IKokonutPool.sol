// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKokonutPool {
    function getVirtualPrice() external view returns (uint256);
}