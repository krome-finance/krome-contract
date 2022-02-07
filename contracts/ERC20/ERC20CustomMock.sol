// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ERC20Custom.sol";

// mock class using ERC20
contract ERC20CustomMock is ERC20Custom {
    string public symbol;
    string public name;
    uint8 public decimals;
 

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address initialAccount,
        uint256 initialBalance
    ) payable {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        if (initialAccount != address(0)) {
            _mint(initialAccount, initialBalance);
        }
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }

    function transferInternal(
        address from,
        address to,
        uint256 value
    ) public {
        _transfer(from, to, value);
    }

    function approveInternal(
        address owner,
        address spender,
        uint256 value
    ) public {
        _approve(owner, spender, value);
    }
}