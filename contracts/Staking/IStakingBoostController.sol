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
// ====================== IStakingBoostController ==========================
// =========================================================================

interface IStakingBoostController {
    function lockMultiplier(uint256 secs) external view returns (uint256);
    function minVeKromeForMaxBoost(uint256 stakedUsdk) external view returns (uint256);
    function veKromeMultiplier(address account, uint256 stakedUsdk) external view returns (uint256 vekrome_multiplier, uint256 slope, uint256 stay_time);
}