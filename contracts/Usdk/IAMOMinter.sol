// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// MAY need to be updated
interface IAMOMinter {
  function custodian_address() external view returns(address);
  function timelock_address() external view returns(address);

  function burnUsdkFromAMO(uint256 frax_amount) external;
  function burnKromeFromAMO(uint256 fxs_amount) external;

  function col_idx() external view returns(uint256);
}