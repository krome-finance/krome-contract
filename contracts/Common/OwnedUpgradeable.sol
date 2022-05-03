// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

// https://docs.synthetix.io/contracts/Owned
abstract contract OwnedUpgradeable is Initializable,  ContextUpgradeable{
    address private _owner;
    address public nominatedOwner;

    function __Owned_init(address _owner_address) internal onlyInitializing {
        __Owned_init_unchained(_owner_address);
    }

    function __Owned_init_unchained(address _owner_address) internal onlyInitializing {
        require(_owner_address != address(0), "Owner address cannot be 0");
        _owner = _owner_address;

        emit OwnerChanged(address(0), _owner);
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function nominateNewOwner(address _owner_address) external onlyOwner {
        nominatedOwner = _owner_address;
        emit OwnerNominated(_owner);
    }

    function acceptOwnership() external {
        require(_msgSender() == nominatedOwner, "You must be nominated before you can accept ownership");
        emit OwnerChanged(_owner, nominatedOwner);
        _owner = nominatedOwner;
        nominatedOwner = address(0);
    }

    modifier onlyOwner {
        require(_msgSender() == _owner, "Only the contract owner may perform this action");
        _;
    }

    event OwnerNominated(address newOwner);
    event OwnerNominationRevoked(address newOwner);
    event OwnerChanged(address oldOwner, address newOwner);

    uint256[48] private __gap;
}