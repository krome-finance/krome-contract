// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../AddressLocator/IAddressLocator.sol";

// https://docs.synthetix.io/contracts/Owned
abstract contract LocatorBasedProxyV2 is Initializable {
    /* ========== CONFIGURATION ========== */
    IAddressLocator public locator;
    address public local_manager_address;
    address public owner;
    address public timelock_address;

    /* ========== INITIALIZER ========== */

    function initializeLocatorBasedProxy(
        address _locator_address
    ) internal initializer {
        locator = IAddressLocator(_locator_address);

        // for gas saving
        owner = payable(locator.owner_address());
        timelock_address = payable(locator.timelock());
    }

    /* ========== MANAGEMENT ========== */

    function msgByManager() internal view returns (bool) {
        return payable(msg.sender) == owner || payable(msg.sender) == timelock_address || (local_manager_address != address(0) && payable(msg.sender) == local_manager_address);
    }

    function managerPermissionRequired() internal view {
        require(msgByManager(), "Not manager");
    }

    function setLocator(address _locator_address) external {
        managerPermissionRequired();
        locator = IAddressLocator(_locator_address);

        syncOwnership();

        emit SetLocator(_locator_address);
    }

    // no permission required, ownership should be guarded by locator & setLocator
    function syncOwnership() public {
        owner = payable(locator.owner_address());
        timelock_address = payable(locator.timelock());
    }

    function setLocalManager(address _address) external {
        managerPermissionRequired();
        local_manager_address = _address;

        emit SetLocalManager(_address);
    }

    event SetLocator(address);
    event SetLocalManager(address);

    uint256[47] private __gap;
} 