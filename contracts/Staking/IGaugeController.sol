// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IGaugeController {
  function global_emission_rate() external view returns(uint256);
  function time_total() external view returns(uint256);
  function gauge_relative_weight(address addr, uint256 time) external view returns (uint256);
  function gauge_relative_weight_write(address addr, uint256 time) external returns(uint256);
}
