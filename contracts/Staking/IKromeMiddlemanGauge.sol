// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// for crosschain
interface IKromeMiddlemanGauge {
  function pullAndBridge(uint256 reward_amount) external;
}