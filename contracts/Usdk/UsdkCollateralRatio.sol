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
// ======================= KromeStablecoin (USDK) =========================
// =========================================================================

import "../Common/TimelockOwned.sol";
import "./IUsdk.sol";

contract UsdkCollateralRatio is TimelockOwned {
    address immutable public usdk_address;

    address public controller_address; // Controller contract to dynamically adjust system parameters automatically

    uint256 public collateral_ratio; // 6 decimals of precision, e.g. 924102 = 0.924102
    uint256 public frax_step; // Amount to change the collateralization ratio by upon refreshCollateralRatio()
    uint256 public refresh_cooldown; // Seconds to wait before being able to run refreshCollateralRatio() again
    uint256 public price_target; // The price of USDK at which the collateral ratio will respond to; this value is only used for the collateral ratio mechanism and not for minting and redeeming which are hardcoded at $1
    uint256 public price_band; // The bound above and below the price target at which the refreshCollateralRatio() will not change the collateral ratio

    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */
    modifier onlyByOwnerGovernanceOrController() {
        require(
            msg.sender != address(0) &&
            (msg.sender == owner ||
                msg.sender == timelock_address ||
                msg.sender == controller_address),
            "Not the owner or the governance timelock"
        );
        _;
    }

    constructor(
        address _usdk_address,
        address _timelock_address,
        uint256 _initial_collateral_ratio   // 100% = 1e6 = 1_000_000
    ) TimelockOwned(msg.sender, _timelock_address) {
        require(_timelock_address != address(0), "Zero address detected");
        usdk_address = _usdk_address;
        collateral_ratio = _initial_collateral_ratio;

        frax_step = 2500; // 6 decimals of precision, equal to 0.25%
        // collateral_ratio = 1000000; // Frax system starts off fully collateralized (6 decimals of precision)
        refresh_cooldown = 3600; // Refresh cooldown period is set to 1 hour (3600 seconds) at genesis
        price_target = 1000000; // Collateral ratio will adjust according to the $1 price target at genesis
        price_band = 5000; // Collateral ratio will not adjust if between $0.995 and $1.005 at genesis
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    // There needs to be a time interval that this can be called. Otherwise it can be called multiple times per expansion.
    uint256 public last_call_time; // Last time the refreshCollateralRatio function was called

    function refreshCollateralRatio() external {
        require(
            collateral_ratio_paused == false,
            "Collateral Ratio has been paused"
        );
        uint256 usdk_price_cur = IUsdk(usdk_address).usdk_price();
        require(
            block.timestamp - last_call_time >= refresh_cooldown,
            "Must wait for the refresh cooldown since last refresh"
        );

        // Step increments are 0.25% (upon genesis, changable by setFraxStep())

        if (usdk_price_cur > price_target + price_band) {
            //decrease collateral ratio
            if (collateral_ratio <= frax_step) {
                //if within a step of 0, go to 0
                collateral_ratio = 0;
            } else {
                collateral_ratio = collateral_ratio - frax_step;
            }
        } else if (usdk_price_cur < price_target - price_band) {
            //increase collateral ratio
            if (collateral_ratio + (frax_step) >= 1000000) {
                collateral_ratio = 1000000; // cap collateral ratio at 1.000000
            } else {
                collateral_ratio = collateral_ratio + (frax_step);
            }
        }

        last_call_time = block.timestamp; // Set the time of the last expansion

        emit CollateralRatioRefreshed(collateral_ratio);
    }

    function setFraxStep(uint256 _new_step)
        external
        onlyByOwnerGovernanceOrController
    {
        require(_new_step <= 1e6);
        frax_step = _new_step;

        emit FraxStepSet(_new_step);
    }

    function setPriceTarget(uint256 _new_price_target)
        external
        onlyByOwnerGovernanceOrController
    {
        price_target = _new_price_target;

        emit PriceTargetSet(_new_price_target);
    }

    function setRefreshCooldown(uint256 _new_cooldown)
        external
        onlyByOwnerGovernanceOrController
    {
        refresh_cooldown = _new_cooldown;

        emit RefreshCooldownSet(_new_cooldown);
    }

    function setPriceBand(uint256 _price_band)
      external
      onlyByOwnerGovernanceOrController
    {
        price_band = _price_band;

        emit PriceBandSet(_price_band);
    }

    function setController(address _controller_address)
        external
        onlyByOwnerGovernanceOrController
    {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function toggleCollateralRatio() external onlyByOwnerGovernanceOrController {
        collateral_ratio_paused = !collateral_ratio_paused;

        emit CollateralRatioToggled(collateral_ratio_paused);
    }


    /* ========== EVENTS ========== */

    event CollateralRatioRefreshed(uint256 collateral_ratio);
    event FraxStepSet(uint256 new_step);
    event PriceTargetSet(uint256 new_price_target);
    event RefreshCooldownSet(uint256 new_cooldown);
    event CollateralRatioToggled(bool collateral_ratio_paused);
    event PriceBandSet(uint256 price_band);
    event ControllerSet(address controller_address);
}