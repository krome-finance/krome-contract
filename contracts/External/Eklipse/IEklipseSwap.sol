// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IEklipseSwap {
  function tokenIndexes(uint8) external view returns (address);
  function getTokens() external view returns (address[] memory);
  function getToken(uint8) external view returns (address);
  function getLpToken() external view returns (address);
  function getTokenIndex(address) external view returns (uint8);
  function getTokenBalances() external view returns (uint256[] memory);
  function getTokenBalance(uint8) external view returns (uint256);
  function getNumberOfTokens() external view returns (uint256);
  function getVirtualPrice() external view returns (uint256);
  function addLiquidity(uint256[] calldata amounts, uint256 minToMint, uint256 deadline) external returns (uint256);
  function calculateTokenAmount(uint256[] calldata amounts, bool deposit) external view returns (uint256);
  function removeLiquidity(uint256 amount, uint256[] calldata minAmounts, uint256 deadline) external returns (uint256[] memory);
  function calculateRemoveLiquidity(address account, uint256 amount) external view returns (uint256[] memory);
  function calculateRemoveLiquidityOneToken(address account, uint256 amount, uint8 index) external view returns (uint256);
  function swap(uint8 fromIndex, uint8 toIndex, uint256 inAmount, uint256 minOutAmount, uint256 deadline) external returns (uint256);
}
