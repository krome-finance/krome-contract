// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IKrome {
  function pool_burn_from(address b_address, uint256 b_amount) external;
  function pool_mint(address m_address, uint256 m_amount) external;

  // function KROME_DAO_min() external view returns(uint256);
  // function allowance(address _owner, address spender) external view returns(uint256);
  // function approve(address spender, uint256 amount) external returns(bool);
  // function balanceOf(address account) external view returns(uint256);
  // function burn(uint256 amount) external;
  // function burnFrom(address account, uint256 amount) external;
  // function checkpoints(address, uint32) external view returns(uint32 fromBlock, uint96 votes);
  // function decimals() external view returns(uint8);
  // function decreaseAllowance(address spender, uint256 subtractedValue) external returns(bool);
  // function genesis_supply() external view returns(uint256);
  // function getCurrentVotes(address account) external view returns(uint96);
  // function getPriorVotes(address account, uint256 blockNumber) external view returns(uint96);
  // function getRoleAdmin(bytes32 role) external view returns(bytes32);
  // function getRoleMember(bytes32 role, uint256 index) external view returns(address);
  // function getRoleMemberCount(bytes32 role) external view returns(uint256);
  // function grantRole(bytes32 role, address account) external;
  // function hasRole(bytes32 role, address account) external view returns(bool);
  // function increaseAllowance(address spender, uint256 addedValue) external returns(bool);
  // function mint(address to, uint256 amount) external;
  // function name() external view returns(string memory);
  // function numCheckpoints(address) external view returns(uint32);
  // // function oracle_address() external view returns(address);
  // // function owner_address() external view returns(address);
  // function owner() external view returns(address);
  // function nominatedOwner() external view returns(address);
  // function renounceRole(bytes32 role, address account) external;
  // function revokeRole(bytes32 role, address account) external;
  // function setUsdkAddress(address usdk_contract_address) external;
  // // function setKromeMinDAO(uint256 min_KROME) external;
  // // function setOracle(address new_oracle) external;
  // function nominateNewOwner(address _owner) external;
  // function acceptOwnership() external;
  // function setTimelock(address new_timelock) external;
  // function symbol() external view returns(string memory);
  // function timelock_address() external view returns(address);
  // function toggleVotes() external;
  // function totalSupply() external view returns(uint256);
  // function trackingVotes() external view returns(bool);
  // function transfer(address recipient, uint256 amount) external returns(bool);
  // function transferFrom(address sender, address recipient, uint256 amount) external returns(bool);
  // function lockedValue(address addr) external view returns (uint256);
}
