// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./IAMO.sol";
import "../Common/LocatorBasedProxy.sol";
import "../Usdk/IAMOMinter.sol";
import "../Libs/TransferHelper.sol";

abstract contract ExternalCollateralWalletAMO is LocatorBasedProxy, IAMO {

    /* ========== CONFIGURATION ========== */
    IAMOMinter public amo_minter;
    address public external_wallet_address;

    /* ========== STATE VARIABLES ========== */

    uint256 public borrowedCollat;
    uint256 public returnedCollat;

    /* ========== MODIFIERS ========== */

    modifier onlyByManager {
        managerPermissionRequired();
        _;
    }

    modifier onlyByExtWallet {
        require(msgByManager() || msg.sender == external_wallet_address, "Not owner or timelock");
        _;
    }

    /* ========== INITIALIZER ========== */

    function initializeExternalWalletAMO(
        address _locator_address,
        address _amo_minter,
        address _external_wallet
    ) internal initializer {
        LocatorBasedProxy.initializeLocatorBasedProxy(_locator_address);
        
        amo_minter = IAMOMinter(_amo_minter);
        external_wallet_address = _external_wallet;
    }

    /* ========== FINANCIAL VIEW ========== */

    function netBalances() external view returns (
        uint256 collat_exported,
        uint256 collat_imported
    ) {
        collat_exported = borrowedCollat > returnedCollat ? borrowedCollat - returnedCollat : 0;
        collat_imported = returnedCollat > borrowedCollat ? returnedCollat - borrowedCollat : 0;
    }

    /* ========== AMO ========== */


    function borrowCollat(uint256 amount) external onlyByExtWallet {
        TransferHelper.safeTransfer(amo_minter.collateral_address(), external_wallet_address, amount);
        borrowedCollat += amount;
        emit BorrowCollat(amount, borrowedCollat);
    }

    function returnCollat(uint256 amount) external onlyByExtWallet {
        address collat_address = amo_minter.collateral_address();
        TransferHelper.safeApprove(collat_address, address(amo_minter), amount);
        amo_minter.receiveCollatFromAMO(amount);
        returnedCollat += amount;
        emit ReturnCollat(amount, returnedCollat);
    }

    /* ========== MANAGEMENT ========== */

    function setExternalWallet(address wallet_address) external onlyByManager {
        external_wallet_address = wallet_address;
        emit SetExternalWallet(wallet_address);
    }

    /* ========== EMERGENCY ========== */

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByManager {
        TransferHelper.safeTransfer(_token, payable(msg.sender), amount);
        emit RecoverERC20(_token, payable(msg.sender), amount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByManager returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        // require(success, "execute failed");
        require(success, success ? "" : _getRevertMsg(result));
        return (success, result);
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "executeTransaction: Transaction execution reverted.";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }


    event SetExternalWallet(address);
    event RecoverERC20(address token, address to, uint256 amount);
    event BorrowCollat(uint256, uint256);
    event ReturnCollat(uint256, uint256);

    uint256[49] private __gap;
}