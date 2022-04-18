// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILpPricedPool {
    function getVirtualPrice() external view returns(uint256);
}