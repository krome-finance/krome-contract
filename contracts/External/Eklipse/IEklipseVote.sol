// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IEklipseVote {
    function voteForGauge(address _gaugeAddress, uint256 _amount) external;
    function getPortion(uint256 week, address _gaugeADdress) external view returns (uint256, uint256);
    function currentWeek() external view returns (uint256);
    function getLeftVotingPower(address _user) external view returns (uint256);
}