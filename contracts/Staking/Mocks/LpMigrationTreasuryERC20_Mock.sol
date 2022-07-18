// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../LpMigrationTreasury_ERC20.sol";

contract LpMigrationTreasuryERC20_Mock is LpMigrationTreasury_ERC20 {
    function initialize(
        address _locator_address,
        address _staking_boost_controller,
        address _staking_token,
        uint256 _closed_at,
        uint256 _minimum_lockend
    ) public initializer {
        LpMigrationTreasury_ERC20.__LpMigrationTreasury_init(_locator_address, _staking_boost_controller, _staking_token, _closed_at, _minimum_lockend);
    }

    function usdkPerLPToken() public override pure returns (uint256) {
        return 0;
    }

    function getVirtualPrice() public override pure returns (uint256) {
        return 2e18;
    }
}