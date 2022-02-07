// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Owned.sol";
import "../ERC20/IERC20.sol";
import "../Oracle/IPriceOracle.sol";
import "../Libs/TransferHelper.sol";

interface ISwap {
  function swap(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut) external;
}

contract TokenSwapHelperMock is Owned {
  uint256 internal immutable PRECISION = 10**6;
  IPriceOracle internal immutable usdk_price_oracle;
  IPriceOracle internal immutable krome_price_oracle;
  uint256 internal immutable usdk_price_precision;
  uint256 internal immutable krome_price_precision;
  address internal immutable swap_address;

  constructor(
    address _usdk_price_oracle,
    address _krome_price_oracle,
    address _swap
  ) Owned(msg.sender) {
    usdk_price_oracle = IPriceOracle(_usdk_price_oracle);
    usdk_price_precision = 10 ** usdk_price_oracle.getDecimals();
    krome_price_oracle = IPriceOracle(_krome_price_oracle);
    krome_price_precision = 10 ** krome_price_oracle.getDecimals();
    swap_address = _swap;
    // amo_minter = _amo_minter;
  }

  // swap usdk -> krome delegatecall
  function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut) external returns (uint256 spent, uint256 received) {
    spent = amountIn;
    received = minAmountOut;

    IERC20(tokenIn).approve(swap_address, spent);
    ISwap(swap_address).swap(tokenIn, spent, tokenOut, received);

    emit Swap(spent, received);
  }

  function calculate(uint256 amount, uint256 max_slippage) external view returns (uint256 spent, uint256 received) {
    spent = amount;
    received = amount * (usdk_price_oracle.getLatestPrice() * PRECISION / usdk_price_precision) / (krome_price_oracle.getLatestPrice() * PRECISION / krome_price_precision);
    received = received - (received * max_slippage / 1e6);
  }

  function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
      TransferHelper.safeTransfer(address(tokenAddress), msg.sender, tokenAmount);
  }

  event Swap(uint256 spent, uint256 received);
}