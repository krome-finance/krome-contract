// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IEklipseGauge {
    function deposit(uint256 _amount) external;
    function withdraw(uint256 _amount) external;
    function userAppliedBoost(address) external view returns (uint256);
    function userInfo(address) external view returns (uint256 amount, uint256 rewardDept, uint256 postEKLRewardDept);
    function pendingEKL(address) external view returns (uint256);
    function pendingPostEKL(address) external view returns (uint256);
    function calculateBoost(address _user) external view returns (uint256);
}
