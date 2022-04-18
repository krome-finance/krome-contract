// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../StakingTreasury_ERC20V3.sol";

contract TreasuryERC20_MockV3 is StakingTreasury_ERC20V3 {
    constructor(
        address _timelock_address,
        address _staking_boost_controller,
        address _staking_token

    ) StakingTreasury_ERC20V3(_timelock_address, _staking_boost_controller, _staking_token) {
    }

    function usdkPerLPToken() public override pure returns (uint256) {
      return 1e18;
    }

    function getVirtualPrice() public override pure returns (uint256) {
      return 2e18;
    }
}