// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICollatBalance {
  function collatDollarBalance() external view returns (uint256 balance_tally);
}
