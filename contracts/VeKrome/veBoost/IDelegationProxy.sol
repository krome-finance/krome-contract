// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IDelegationProxy {
  function adjusted_balance_of(address _account) external view returns(uint256);
}
