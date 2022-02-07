// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Owned.sol";

// =========================================================================
//    __ __                              _______
//   / //_/_________  ____ ___  ___     / ____(_)___  ____ _____  ________
//  / ,<  / ___/ __ \/ __ `__ \/ _ \   / /_  / / __ \/ __ `/ __ \/ ___/ _ \
// / /| |/ /  / /_/ / / / / / /  __/  / __/ / / / / / /_/ / / / / /__/  __/
///_/ |_/_/   \____/_/ /_/ /_/\___/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/
//
// =========================================================================
// ======================== ManualGaugeController (USDK) =========================
// =========================================================================

contract ManualGaugeController is Owned {
    uint256 private constant WEEK = 604800;
    uint256 private constant PRECISION = 10 ** 18;

    address[] public gauges;
    mapping(address => uint256) public gauge_index_map;
    mapping(address => uint256) public gauge_weight_map;

    uint256 public total_weight;

    // used when block.timestamp >= next_time
    mapping(address => uint256) public gauge_next_weight_map;
    uint256 public next_total_weight;
    uint256 public next_time;

    uint256 public global_emission_rate;  // inflation rate

    constructor() Owned(msg.sender) { }

    function gauges_length() external view returns(uint256) {
        return gauges.length;
    }

    function all_gauges() external view returns(address[] memory) {
        return gauges;
    }

    function sync() internal {
        if (next_time <= block.timestamp) {
            total_weight = next_total_weight;
            next_time = (block.timestamp + WEEK) / WEEK * WEEK;

            for (uint256 i = 0; i < gauges.length; i++) {
                address gauge = gauges[i];
                gauge_weight_map[gauge] = gauge_next_weight_map[gauge];
            }
        }
    }

    function add_gauge(address gauge, uint256 weight) external onlyOwner {
        require(gauge_index_map[gauge] == 0 && (gauges.length == 0 || gauges[0] != gauge), "Duplicated gauge");

        sync();

        uint256 _index = gauges.length;
        gauges.push(gauge);

        gauge_index_map[gauge] = _index;
        gauge_weight_map[gauge] = 0;
        gauge_next_weight_map[gauge] = weight;

        next_total_weight = next_total_weight + weight;

        emit GaugeAdded(gauge, next_time, weight, next_total_weight);
    }

    function remove_gauge(address gauge) external onlyOwner {
        require(gauge_index_map[gauge] != 0 || (gauges.length > 0 && gauges[0] == gauge), "Invalid gauge");

        uint256 weight = block.timestamp < next_time ? gauge_weight_map[gauge] : gauge_next_weight_map[gauge];
        require(weight == 0, "Gauge weight > 0");

        uint256 _index = gauge_index_map[gauge];

        total_weight -= gauge_weight_map[gauge];
        gauge_weight_map[gauge] = 0;
        next_total_weight -= gauge_next_weight_map[gauge];
        gauge_next_weight_map[gauge] = 0;

        for (uint256 idx = _index; idx < gauges.length - 1; idx++) {
            address _gauge = gauges[idx + 1];
            gauges[idx] = _gauge;
            gauge_index_map[_gauge] = idx;
        }
        gauges.pop();
        emit GaugeAdded(gauge, next_time, weight, next_total_weight);
    }

    function get_gauge_array() external view returns (address[] memory) {
        return gauges;
    }

    function set_weight_now(address gauge, uint256 weight) external onlyOwner {
        require(gauge_index_map[gauge] != 0 || (gauges.length > 0 && gauges[0] == gauge), "Invalid gauge");

        sync();

        total_weight = total_weight + weight - gauge_weight_map[gauge];
        next_total_weight = next_total_weight + weight - gauge_next_weight_map[gauge];

        gauge_weight_map[gauge] = weight;
        gauge_next_weight_map[gauge] = weight;

        emit GaugeWeightChanged(gauge, block.timestamp, weight, total_weight);
    }

    function set_next_weight(address gauge, uint256 weight) external onlyOwner {
        require(gauge_index_map[gauge] != 0 || (gauges.length > 0 && gauges[0] == gauge), "Invalid gauge");

        sync();

        next_total_weight = next_total_weight + weight - gauge_next_weight_map[gauge];
        gauge_next_weight_map[gauge] = weight;

        emit GaugeWeightChanged(gauge, next_time, weight, next_total_weight);
    }

    function time_total() external view returns(uint256) {
        return (block.timestamp + WEEK) / WEEK * WEEK;
    }

    function _gauge_relative_weight(address gauge, uint256 time) internal view returns (uint256) {
        require(gauge_index_map[gauge] != 0 || (gauges.length > 0 && gauges[0] == gauge), "Invalid gauge");

        if (time < next_time) {
            if (total_weight == 0) return 0;
            return PRECISION * gauge_weight_map[gauge] / total_weight;
        } else {
            if (next_total_weight == 0) return 0;
            return PRECISION * gauge_next_weight_map[gauge] / next_total_weight;
        }
    }

    function gauge_relative_weight(address gauge, uint256 time) external view returns (uint256) {
        return _gauge_relative_weight(gauge, time);
    }

    function gauge_relative_weight_write(address gauge, uint256 time) external view returns(uint256) {
        return _gauge_relative_weight(gauge, time);
    }

    /**
    * Change KROME emission rate
    * @param new_rate new emission rate (FXS per second)
    */
    function change_global_emission_rate(uint256 new_rate) external onlyOwner {
        global_emission_rate = new_rate;

        emit GlobalEmissionRate(new_rate);
    }

    event GaugeWeightChanged(address gauge_address, uint256 ts, uint256 weight, uint256 total_weight);
    event GaugeAdded(address addr, uint256 ts, uint256 weight, uint256 total_weight);
    event GaugeRemoved(address addr, uint256 ts, uint256 weight, uint256 total_weight);
    event GlobalEmissionRate(uint256 new_rate);
}