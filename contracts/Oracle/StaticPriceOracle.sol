// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Owned.sol";
import "./IPairPriceOracle.sol";
import "./IPriceOracle.sol";

contract StaticPriceOracle is Owned, IPairPriceOracle, IPriceOracle {
    address public immutable token_address;
    IPriceOracle private immutable oracle_klay_usd;
    uint256 private immutable klay_price_precision;
    uint256 public override getLatestPrice;

    constructor(
        address _token_address,
        address _oracle_klay_usd,
        uint256 _price
    ) Owned(payable(msg.sender)) {
        token_address = _token_address;
        oracle_klay_usd = IPriceOracle(_oracle_klay_usd);
        klay_price_precision = 10 ** oracle_klay_usd.getDecimals();
        getLatestPrice = _price;
    }

    function setPrice(uint256 _price) external onlyOwner {
        getLatestPrice = _price;
    }

    // for USD price
    function getDecimals() external pure override returns (uint8) {
        return 9;
    }

    // in KLAY amountIn precision
    function consult(address token, uint amountIn) external view override returns (uint amountOut) {
        uint256 usdPerKlay = oracle_klay_usd.getLatestPrice();
        if (token == token_address) {
            amountOut = getLatestPrice * amountIn * klay_price_precision / 1e9 / usdPerKlay;
        } else {
            amountOut = getLatestPrice * usdPerKlay * 1e9 / klay_price_precision / getLatestPrice;
        }
    }
}