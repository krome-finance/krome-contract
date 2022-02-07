// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ExecutorMock {
    address public admin;

    constructor() {
        admin = msg.sender;
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
        require(success, success ? "" : _getRevertMsg(returnData));

        emit ExecuteTransaction(target, value, signature, data);

        return returnData;
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return 'Transaction reverted silently';

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }


    event ExecuteTransaction(address indexed target, uint value, string signature,  bytes data);
}