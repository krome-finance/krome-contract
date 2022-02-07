// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IUsdk {
  function addPool(address pool_address ) external;
  // function controller_address() external view returns (address);
  function usdk_pools(address pool_address) external returns (bool);
  function usdk_pools_array(uint256) external returns (address);
  function usdk_price() external view returns (uint256);
  function krome_price() external view returns (uint256);
  function globalCollateralValue() external view returns (uint256);
  function global_collateral_ratio() external view returns (uint256);
  // function name() external view returns (string memory);
  // function owner_address() external view returns (address);
  function pool_burn_from(address b_address, uint256 b_amount ) external;
  function pool_mint(address m_address, uint256 m_amount ) external;
  // function price_band() external view returns (uint256);
  // function price_target() external view returns (uint256);
  // function redemption_fee() external view returns (uint256);
  // function refreshCollateralRatio() external;
  // function refresh_cooldown() external view returns (uint256);
  // function removePool(address pool_address ) external;
  // function renounceRole(bytes32 role, address account ) external;
  // function revokeRole(bytes32 role, address account ) external;
  // function setController(address _controller_address ) external;
  // function setKromeAddress(address _krome_address ) external;
  // function setKromeEthOracle(address _krome_oracle_addr, address _weth_address ) external;
  // function setFraxStep(uint256 _new_step ) external;
  // function setMintingFee(uint256 min_fee ) external;
  // function setOwner(address _owner_address ) external;
  // function setPriceBand(uint256 _price_band ) external;
  // function setPriceTarget(uint256 _new_price_target ) external;
  // function setRedemptionFee(uint256 red_fee ) external;
  // function setRefreshCooldown(uint256 _new_cooldown ) external;
  // function setTimelock(address new_timelock ) external;
  // function symbol() external view returns (string memory);
  // function timelock_address() external view returns (address);
  // function toggleCollateralRatio() external;
  // function totalSupply() external view returns (uint256);
  // function transfer(address recipient, uint256 amount ) external returns (bool);
  // function transferFrom(address sender, address recipient, uint256 amount ) external returns (bool);
  // function weth_address() external view returns (address);
}