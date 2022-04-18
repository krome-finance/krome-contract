// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IEklipseLock {
    function totalVekl() external view returns (uint256);
    function userInfo(address) external view returns (uint256 amount, uint256 lockStarted, uint256 period, uint256 lastFeeClaimed);
    function addLock(uint256 _amount, uint256 _period) external;
    function withdrawEkl() external;
    function getUserVekl(address _address) external view returns (uint256);
    function withdrawFeeReward() external;
    function calculateFeeReward(address _address) external view returns (uint256);
}