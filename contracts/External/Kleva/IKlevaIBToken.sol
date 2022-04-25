// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IKlevaIBToken {
    function allowance(address owner, address spender) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    function baseTokenAddress() external view returns (address);
    function calcPendingInterest(uint256 pendingAmount) external view returns (uint256);
    function convertDebtAmountToShare(uint256 debtAmount) external view returns (uint256);
    function convertDebtShareToAmount(uint256 debtShare) external view returns (uint256);
    function crLowerLimitBps() external view returns (uint256);
    function debtFairLaunchPoolId() external view returns (uint256);
    function debtTokenAddress() external view returns (address);
    function fairLaunchAddress() external view returns (address);
    function getBaseTokenAddress() external view returns (address);
    function getPrevUtilizationRates() external view returns (
        uint256, uint256, uint256, uint256
    );
    function getTotalToken() external view returns (uint256);
    function isBaseTokenWrappedKlay() external view returns (bool);
    function isKillable(uint256 positionid) external view returns (bool);
    function isWrappedKlay(address address_) external view returns (bool);
    function lastAccureTime() external view returns (uint256);
    function lastSavedUtilizationRateTime() external view returns (uint256);
    function minTotalSupply() external view returns (uint256);
    function paused() external view returns (bool);
    function positionInfo(uint256 id) external view returns (uint256, uint256);
    function positions(uint256) external view returns (
        address workerAddress,
        address ownerAddress,
        uint256 debtShare
    );
    function positionsLength() external view returns (uint256);
    function reservePool() external view returns (uint256);
    function totalDebtAmount() external view returns (uint256);
    function totalDebtShare() external view returns (uint256);
    function utilizationRate0() external view returns (uint256);
    function utilizationRate1() external view returns (uint256);
    function utilizationRate2() external view returns (uint256);
    function vaultBalance() external view returns (uint256);
    function vaultConfig() external view returns (address);
} 