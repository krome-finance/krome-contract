// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// it should have no state variables!! called by delegatecall
interface ITokenSwapHelper {
  function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut) external returns (uint256 spent, uint256 received);
}