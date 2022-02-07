// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Owned.sol";
import "../Libs/TransferHelper.sol";

// only for test
contract GaugeMock is Owned {
  constructor () Owned(msg.sender) { }

  function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
      // Only the owner address can ever receive the recovery withdrawal
      TransferHelper.safeTransfer(tokenAddress, owner, tokenAmount);
      emit RecoveredERC20(tokenAddress, tokenAmount);
  }


  event RecoveredERC20(address token, uint256 amount);
}