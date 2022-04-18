// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "../../ERC20/IERC20.sol";

interface IEKLP is IERC20 {
    function minter() external view returns (address);
}
