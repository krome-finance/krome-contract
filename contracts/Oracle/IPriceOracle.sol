// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPriceOracle {
    function getLatestPrice() external view returns (uint256);
    function getDecimals() external view returns (uint8);
}