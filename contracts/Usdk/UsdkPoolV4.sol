// SPDX-License-Identifier: BUSL-1.1
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
// Allows multiple stablecoins (fixed amount at initialization) as collateral
// LUSD, sUSD, USDP, Wrapped UST, and FEI initially
// For this pool, the goal is to accept crypto-backed / overcollateralized stablecoins to limit
// government / regulatory risk (e.g. USDC blacklisting until holders KYC)

// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian
// Dennis: github.com/denett
// Hameed

// Mofdified by: https://github.com/krome-finance

import "../Libs/TransferHelper.sol";
import "../Common/Owned.sol";
import "../Krome/IKrome.sol";
import "./IUsdk.sol";
import "./ICollatBalance.sol";
import "../Oracle/IPriceOracle.sol";
import "./IAMOMinter.sol";
import "../ERC20/ERC20.sol";

contract UsdkPoolV4 is Owned {
    // using SafeMath for uint256;
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== STATE VARIABLES ========== */

    // Core
    address public timelock_address;
    address public custodian_address; // Custodian is an EOA (or msig) with pausing privileges only, in case of an emergency
    address immutable usdk_address;
    address immutable krome_address;
    mapping(address => bool) public amo_minter_addresses; // minter address -> is it enabled
    IPriceOracle public priceFeedUsdkUsd;
    IPriceOracle public priceFeedKromeUsd;
    uint256 private oracle_usdk_usd_decimals;
    uint256 private oracle_krome_usd_decimals;

    // Collateral
    address[] public collateral_addresses;
    string[] public collateral_symbols;
    uint256[] public missing_decimals; // Number of decimals needed to get to E18. collateral index -> missing_decimals
    uint256[] public pool_ceilings; // Total across all collaterals. Accounts for missing_decimals
    uint256[] public collateral_prices; // Stores price of the collateral, if price is paused
    mapping(address => uint256) public collateralAddrToIdx; // collateral addr -> collateral index
    mapping(address => bool) public enabled_collaterals; // collateral address -> is it enabled
    
    // Redeem related
    mapping (address => uint256) public redeemKROMEBalances;
    mapping (address => mapping(uint256 => uint256)) public redeemCollateralBalances; // Address -> collateral index -> balance
    uint256[] public unclaimedPoolCollateral; // collateral index -> balance
    uint256 public unclaimedPoolKROME;
    mapping (address => uint256) public lastRedeemed; // Collateral independent
    uint256 public redemption_delay = 2; // Number of blocks to wait before being able to collectRedemption()
    uint256 public redeem_price_threshold = 990000; // $0.99
    uint256 public mint_price_threshold = 1010000; // $1.01
    
    // Buyback related
    mapping(uint256 => uint256) public bbkHourlyCum; // Epoch hour ->  Collat out in that hour (E18)
    uint256 public bbkMaxColE18OutPerHour = 1000e18;

    // Recollat related
    mapping(uint256 => uint256) public rctHourlyCum; // Epoch hour ->  KROME out in that hour
    uint256 public rctMaxKromeOutPerHour = 1000e18;

    // Fees and rates
    // getters are in collateral_information()
    uint256[] private minting_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256[] private redemption_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256[] private buyback_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256[] private recollat_fee; // 6 decimals of precision, divide by 1000000 in calculations for fee
    uint256 public bonus_rate = 7500; // Bonus rate on KROME minted during recollateralize(); 6 decimals of precision, set to 0.75% on genesis
    
    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;

    // Pause variables
    // getters are in collateral_information()
    bool[] private mintPaused; // Collateral-specific
    bool[] private redeemPaused; // Collateral-specific
    bool[] private recollateralizePaused; // Collateral-specific
    bool[] private buyBackPaused; // Collateral-specific

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() {
        require(msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address, "Not owner, tlck, or custd");
        _;
    }

    modifier onlyAMOMinters() {
        require(amo_minter_addresses[msg.sender], "Not an AMO Minter");
        _;
    }

    modifier collateralEnabled(uint256 col_idx) {
        require(enabled_collaterals[collateral_addresses[col_idx]], "Collateral disabled");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _usdk,
        address _krome,
        address _owner_address,
        address _custodian_address,
        address _timelock_address,
        address _oracle_usdk,
        address _oracle_krome,
        address[] memory _collateral_addresses,
        uint256[] memory _pool_ceilings,
        uint256[] memory _initial_fees
    ) Owned(_owner_address){
        // Core
        usdk_address = _usdk;
        krome_address = _krome;
        timelock_address = _timelock_address;
        custodian_address = _custodian_address;

        priceFeedUsdkUsd = IPriceOracle(_oracle_usdk);
        priceFeedKromeUsd = IPriceOracle(_oracle_krome);
        // Fill collateral info
        for (uint256 i = 0; i < _collateral_addresses.length; i++){ 
            _addCollateral(_collateral_addresses[i],  _pool_ceilings[i], _initial_fees[0], _initial_fees[1], _initial_fees[2], _initial_fees[3], false);
        }

        // Set the decimals
        oracle_usdk_usd_decimals = priceFeedUsdkUsd.getDecimals();
        oracle_krome_usd_decimals = priceFeedKromeUsd.getDecimals();
    }

    /* ========== STRUCTS ========== */
    
    struct CollateralInformation {
        uint256 index;
        string symbol;
        address col_addr;
        bool is_enabled;
        uint256 missing_decs;
        uint256 price;
        uint256 pool_ceiling;
        bool mint_paused;
        bool redeem_paused;
        bool recollat_paused;
        bool buyback_paused;
        uint256 minting_fee;
        uint256 redemption_fee;
        uint256 buyback_fee;
        uint256 recollat_fee;
    }

    /* ========== VIEWS ========== */

    // Helpful for UIs
    function collateral_information(address collat_address) external view returns (CollateralInformation memory return_data){
        // require(enabled_collaterals[collat_address], "Invalid collateral");

        // Get the index
        uint256 idx = collateralAddrToIdx[collat_address];
        
        return_data = CollateralInformation(
            idx, // [0]
            collateral_symbols[idx], // [1]
            collat_address, // [2]
            enabled_collaterals[collat_address], // [3]
            missing_decimals[idx], // [4]
            collateral_prices[idx], // [5]
            pool_ceilings[idx], // [6]
            mintPaused[idx], // [7]
            redeemPaused[idx], // [8]
            recollateralizePaused[idx], // [9]
            buyBackPaused[idx], // [10]
            minting_fee[idx], // [11]
            redemption_fee[idx], // [12]
            buyback_fee[idx], // [13]
            recollat_fee[idx] // [14]
        );
    }

    function allCollaterals() external view returns (address[] memory) {
        return collateral_addresses;
    }

    // 1 USDK = X USD
    function getUsdkPrice() public view returns (uint256) {
        uint256 price = priceFeedUsdkUsd.getLatestPrice();
        return price * PRICE_PRECISION / (10 ** oracle_usdk_usd_decimals);
    }

    // 1 KROME = X USD
    function getKromePrice() public view returns (uint256) {
        uint256 price = priceFeedKromeUsd.getLatestPrice();
        return price * PRICE_PRECISION / (10 ** oracle_krome_usd_decimals);
    }

    // Returns the USDK value in collateral tokens
    function getUsdkInCollateral(uint256 col_idx, uint256 usdk_amount) public view returns (uint256) {
        return usdk_amount * PRICE_PRECISION / (10 ** missing_decimals[col_idx]) / collateral_prices[col_idx];
    }

    // Used by some functions.
    function freeCollatBalance(uint256 col_idx) public view returns (uint256) {
        return ERC20(collateral_addresses[col_idx]).balanceOf(address(this)) - unclaimedPoolCollateral[col_idx];
    }

    // Returns dollar value of collateral held in this Usdk pool, in E18
    function collatDollarBalance() external view returns (uint256 balance_tally) {
        balance_tally = 0;

        // Test 1
        for (uint256 i = 0; i < collateral_addresses.length; i++){ 
            balance_tally += freeCollatBalance(i) * (10 ** missing_decimals[i]) * collateral_prices[i] / PRICE_PRECISION;
        }

    }

    function comboCalcBbkRct(uint256 cur, uint256 max, uint256 theo) internal pure returns (uint256) {
        if (cur >= max) {
            // If the hourly limit has already been reached, return 0;
            return 0;
        }
        else {
            // Get the available amount
            uint256 available = max - cur;

            if (theo >= available) {
                // If the the theoretical is more than the available, return the available
                return available;
            }
            else {
                // Otherwise, return the theoretical amount
                return theo;
            }
        } 
    }

    // Returns the value of excess collateral (in E18) held globally, compared to what is needed to maintain the global collateral ratio
    // Also has throttling to avoid dumps during large price movements
    function buybackAvailableCollat() public view returns (uint256) {
        uint256 total_supply = ERC20(usdk_address).totalSupply();
        uint256 global_collateral_ratio = IUsdk(usdk_address).global_collateral_ratio();
        uint256 global_collat_value = IUsdk(usdk_address).globalCollateralValue();

        if (global_collateral_ratio > PRICE_PRECISION) global_collateral_ratio = PRICE_PRECISION; // Handles an overcollateralized contract with CR > 1
        uint256 required_collat_dollar_value_d18 = (total_supply * global_collateral_ratio) / PRICE_PRECISION; // Calculates collateral needed to back each 1 USDK with $1 of collateral at current collat ratio
        
        if (global_collat_value > required_collat_dollar_value_d18) {
            // Get the theoretical buyback amount
            uint256 theoretical_bbk_amt = global_collat_value - required_collat_dollar_value_d18;

            // See how much has collateral has been issued this hour
            uint256 current_hr_bbk = bbkHourlyCum[curEpochHr()];

            // Account for the throttling
            return comboCalcBbkRct(current_hr_bbk, bbkMaxColE18OutPerHour, theoretical_bbk_amt);
        }
        else return 0;
    }

    // Returns the missing amount of collateral (in E18) needed to maintain the collateral ratio
    function recollatTheoColAvailableE18() public view returns (uint256) {
        uint256 usdk_total_supply = ERC20(usdk_address).totalSupply();
        uint256 effective_collateral_ratio = IUsdk(usdk_address).globalCollateralValue() * PRICE_PRECISION / usdk_total_supply; // Returns it in 1e6
        
        uint256 desired_collat_e24 = IUsdk(usdk_address).global_collateral_ratio() * usdk_total_supply;
        uint256 effective_collat_e24 = effective_collateral_ratio * usdk_total_supply;

        // Return 0 if already overcollateralized
        // Otherwise, return the deficiency
        if (effective_collat_e24 >= desired_collat_e24) return 0;
        else {
            return (desired_collat_e24 - effective_collat_e24) / PRICE_PRECISION;
        }
    }

    // Returns the value of KROME available to be used for recollats
    // Also has throttling to avoid dumps during large price movements
    function recollatAvailableKrome() public view returns (uint256) {
        uint256 krome_price = getKromePrice();

        // Get the amount of collateral theoretically available
        uint256 recollat_theo_available_e18 = recollatTheoColAvailableE18();

        // Get the amount of KROME theoretically outputtable
        uint256 krome_theo_out = recollat_theo_available_e18 * PRICE_PRECISION / krome_price;

        // See how much KROME has been issued this hour
        uint256 current_hr_rct = rctHourlyCum[curEpochHr()];

        // Account for the throttling
        return comboCalcBbkRct(current_hr_rct, rctMaxKromeOutPerHour, krome_theo_out);
    }

    // Returns the current epoch hour
    function curEpochHr() public view returns (uint256) {
        return (block.timestamp / 3600); // Truncation desired
    }

    /* ========== PUBLIC FUNCTIONS ========== */

     function mintUsdk(
        uint256 col_idx,
        uint256 usdk_amt,
        uint256 usdk_out_min,
        bool one_to_one_override
    ) external collateralEnabled(col_idx) returns (
        uint256 total_usdk_mint,
        uint256 collat_needed,
        uint256 krome_needed
    ) {
        require(mintPaused[col_idx] == false, "Minting is paused");

        // Prevent unneccessary mints
        require(getUsdkPrice() >= mint_price_threshold, "Usdk price too low");

        (total_usdk_mint, collat_needed, krome_needed) = _calculate_mint(col_idx, usdk_amt, one_to_one_override);

        // Checks
        require((usdk_out_min <= total_usdk_mint), "USDK slippage");
        require(freeCollatBalance(col_idx) + collat_needed <= pool_ceilings[col_idx], "Pool ceiling");

        // Take the KROME and collateral first
        IKrome(krome_address).pool_burn_from(msg.sender, krome_needed);
        TransferHelper.safeTransferFrom(collateral_addresses[col_idx], msg.sender, address(this), collat_needed);

        // Mint the USDK
        IUsdk(usdk_address).pool_mint(msg.sender, total_usdk_mint);
    }

    function _calculate_mint(
        uint256 col_idx,
        uint256 usdk_amt,
        bool one_to_one_override
    ) internal view returns (
        uint256 total_usdk_mint,
        uint256 collat_needed,
        uint256 krome_needed
    ) {
        uint256 global_collateral_ratio = IUsdk(usdk_address).global_collateral_ratio();

        if (one_to_one_override || global_collateral_ratio >= PRICE_PRECISION) { 
            // 1-to-1, overcollateralized, or user selects override
            collat_needed = getUsdkInCollateral(col_idx, usdk_amt);
            krome_needed = 0;
        } else if (global_collateral_ratio == 0) { 
            // Algorithmic
            collat_needed = 0;
            krome_needed = usdk_amt * PRICE_PRECISION / getKromePrice();
        } else { 
            // Fractional
            uint256 usdk_for_collat = (usdk_amt * global_collateral_ratio) / PRICE_PRECISION;
            uint256 usdk_for_krome = usdk_amt - usdk_for_collat;
            collat_needed = getUsdkInCollateral(col_idx, usdk_for_collat);
            krome_needed = usdk_for_krome * PRICE_PRECISION / getKromePrice();
        }

        // Subtract the minting fee
        total_usdk_mint = (usdk_amt * (PRICE_PRECISION - minting_fee[col_idx])) / PRICE_PRECISION;
    }

    function estimateMint(
        uint256 col_idx,
        uint256 usdk_amt,
        bool one_to_one_override
    ) external view returns (
        uint256 total_usdk_mint,
        uint256 collat_needed,
        uint256 krome_needed
    ) {
        require(getUsdkPrice() >= mint_price_threshold, "Usdk price too low");

        (total_usdk_mint, collat_needed, krome_needed) = _calculate_mint(col_idx, usdk_amt, one_to_one_override);
    }

    function redeemUsdk(
        uint256 col_idx,
        uint256 usdk_amount,
        uint256 krome_out_min,
        uint256 col_out_min
    ) external collateralEnabled(col_idx) returns (
        uint256 collat_out,
        uint256 krome_out
    ) {
        require(redeemPaused[col_idx] == false, "Redeeming is paused");

        // Prevent unneccessary redemptions that could adversely affect the KROME price
        require(getUsdkPrice() <= redeem_price_threshold, "Usdk price too high");

        (collat_out, krome_out) = _calculate_redeem(col_idx, usdk_amount);

        // Checks
        require(collat_out <= (ERC20(collateral_addresses[col_idx])).balanceOf(address(this)) - unclaimedPoolCollateral[col_idx], "Insufficient pool collateral");
        require(collat_out >= col_out_min, "Collateral slippage");
        require(krome_out >= krome_out_min, "KROME slippage");

        // Account for the redeem delay
        redeemCollateralBalances[msg.sender][col_idx] = redeemCollateralBalances[msg.sender][col_idx] + collat_out;
        unclaimedPoolCollateral[col_idx] = unclaimedPoolCollateral[col_idx] + collat_out;

        redeemKROMEBalances[msg.sender] = redeemKROMEBalances[msg.sender] + krome_out;
        unclaimedPoolKROME = unclaimedPoolKROME + krome_out;

        lastRedeemed[msg.sender] = block.number;

        IUsdk(usdk_address).pool_burn_from(msg.sender, usdk_amount);
        IKrome(krome_address).pool_mint(address(this), krome_out);
    }

    function _calculate_redeem(
        uint256 col_idx,
        uint256 usdk_amount
    ) internal view returns (
        uint256 collat_out,
        uint256 krome_out
    ) {
        uint256 global_collateral_ratio = IUsdk(usdk_address).global_collateral_ratio();
        uint256 usdk_after_fee = (usdk_amount * (PRICE_PRECISION - redemption_fee[col_idx])) / PRICE_PRECISION;

        // Assumes $1 USDK in all cases
        if(global_collateral_ratio >= PRICE_PRECISION) { 
            // 1-to-1 or overcollateralized
            collat_out = usdk_after_fee * PRICE_PRECISION
                            / collateral_prices[col_idx]
                            / (10 ** (missing_decimals[col_idx])); // missing decimals
            krome_out = 0;
        } else if (global_collateral_ratio == 0) { 
            // Algorithmic
            krome_out = usdk_after_fee
                            * PRICE_PRECISION
                            / getKromePrice();
            collat_out = 0;
        } else { 
            // Fractional
            collat_out = usdk_after_fee
                            * global_collateral_ratio
                            * PRICE_PRECISION
                            / collateral_prices[col_idx]
                            / (10 ** (6 + missing_decimals[col_idx])); // PRICE_PRECISION + missing decimals
            krome_out = usdk_after_fee
                            * (PRICE_PRECISION - global_collateral_ratio)
                            / getKromePrice(); // PRICE_PRECISIONS CANCEL OUT
        }
    }

    function estimateRedeem(
        uint256 col_idx,
        uint256 usdk_amount
    ) external view returns (
        uint256 collat_out,
        uint256 krome_out
    ) {
        // Prevent unneccessary redemptions that could adversely affect the KROME price
        require(getUsdkPrice() <= redeem_price_threshold, "Usdk price too high");

        (collat_out, krome_out) = _calculate_redeem(col_idx, usdk_amount);
    }

    // After a redemption happens, transfer the newly minted KROME and owed collateral from this pool
    // contract to the user. Redemption is split into two functions to prevent flash loans from being able
    // to take out USDK/collateral from the system, use an AMM to trade the new price, and then mint back into the system.
    function collectRedemption(uint256 col_idx) external returns (uint256 krome_amount, uint256 collateral_amount) {
        require(redeemPaused[col_idx] == false, "Redeeming is paused");
        require((lastRedeemed[msg.sender] + redemption_delay) <= block.number, "Too soon");
        bool sendKROME = false;
        bool sendCollateral = false;

        // Use Checks-Effects-Interactions pattern
        if(redeemKROMEBalances[msg.sender] > 0){
            krome_amount = redeemKROMEBalances[msg.sender];
            redeemKROMEBalances[msg.sender] = 0;
            unclaimedPoolKROME = unclaimedPoolKROME - krome_amount;
            sendKROME = true;
        }
        
        if(redeemCollateralBalances[msg.sender][col_idx] > 0){
            collateral_amount = redeemCollateralBalances[msg.sender][col_idx];
            redeemCollateralBalances[msg.sender][col_idx] = 0;
            unclaimedPoolCollateral[col_idx] = unclaimedPoolCollateral[col_idx] - collateral_amount;
            sendCollateral = true;
        }

        // Send out the tokens
        if(sendKROME){
            TransferHelper.safeTransfer(krome_address, msg.sender, krome_amount);
        }
        if(sendCollateral){
            TransferHelper.safeTransfer(collateral_addresses[col_idx], msg.sender, collateral_amount);
        }
    }

    // Function can be called by an KROME holder to have the protocol buy back KROME with excess collateral value from a desired collateral pool
    // This can also happen if the collateral ratio > 1
    function buyBackKrome(uint256 col_idx, uint256 krome_amount, uint256 col_out_min) external collateralEnabled(col_idx) returns (uint256 col_out) {
        require(buyBackPaused[col_idx] == false, "Buyback is paused");
        uint256 krome_price = getKromePrice();
        uint256 available_excess_collat_dv = buybackAvailableCollat();

        // If the total collateral value is higher than the amount required at the current collateral ratio then buy back up to the possible KROME with the desired collateral
        require(available_excess_collat_dv > 0, "Insuf Collat Avail For BBK");

        // Make sure not to take more than is available
        uint256 krome_dollar_value_d18 = krome_amount * krome_price / PRICE_PRECISION;
        require(krome_dollar_value_d18 <= available_excess_collat_dv, "Insuf Collat Avail For BBK");

        // Get the equivalent amount of collateral based on the market value of KROME provided 
        uint256 collateral_equivalent_d18 = krome_dollar_value_d18 * PRICE_PRECISION / collateral_prices[col_idx];
        col_out = collateral_equivalent_d18 / (10 ** missing_decimals[col_idx]); // In its natural decimals()

        // Subtract the buyback fee
        col_out = (col_out * (PRICE_PRECISION - buyback_fee[col_idx])) / PRICE_PRECISION;

        // Check for slippage
        require(col_out >= col_out_min, "Collateral slippage");

        // Take in and burn the KROME, then send out the collateral
        IKrome(krome_address).pool_burn_from(msg.sender, krome_amount);
        TransferHelper.safeTransfer(collateral_addresses[col_idx], msg.sender, col_out);

        // Increment the outbound collateral, in E18, for that hour
        // Used for buyback throttling
        bbkHourlyCum[curEpochHr()] += collateral_equivalent_d18;
    }

    // When the protocol is recollateralizing, we need to give a discount of KROME to hit the new CR target
    // Thus, if the target collateral ratio is higher than the actual value of collateral, minters get KROME for adding collateral
    // This function simply rewards anyone that sends collateral to a pool with the same amount of KROME + the bonus rate
    // Anyone can call this function to recollateralize the protocol and take the extra KROME value from the bonus rate as an arb opportunity
    function recollateralize(uint256 col_idx, uint256 collateral_amount, uint256 krome_out_min) external collateralEnabled(col_idx) returns (uint256 krome_out) {
        require(recollateralizePaused[col_idx] == false, "Recollat is paused");
        uint256 collateral_dollar_value_d18 = collateral_amount * (10 ** missing_decimals[col_idx]) * collateral_prices[col_idx] / PRICE_PRECISION;
        uint256 krome_price = getKromePrice();

        // Get the amount of KROME actually available (accounts for throttling)
        uint256 krome_actually_available = recollatAvailableKrome();

        // Calculated the attempted amount of KROME
        krome_out = collateral_dollar_value_d18 * (PRICE_PRECISION + bonus_rate - recollat_fee[col_idx]) / krome_price;

        // Make sure there is KROME available
        require(krome_out <= krome_actually_available, "Insuf KROME Avail For RCT");

        // Check slippage
        require(krome_out >= krome_out_min, "KROME slippage");

        // Don't take in more collateral than the pool ceiling for this token allows
        require(freeCollatBalance(col_idx) + collateral_amount <= pool_ceilings[col_idx], "Pool ceiling");

        // Take in the collateral and pay out the KROME
        TransferHelper.safeTransferFrom(collateral_addresses[col_idx], msg.sender, address(this), collateral_amount);
        IKrome(krome_address).pool_mint(msg.sender, krome_out);

        // Increment the outbound KROME, in E18
        // Used for recollat throttling
        rctHourlyCum[curEpochHr()] += krome_out;
    }

    // Bypasses the gassy mint->redeem cycle for AMOs to borrow collateral
    function amoMinterBorrow(uint256 collateral_amount) external onlyAMOMinters {
        // Checks the col_idx of the minter as an additional safety check
        uint256 minter_col_idx = IAMOMinter(msg.sender).col_idx();

        // Transfer
        TransferHelper.safeTransfer(collateral_addresses[minter_col_idx], msg.sender, collateral_amount);
    }

    /* ========== RESTRICTED FUNCTIONS, CUSTODIAN CAN CALL TOO ========== */

    function toggleMRBR(uint256 col_idx, uint8 tog_idx) external onlyByOwnGovCust {
        if (tog_idx == 0) mintPaused[col_idx] = !mintPaused[col_idx];
        else if (tog_idx == 1) redeemPaused[col_idx] = !redeemPaused[col_idx];
        else if (tog_idx == 2) buyBackPaused[col_idx] = !buyBackPaused[col_idx];
        else if (tog_idx == 3) recollateralizePaused[col_idx] = !recollateralizePaused[col_idx];

        emit MRBRToggled(col_idx, tog_idx);
    }

    /* ========== RESTRICTED FUNCTIONS, GOVERNANCE ONLY ========== */

    // Add an AMO Minter
    function addAMOMinter(address amo_minter_addr) external onlyByOwnGov {
        require(amo_minter_addr != address(0), "Zero address detected");

        // Make sure the AMO Minter has collatDollarBalance()
        uint256 collat_val_e18 = ICollatBalance(amo_minter_addr).collatDollarBalance();
        require(collat_val_e18 >= 0, "Invalid AMO");

        amo_minter_addresses[amo_minter_addr] = true;

        emit AMOMinterAdded(amo_minter_addr);
    }

    // Remove an AMO Minter 
    function removeAMOMinter(address amo_minter_addr) external onlyByOwnGov {
        amo_minter_addresses[amo_minter_addr] = false;
        
        emit AMOMinterRemoved(amo_minter_addr);
    }

    function setCollateralPrice(uint256 col_idx, uint256 _new_price) external onlyByOwnGov {
        collateral_prices[col_idx] = _new_price;

        emit CollateralPriceSet(col_idx, _new_price);
    }

    // Could also be called toggleCollateral
    function toggleCollateral(uint256 col_idx) external onlyByOwnGov {
        address col_address = collateral_addresses[col_idx];
        enabled_collaterals[col_address] = !enabled_collaterals[col_address];

        emit CollateralToggled(col_idx, enabled_collaterals[col_address]);
    }

    function setPoolCeiling(uint256 col_idx, uint256 new_ceiling) external onlyByOwnGov {
        pool_ceilings[col_idx] = new_ceiling;

        emit PoolCeilingSet(col_idx, new_ceiling);
    }

    function setFees(uint256 col_idx, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external onlyByOwnGov {
        minting_fee[col_idx] = new_mint_fee;
        redemption_fee[col_idx] = new_redeem_fee;
        buyback_fee[col_idx] = new_buyback_fee;
        recollat_fee[col_idx] = new_recollat_fee;

        emit FeesSet(col_idx, new_mint_fee, new_redeem_fee, new_buyback_fee, new_recollat_fee);
    }

    function setPoolParameters(uint256 new_bonus_rate, uint256 new_redemption_delay) external onlyByOwnGov {
        bonus_rate = new_bonus_rate;
        redemption_delay = new_redemption_delay;
        emit PoolParametersSet(new_bonus_rate, new_redemption_delay);
    }

    function setPriceThresholds(uint256 new_mint_price_threshold, uint256 new_redeem_price_threshold) external onlyByOwnGov {
        mint_price_threshold = new_mint_price_threshold;
        redeem_price_threshold = new_redeem_price_threshold;
        emit PriceThresholdsSet(new_mint_price_threshold, new_redeem_price_threshold);
    }

    function setBbkRctPerHour(uint256 _bbkMaxColE18OutPerHour, uint256 _rctMaxKromeOutPerHour) external onlyByOwnGov {
        bbkMaxColE18OutPerHour = _bbkMaxColE18OutPerHour;
        rctMaxKromeOutPerHour = _rctMaxKromeOutPerHour;
        emit BbkRctPerHourSet(_bbkMaxColE18OutPerHour, _rctMaxKromeOutPerHour);
    }

    // Set the Price oracles
    function setOracles(address _usdk_usd_oracle_addr, address _krome_usd_oracle_addr) external onlyByOwnGov {
        // Set the instances
        priceFeedUsdkUsd = IPriceOracle(_usdk_usd_oracle_addr);
        priceFeedKromeUsd = IPriceOracle(_krome_usd_oracle_addr);

        // Set the decimals
        oracle_usdk_usd_decimals = priceFeedUsdkUsd.getDecimals();
        oracle_krome_usd_decimals = priceFeedKromeUsd.getDecimals();
        
        emit OraclesSet(_usdk_usd_oracle_addr, _krome_usd_oracle_addr);
    }

    function setCustodian(address new_custodian) external onlyByOwnGov {
        custodian_address = new_custodian;

        emit CustodianSet(new_custodian);
    }

    function setTimelock(address new_timelock) external onlyByOwnGov {
        timelock_address = new_timelock;

        emit TimelockSet(new_timelock);
    }

    function addCollateral(
        address _collateral_address,
        uint256 _pool_ceiling,
        uint256 _minting_fee,
        uint256 _redemption_fee,
        uint256 _buyback_fee,
        uint256 _recollat_fee,
        bool _paused
    ) external onlyByOwnGov {
        _addCollateral(_collateral_address, _pool_ceiling, _minting_fee, _redemption_fee, _buyback_fee, _recollat_fee, _paused);
    }

    function _addCollateral(
        address _collateral_address,
        uint256 _pool_ceiling,
        uint256 _minting_fee,
        uint256 _redemption_fee,
        uint256 _buyback_fee,
        uint256 _recollat_fee,
        bool _paused
    ) internal {
        collateralAddrToIdx[_collateral_address] = collateral_addresses.length;

        collateral_addresses.push(_collateral_address);

        // Set all of the collaterals initially to disabled
        enabled_collaterals[_collateral_address] = false;

        // Add in the missing decimals
        missing_decimals.push(uint256(18) - ERC20(_collateral_address).decimals());

        // Add in the collateral symbols
        collateral_symbols.push(ERC20(_collateral_address).symbol());

        // Initialize unclaimed pool collateral
        unclaimedPoolCollateral.push(0);

        // Initialize paused prices to $1 as a backup
        collateral_prices.push(PRICE_PRECISION);

        // Handle the fees
        minting_fee.push(_minting_fee);
        redemption_fee.push(_redemption_fee);
        buyback_fee.push(_buyback_fee);
        recollat_fee.push(_recollat_fee);

        // Handle the pauses
        mintPaused.push(_paused);
        redeemPaused.push(_paused);
        recollateralizePaused.push(_paused);
        buyBackPaused.push(_paused);

        pool_ceilings.push(_pool_ceiling);

        emit CollateralAdded(_collateral_address, _pool_ceiling, _minting_fee, _redemption_fee, _buyback_fee, _recollat_fee);
    }

    /* ========== EVENTS ========== */
    event CollateralAdded(address collateral_address, uint256 pool_ceiling, uint256 minting_fee, uint256 redemption_fee, uint256 buyback_fee, uint256 recollat_fee);
    event CollateralToggled(uint256 col_idx, bool new_state);
    event PoolCeilingSet(uint256 col_idx, uint256 new_ceiling);
    event FeesSet(uint256 col_idx, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee);
    event PoolParametersSet(uint256 new_bonus_rate, uint256 new_redemption_delay);
    event PriceThresholdsSet(uint256 new_bonus_rate, uint256 new_redemption_delay);
    event BbkRctPerHourSet(uint256 bbkMaxColE18OutPerHour, uint256 rctMaxKromeOutPerHour);
    event AMOMinterAdded(address amo_minter_addr);
    event AMOMinterRemoved(address amo_minter_addr);
    event OraclesSet(address usdk_usd_oracle_addr, address krome_usd_oracle_addr);
    event CustodianSet(address new_custodian);
    event TimelockSet(address new_timelock);
    event MRBRToggled(uint256 col_idx, uint8 tog_idx);
    event CollateralPriceSet(uint256 col_idx, uint256 new_price);
}