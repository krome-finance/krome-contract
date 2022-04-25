// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKlevaStakePool {
    struct PoolInfo {
        address vaultToken;
        uint256 allocPoint;
        uint256 lastRewardBlockNumber;
        uint256 accRewardPerShare;
    }
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        address fundedBy;
    }
    function calcPendingReward(uint256 _pid, address _for) external view returns (uint256);
    function devFund() external view returns (address);
    function getPoolId(address tokenAddress) external view returns (uint256);
    function getPoolInfo(uint256 pid) external view returns (PoolInfo memory);
    function getRewardPerBlock() external view returns (uint256);
    function getTotalAllocPoint() external view returns (uint256);
    function getUserInfo(uint256 _pid, address _user) external view returns (UserInfo memory);
    function isDuplicatedPool(address vaultToken) external view returns (bool);
    function kevalToken() external view returns (address);
    function poolInfos(uint256) external view returns (
        address vaultToken,
        uint256 allocPoint,
        uint256 lastRewardBlockNumber,
        uint256 accRewardPerShare,
        bool isRealVault
    );
    function poolLength() external view returns (uint256);
    function rewardPerBlock() external view returns (uint256);
    function startBlock() external view returns (uint256);
    function totalAllocPoint() external view returns (uint256);
    function userInfos(uint256 _pid, address _user) 
        external 
        view 
        returns ( 
            uint256 amount, 
            uint256 rewardDebt, 
            address fundedBy 
        );
} 