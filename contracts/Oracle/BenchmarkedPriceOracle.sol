// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Owned.sol";
import "../Libs/Address.sol";
import "./IPriceOracle.sol";
import "./IPriceValidator.sol";

abstract contract BenchmarkedPriceOracle is Owned, IPriceValidator {
    using Address for address;

    mapping(address => bool) public whitelist_address;

    uint256 public benchmark_valid_duration = 7200; // 2 hour, in seconds, 0 means no expiry

    uint256 public permitted_price_range_rate = 150000; // 10%, e6
    uint256 public benchmark_price; // 0 means no benchmark
    uint256 public benchmark_price_timestamp;

    modifier onlyUserOrWhitelistedContract {
        require(msg.sender == owner || whitelist_address[msg.sender] || (!msg.sender.isContract() && tx.origin == msg.sender), "non-white listed contract may not perform this action");
        _;
    }

    constructor(address _owner) Owned(_owner) {}

    function requireValidPrice(uint256 _price) public view {
        require(isValidPrice(_price), "out of benchmark price range");
    } 

    function isValidPrice(uint256 _price) public view override returns(bool) {
        if (benchmark_price == 0) return true;
        if (benchmark_valid_duration > 0 && benchmark_price_timestamp + benchmark_valid_duration < block.timestamp) {
            return true;
        }
        uint256 band = benchmark_price * permitted_price_range_rate / 1e6;
        return (benchmark_price > band ? benchmark_price - band : 0) <= _price && _price <= benchmark_price + band;
    }

    function getLatestPrice() virtual public view returns (uint256);

    function updateBenchmarkPrice() external onlyUserOrWhitelistedContract {
        benchmark_price = 0; // disable benchmark price to prevent revert on getLatestPrice()
        _setBenchmarkPrice(getLatestPrice());
    }

    function _setBenchmarkPrice(uint256 _price) internal {
        benchmark_price = _price;
        benchmark_price_timestamp = block.timestamp;

        emit BenchmarkPriceSet(_price);
    }

    /* ---------------- managing ------------------- */

    function setWhitelist(address _address, bool v) external onlyOwner {
        whitelist_address[_address] = v;

        emit WhitelistToggled(_address, v);
    }

    // set 0 to clear benchmark
    function setBenchmarkPrice(uint256 _price) external onlyOwner {
        _setBenchmarkPrice(_price);
    }

    function setPermittedPriceRangeRate(uint256 _range_rate) external onlyOwner {
        permitted_price_range_rate = _range_rate;

        emit PermittedPriceRangeRateSet(_range_rate);
    }

    function setBenchmarkValidDuration(uint256 _duration) external onlyOwner {
        benchmark_valid_duration = _duration;

        emit BenchmarkValidDuration(_duration);
    }

    /* ----------------- event -------------------- */

    event WhitelistToggled(address _address, bool v);
    event BenchmarkPriceSet(uint256 _price);
    event PermittedPriceRangeRateSet(uint256 _range_rate);
    event BenchmarkValidDuration(uint256 _duration);
}
