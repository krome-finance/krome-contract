// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// =========================================================================
//    __ __                              _______
//   / //_/_________  ____ ___  ___     / ____(_)___  ____ _____  ________
//  / ,<  / ___/ __ \/ __ `__ \/ _ \   / /_  / / __ \/ __ `/ __ \/ ___/ _ \
// / /| |/ /  / /_/ / / / / / /  __/  / __/ / / / / / /_/ / / / / /__/  __/
///_/ |_/_/   \____/_/ /_/ /_/\___/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/
//
// =========================================================================
// ======================== KromeStablecoin (USDK) =========================
// =========================================================================
// Original idea and credit:
// Curve Finance's veCRV
// https://resources.curve.fi/guides/boosting-your-crv-rewards
// https://github.com/curvefi/curve-veBoost/blob/master/contracts/DelegationProxy.vy
// this is a solidity clone for veKROME
//

import "../../ERC20/ERC20.sol";

interface VeDelegation {
  function adjusted_balance_of(address _account) external view returns(uint256);
}

contract DelegationProxy {
  event CommitAdmins(address ownership_admin, address emergency_admin);
  event ApplyAdmins(address ownership_admin, address emergency_admin);
  event DelegationSet(address delegation);

  address immutable VOTING_ESCROW;
  address public delegation;

  address public emergency_admin;
  address public ownership_admin;
  address public future_emergency_admin;
  address public future_ownership_admin;

  constructor(address _voting_escrow, address _delegation, address _o_admin, address _e_admin) {
    VOTING_ESCROW = _voting_escrow;
    delegation = _delegation;

    ownership_admin = _o_admin;
    emergency_admin = _e_admin;

    emit DelegationSet(_delegation);
  }

  /**
   * Get the adjusted veCRV balance from the active boost delegation contract
   * @param _account The account to query the adjusted veCRV balance of
   * @return veCRV balance
   */
  function adjusted_balance_of(address _account) external view returns(uint256) {
    address _delegation = delegation;
    if (_delegation == address(0)) {
      return ERC20(VOTING_ESCROW).balanceOf(_account);
    }
    return VeDelegation(_delegation).adjusted_balance_of(_account);
  }

  /**
   * Set delegation contract to 0x00, disabling boost delegation
   * @dev Callable by the emergency admin in case of an issue with the delegation logic
   */
  function kill_delegation() external {
    require(msg.sender  == ownership_admin || msg.sender == emergency_admin);

    delegation = address(0);
    emit DelegationSet(address(0));
  }

  /**
   * Set the delegation contract
   * @dev Only callable by the ownership admin
   * @param _delegation `VotingEscrowDelegation` deployment address
   */
  function set_delegation(address _delegation) external {
    require(msg.sender == ownership_admin);

    // call `adjusted_balance_of` to make sure it works
    VeDelegation(_delegation).adjusted_balance_of(msg.sender);

    delegation = _delegation;
    emit DelegationSet(_delegation);
  }

  /**
   * Set ownership admin to `_o_admin` and emergency admin to `_e_admin`
   * @param _o_admin Ownership admin
   * @param _e_admin Emergency admin
   */
  function commit_set_admins(address _o_admin, address _e_admin) external {
    require(msg.sender == ownership_admin, "Access denied");

    future_ownership_admin = _o_admin;
    future_emergency_admin = _e_admin;

    emit CommitAdmins(_o_admin, _e_admin);
  }

  /**
   * Apply the effects of `commit_set_admins`
   */
  function apply_set_admins() external {
    require(msg.sender == ownership_admin, "Access denied");

    address _o_admin = future_ownership_admin;
    address _e_admin = future_emergency_admin;
    ownership_admin = _o_admin;
    emergency_admin = _e_admin;

    emit ApplyAdmins(_o_admin, _e_admin);
  }
}