// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "../AddressLocator/IAddressLocator.sol";

// https://docs.synthetix.io/contracts/Owned
abstract contract LocatorBasedProxy is Initializable {
    /* ========== CONFIGURATION ========== */
    IAddressLocator public locator;
    address public local_manager_address;

    /* ========== INITIALIZER ========== */

    function initializeLocatorBasedProxy(
        address _locator_address
    ) internal initializer {
        locator = IAddressLocator(_locator_address);
    }

    /* ========== VIEWS ========== */

    function owner() public view returns (address) {
        return locator.owner_address();
    }

    function timelock_address() public view returns (address) {
        return locator.timelock();
    }

    /* ========== MANAGEMENT ========== */

    function setLocator(address _locator_address) external {
        require(msg.sender == owner() || msg.sender == timelock_address(), "Not owner or timelock");
        locator = IAddressLocator(_locator_address);
        emit SetLocator(_locator_address);
    }

    function msgByManager() internal view returns (bool) {
        return msg.sender == owner() || msg.sender == timelock_address() || (local_manager_address != address(0) && msg.sender == local_manager_address);
    }

    function managerPermissionRequired() internal view {
        require(msgByManager(), "Not manager");
    }

    function setLocalManager(address _address) external {
        managerPermissionRequired();
        local_manager_address = _address;

        emit SetLocalManager(_address);
    }

    event SetLocator(address);
    event SetLocalManager(address);

    uint256[49] private __gap;
} 