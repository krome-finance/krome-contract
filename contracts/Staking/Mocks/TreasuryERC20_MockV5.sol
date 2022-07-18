// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../StakingTreasury_ERC20V5.sol";

contract TreasuryERC20_MockV5 is StakingTreasury_ERC20V5 {
    function initialize(
        address _locator_address,
        address _staking_boost_controller,
        address _staking_token

    ) public initializer {
        StakingTreasury_ERC20V5.__StakingTreasury_init(_locator_address, _staking_boost_controller, _staking_token);
    }

    function usdkPerLPToken() public override pure returns (uint256) {
        return 1e18;
    }

    function getVirtualPrice() public override pure returns (uint256) {
        return 2e18;
    }
}