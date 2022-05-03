// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/LocatorBasedProxyV2.sol";
import "../Libs/TransferHelper.sol";
import "./IUsdkPool.sol";

contract AMOMinterDelegator is LocatorBasedProxyV2 {
    address public collateral_address;
    address public pool_address;
    uint256 public col_idx;
    address[] public amo_minters;
    mapping(address => uint256) public amo_minter_orders;

    /* ========== MODIFIERS ========== */

    modifier onlyByManager() {
        managerPermissionRequired();
        _;
    }

    modifier onlyAMOMinter() {
        require(amo_minter_orders[msg.sender] > 0, "not AMO mitner");
        _;
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _locator, address _pool_address, uint256 _col_idx, address[] calldata _amo_minters) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);

        pool_address = _pool_address;
        col_idx = _col_idx;

        collateral_address = IUsdkPool(_pool_address).collateral_addresses(_col_idx);

        for (uint256 i = 0; i < _amo_minters.length; i++) {
            amo_minters.push(_amo_minters[i]);
            amo_minter_orders[_amo_minters[i]] = i + 1;
        }
    }

    /* ============ Fake view ============== */

    function collatDollarBalance() external pure returns (uint256) {
        return 0;
    }

    /* ============ Main ============== */

    function amoMinterBorrow(uint256 amount) external onlyAMOMinter {
        IUsdkPool(pool_address).amoMinterBorrow(amount);

        TransferHelper.safeTransfer(collateral_address, msg.sender, amount);
    }

    function amoMinterBorrowTo(address recipient, uint256 amount) external onlyAMOMinter {
        IUsdkPool(pool_address).amoMinterBorrow(amount);

        TransferHelper.safeTransfer(collateral_address, recipient, amount);
    }

    /* ============ Only MANAGER ============== */

    function addAMOMinter(address _minter_address) external onlyByManager {
        require(amo_minter_orders[_minter_address] == 0, "duplicated");
        amo_minters.push(_minter_address);
        amo_minter_orders[_minter_address] = amo_minters.length;

        emit AddAMOMinter(_minter_address);
    }

    function removeAMOMinter(address _minter_address) external onlyByManager {
        require(amo_minter_orders[_minter_address] > 0, "duplicated");
        uint256 minter_idx = amo_minter_orders[_minter_address] - 1;
        uint256 last_idx = amo_minters.length - 1;
        if (minter_idx != last_idx) {
            address last_minter = amo_minters[last_idx];
            amo_minters[minter_idx] = last_minter;
            amo_minter_orders[last_minter] = minter_idx + 1;
        }
        amo_minters.pop();
        amo_minter_orders[_minter_address] = 0;

        emit RemoveAMOMinter(_minter_address);
    }

    function setPool(address _pool_address, uint256 _col_idx) external onlyByManager {
        require(IUsdkPool(_pool_address).collateral_addresses(_col_idx) == collateral_address, "Collateral is not matched");
        pool_address = _pool_address;
        col_idx = _col_idx;

        emit SetPool(_pool_address, _col_idx);
    }

    event AddAMOMinter(address);
    event RemoveAMOMinter(address);
    event SetPool(address, uint256);
}