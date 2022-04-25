// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKokoaBond {
    function toTokenAmount(uint256 bondAmount) external view returns (uint256 tokenAmount);
}
 