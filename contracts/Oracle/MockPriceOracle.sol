// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockPriceOracle {
  uint8 public decimals;
  uint256 public price;

  constructor(uint8 _decimals, uint256 _price) {
    decimals = _decimals;
    price = _price;
  }

  function setDecimals(uint8 _decimals) external {
    decimals = _decimals;
  }

  function setPrice(uint256 _price) external {
    price = _price;
  }

  function getDecimals() external view returns (uint8) {
    return decimals;
  }

  function getLatestPrice() external view returns(uint256) {
    return price;
  }
}