// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IEklipseDelegator {
    function withdraw(uint256 amount) external;
    function deposit(uint256 amount) external;
    function manage() external;
}