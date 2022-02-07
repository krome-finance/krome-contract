// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGaugeRewardsDistributor {
  function distributeReward(address gauge_address) external returns (uint256 weeks_elapsed, uint256 reward_tally);
}