// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKLAYSwapUtil {
    function getPendingReward(address lp, address user) external view returns (
      uint256 kspReward,
      uint256 airDropCount,
      address[] memory airdropTokens,
      uint256[] memory adirdropRewards
    );
}