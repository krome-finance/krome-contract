// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Libs/TransferHelper.sol";
import "../Common/Owned.sol";

contract SwapMock is Owned {
  constructor() Owned(msg.sender) {
  }

  function swap(address _tokenIn, uint256 _amountIn, address _tokenOut, uint256 _amountOut) external {
      TransferHelper.safeTransferFrom(_tokenIn, msg.sender, address(this), _amountIn);
      TransferHelper.safeTransfer(_tokenOut, msg.sender, _amountOut);
  }
}