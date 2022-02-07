// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../Usdk/UsdkCollateralRatio.sol";

contract CollateralRatioMock is UsdkCollateralRatio {
  
  constructor(
    address _usdk_address,
    address _timelock_address,
    uint256 _initial_collateral_ratio   // 100% = 1e6 = 1_000_000
  ) UsdkCollateralRatio(_usdk_address, _timelock_address, _initial_collateral_ratio) {
  }

  function setCollateralRatio(uint256 value) external onlyByOwnerGovernanceOrController {
    collateral_ratio = value;
  }

}