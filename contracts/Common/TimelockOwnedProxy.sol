// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

// https://docs.synthetix.io/contracts/Owned
abstract contract TimelockOwnedProxy is Initializable {
    address public owner;
    address public nominatedOwner;
    address public timelock_address;

    function initializeTimelockOwned(address _owner, address _timelock_address) internal initializer {
        require(_owner != address(0), "Owner address cannot be 0");
        owner = _owner;
        timelock_address = _timelock_address;

        emit OwnerChanged(address(0), _owner);
    }

    function nominateNewOwner(address _owner) external {
        require(msg.sender == owner, "Only the contract owner may perform this action");
        nominatedOwner = _owner;
        emit OwnerNominated(_owner);
    }

    function acceptOwnership() external {
        require(msg.sender == nominatedOwner, "You must be nominated before you can accept ownership");
        emit OwnerChanged(owner, nominatedOwner);
        owner = nominatedOwner;
        nominatedOwner = address(0);
    }

    function setTimelock(address new_timelock) external
    {
        require(msg.sender == owner || msg.sender == timelock_address, "Only the contract owner or timelock may perform this action");
        require(new_timelock != address(0), "Zero address detected");

        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    event OwnerNominated(address newOwner);
    event OwnerNominationRevoked(address newOwner);
    event OwnerChanged(address oldOwner, address newOwner);
    event TimelockSet(address new_timelock);

    uint256[49] private __gap;
} 