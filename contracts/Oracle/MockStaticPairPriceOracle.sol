// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockStaticPairPriceOracle {
  address public token;
  uint256 public amountIn;
  uint256 public price;

  constructor(address _token, uint256 _amountIn, uint256 _price) {
    token = _token;
    amountIn = _amountIn;
    price = _price;
  }

  function consult(address _token, uint256 _amountIn) external view returns (uint256 amountOut) {
    require(token == _token, "Invalid token");
    require(amountIn == _amountIn, "Invalid amoount");
    amountOut = price;
  }

  function setPrice(uint256 _price) external {
    price = _price;
  }
}