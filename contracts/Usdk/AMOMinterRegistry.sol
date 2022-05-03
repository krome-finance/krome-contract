// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/LocatorBasedProxyV2.sol";

contract AMOMinterRegistry is LocatorBasedProxyV2 {
    address[] public amo_minters;
    mapping(address => uint256) public amo_minter_orders;

    /* ========== MODIFIERS ========== */

    modifier onlyByManager() {
        managerPermissionRequired();
        _;
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _locator, address[] calldata _amo_minters) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);

        for (uint256 i = 0; i < _amo_minters.length; i++) {
            amo_minters.push(_amo_minters[i]);
            amo_minter_orders[_amo_minters[i]] = i + 1;
        }
    }

    /* ============ view ============== */

    function isAMOMinter(address _address) external view returns (bool) {
        return amo_minter_orders[_address] > 0;
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

    event AddAMOMinter(address);
    event RemoveAMOMinter(address);
}