// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../External/Claimswap/IUniswapV2Router02.sol";

// it should have no state variables!! called by delegatecall
contract ClaimswapHelper {
    address public immutable claimswap_router;

    constructor(
        address _claimswap_router
    ) {
        claimswap_router = _claimswap_router;
    }

    // swap usdk -> krome delegatecall
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 minAmountOut) external returns (uint256 spent, uint256 received) {
        address[] memory PATH = new address[](2);
        PATH[0] = tokenIn;
        PATH[1] = tokenOut;

        // Buy some KROME with USDK
        (uint[] memory amounts) = IUniswapV2Router02(claimswap_router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            PATH,
            address(this),
            block.timestamp + 604800 // Expiration: 7 days from now
        );
        return (amounts[0], amounts[1]);
    }
}