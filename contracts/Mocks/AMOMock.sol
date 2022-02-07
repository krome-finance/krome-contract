// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Libs/TransferHelper.sol";
import "../Common/Owned.sol";

contract AMOMock is Owned {
    uint256 public usdk_balance;
    uint256 public collat_balance;
    constructor(uint256 _usdk_balance, uint256 _collat_balance) Owned(msg.sender) {
      usdk_balance = _usdk_balance;
      collat_balance = _collat_balance;
    }

    function dollarBalances() external view returns (uint256, uint256) {
      return (usdk_balance, collat_balance);
    }

    function setUsdkBalance(uint256 _v) external {
      usdk_balance = _v;
    }

    function setCollatBalance(uint256 _v) external {
      collat_balance = _v;
    }

    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        // require(success, "execute failed");
        require(success, success ? "" : _getRevertMsg(result));
        return (success, result);
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "AMOMock::executeTransaction: Transaction execution reverted.";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }
}