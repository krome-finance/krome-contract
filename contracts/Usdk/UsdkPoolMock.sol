// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

contract UsdkPoolMock {
  address public admin;
  uint256 public collatDollarBalance;

  constructor(uint256 _balance) {
    admin = msg.sender;
    collatDollarBalance = _balance;
  }

  function setBalance(uint256 _balance) external {
    collatDollarBalance = _balance;
  }

  function executeTransaction(address target, uint value, string memory signature, bytes memory data) public payable returns (bytes memory) {
    require(msg.sender == admin, "Timelock::executeTransaction: Call must come from admin.");

    bytes memory callData;

    if (bytes(signature).length == 0) {
        callData = data;
    } else {
        callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
    }

    // Execute the call
    (bool success, bytes memory returnData) = target.call{ value: value }(callData);
    require(success, "Timelock::executeTransaction: Transaction execution reverted.");

    emit ExecuteTransaction(target, value, signature, data);

    return returnData;
  }

  event ExecuteTransaction(address indexed target, uint value, string signature,  bytes data);
}