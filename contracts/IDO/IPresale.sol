// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPresale {
  function tokenAmount() external returns (uint256);
  function getPurchaseLimit() external view returns (uint256);
  function getPurchaseAmount(address) external view returns (uint256);
}