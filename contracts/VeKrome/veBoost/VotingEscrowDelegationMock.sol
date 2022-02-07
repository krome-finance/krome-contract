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

import "./VotingEscrowDelegation.sol";

contract VotingEscrowDelegationMock is VotingEscrowDelegation {
  constructor(
    address _voting_escrow,
    string memory _name,
    string memory _symbol,
    string memory _base_uri) VotingEscrowDelegation(_voting_escrow, _name, _symbol, _base_uri) {
  }
  
  function _mint_for_testing(address _to, uint256 _token_id) external {
    _mint(_to, _token_id);
  }

  function _burn_for_testing(uint256 _token_id) external {
    _burn(_token_id);
  }
}