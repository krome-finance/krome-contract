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

contract KromePriceOracle is BenchmarkedPriceOracle, IPairPriceOracle, IPriceOracle {
    uint256 private constant PRICE_PRECISION = 10 ** 9;
    uint256 private constant Q112 = 2**112;

    address private immutable krome_address;
    IPriceOracle private immutable oracle_klay_usd;
    IPair private immutable pair_usdk_klay;
    IPair private immutable pair_usdk_krome;

    uint256 private immutable klay_price_precision;

    bool private immutable isUsdk0ForKlay;
    bool private immutable isUsdk0ForKrome;

    constructor(
        address _krome_address,
        address _usdk_address,
        address _oracle_klay_usd,
        address _pair_usdk_klay,
        address _pair_usdk_krome
    ) BenchmarkedPriceOracle(msg.sender) {
        krome_address = _krome_address;
        oracle_klay_usd = IPriceOracle(_oracle_klay_usd);
        pair_usdk_klay = IPair(_pair_usdk_klay);
        pair_usdk_krome = IPair(_pair_usdk_krome);

        klay_price_precision = 10 ** oracle_klay_usd.getDecimals();

        isUsdk0ForKlay = pair_usdk_klay.token0() == _usdk_address;
        isUsdk0ForKrome = pair_usdk_krome.token0() == _usdk_address;
    }

    // for USD price
    function getDecimals() external pure override returns (uint8) {
        return 9;
    }

    function kromePrice1() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_krome.getReserves();
        return uint256(reserve0) * Q112 / uint256(reserve1);
    }

    function kromePrice0() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_krome.getReserves();
        return uint256(reserve1) * Q112 / uint256(reserve0);
    }

    function klayPrice1() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_klay.getReserves();
        return uint256(reserve0) * Q112 / uint256(reserve1);
    }

    function klayPrice0() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair_usdk_klay.getReserves();
        return uint256(reserve1) * Q112 / uint256(reserve0);
    }

    // price0 = reserve1/reserve0  3:1 = 3
    // in USD e9
    function getLatestPrice() public view override(BenchmarkedPriceOracle, IPriceOracle) returns (uint256 price) {
        // UQ112x112 -> E9
        uint256 usdkPerKrome = (isUsdk0ForKrome ? kromePrice1() : kromePrice0()) * PRICE_PRECISION / Q112;
        // UQ112x112 -> E9
        uint256 klayPerUsdk = (isUsdk0ForKlay ? klayPrice0() : klayPrice1()) * PRICE_PRECISION / Q112;
        uint256 usdPerKlay = oracle_klay_usd.getLatestPrice();
        price = usdPerKlay * (usdkPerKrome * klayPerUsdk / PRICE_PRECISION) / klay_price_precision;
        if (tx.gasprice > 0) requireValidPrice(price);
    }

    // in KLAY amountIn precision
    function consult(address token, uint amountIn) external view override returns (uint amountOut) {
        // UQ112x112 -> E9
        uint256 usdkPerKrome = (isUsdk0ForKrome == (token == krome_address) ? kromePrice1() : kromePrice0()) * PRICE_PRECISION / Q112;
        // UQ112x112 -> E9
        uint256 klayPerUsdk = (isUsdk0ForKlay == (token == krome_address) ? klayPrice0() : klayPrice1()) * PRICE_PRECISION / Q112;
        amountOut =  (amountIn * usdkPerKrome / PRICE_PRECISION) * klayPerUsdk / PRICE_PRECISION;
        if (tx.gasprice > 0) {
            uint256 usdPerKlay = oracle_klay_usd.getLatestPrice();
            if (token == krome_address) {
                requireValidPrice(amountOut * usdPerKlay * 1e9 / klay_price_precision / amountIn);
            } else {
                requireValidPrice(amountIn * usdPerKlay * 1e9 / klay_price_precision / amountOut);
            }
        }
    }
}