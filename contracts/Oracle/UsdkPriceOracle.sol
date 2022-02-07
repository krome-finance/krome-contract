// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./BenchmarkedPriceOracle.sol";
import "./IPairPriceOracle.sol";
import "./IPriceOracle.sol";

interface IPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    // function price0CumulativeLast() external view returns (uint256);
    // function price1CumulativeLast() external view returns (uint256);
}

contract UsdkPriceOracle is BenchmarkedPriceOracle, IPairPriceOracle, IPriceOracle {
    uint256 private constant PRICE_PRECISION = 10 ** 9;
    uint256 private constant Q112 = 2**112;

    address private immutable usdk_address;
    IPriceOracle private immutable oracle_klay_usd;
    IPair private immutable pair_usdk_klay;

    uint256 private immutable klay_price_precision;

    bool private immutable isUsdk0ForKlay;

    constructor(
        address _usdk_address,
        address _oracle_klay_usd,
        address _pair_usdk_klay
    ) BenchmarkedPriceOracle(msg.sender) {
        usdk_address = _usdk_address;
        oracle_klay_usd = IPriceOracle(_oracle_klay_usd);
        pair_usdk_klay = IPair(_pair_usdk_klay);

        klay_price_precision = 10 ** oracle_klay_usd.getDecimals();

        isUsdk0ForKlay = pair_usdk_klay.token0() == _usdk_address;
    }

    function klayPrice1() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_klay.getReserves();
        return uint256(reserve0) * Q112 / uint256(reserve1);
    }

    function klayPrice0() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_klay.getReserves();
        return uint256(reserve1) * Q112 / uint256(reserve0);
    }

    // for USD price
    function getDecimals() external pure override returns (uint8) {
        return 9;
    }

    // price0 = reserve1/reserve0  3:1 = 3
    // in USD e9
    function getLatestPrice() public view override(BenchmarkedPriceOracle, IPriceOracle) returns (uint256 price) {
        // UQ112x112 -> E9
        uint256 usdkToKlay = (isUsdk0ForKlay ? klayPrice0() : klayPrice1()) * PRICE_PRECISION / Q112;
        uint256 usdPerKlay = oracle_klay_usd.getLatestPrice();
        price = usdkToKlay * usdPerKlay / klay_price_precision;
        if (tx.gasprice > 0) requireValidPrice(price);
    }

    // token price as amountIn
    function consult(address token, uint amountIn) external view override returns (uint amountOut) {
        uint256 price = (isUsdk0ForKlay == (token == usdk_address) ? klayPrice0() : klayPrice1()) * PRICE_PRECISION / Q112;
        // UQ112x112 -> E6
        amountOut = amountIn * price / PRICE_PRECISION;
        if (tx.gasprice > 0) {
            uint256 usdPerKlay = oracle_klay_usd.getLatestPrice();
            if (token == usdk_address) {
                requireValidPrice(amountOut * usdPerKlay * 1e9 / klay_price_precision / amountIn);
            } else {
                requireValidPrice(amountIn * usdPerKlay * 1e9 / klay_price_precision / amountOut);
            }
        }
    }
}