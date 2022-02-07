// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IPriceValidator {
    function isValidPrice(uint256 price) external view returns (bool);
    function requireValidPrice(uint256 price) external view;
}