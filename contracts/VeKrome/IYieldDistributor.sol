// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IYieldDistributor {
  function notifyRewardAmount(uint256 amount) external;
}