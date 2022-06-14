// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract I4ISwapMock {
    address public token;

    constructor(address _lp_token) {
        token = _lp_token;
    }

    function coinIndex(address coin) external pure returns (uint256) {
        require(coin != address(0));
        return 0;
    }
    function balances(uint256 i) external view returns (uint256) {
        require(i == 0);
        return IERC20(token).totalSupply() / 2;
    }

    function getVirtualPrice() external pure returns (uint256) {
        return 1e18;
    }
}