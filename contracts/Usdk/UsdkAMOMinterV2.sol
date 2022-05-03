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
// globalCollateralValue() in Frax.sol is gassy because of the loop and all of the AMOs attached to it. 
// This minter would be single mint point for all of the AMOs, and would track the collatDollarBalance with a
// state variable after any mint occurs, or manually with a sync() call
// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian
// Dennis: github.com/denett
// Hameed

// Mofdified by: https://github.com/krome-finance

import "./ICollatBalance.sol";
import "./IAMOMinter.sol";
import "./IUsdk.sol";
import "./IUsdkPoolV5.sol";
import "../Krome/IKrome.sol";
import "../ERC20/ERC20.sol";
import "../Common/LocatorBasedProxyV2.sol";
import '../Libs/TransferHelper.sol';
import '../AMO/IAMO.sol';

contract UsdkAMOMinterV2 is LocatorBasedProxyV2 {
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== CONSTANT VARIABLES ========== */

    // Price constants
    uint256 private constant PRICE_PRECISION = 1e6;

    /* ========== STRUCT ========== */

    struct Collateral {
        address collateral_address;
        uint8 missing_decimals;
        address pool_address;
        uint96 col_idx;
    }

    /* ========== STATE VARIABLES ========== */

    // Core
    address public usdk_address;
    address public krome_address;
    address public custodian_address;

    // Collateral related
    Collateral[] public collaterals;
    mapping(address => uint256) collateral_order;

    // AMO addresses
    address[] public amos_array;
    mapping(address => bool) public amos; // Mapping is also used for faster verification

    // Max amount of collateral the contract can borrow from the UsdkPool
    int256 public collat_borrow_cap;

    // Max amount of USDK and KROME this contract can mint
    int256 public usdk_mint_cap;
    int256 public krome_mint_cap;

    // Minimum collateral ratio needed for new USDK minting
    uint256 public min_cr;

    // Usdk mint balances
    mapping(address => int256) public usdk_mint_balances; // Amount of USDK the contract minted, by AMO
    int256 public usdk_mint_sum; // Across all AMOs

    // Krome mint balances
    mapping(address => int256) public krome_mint_balances; // Amount of KROME the contract minted, by AMO
    int256 public krome_mint_sum; // Across all AMOs

    // Collateral borrowed balances
    mapping(address => int256) public amo_collat_borrowed_balances; // Amount of collateral the contract borrowed in e18, by AMO
    mapping(address => int256) public collat_borrowed_balances; // Amount of collateral the contract borrowed in e18, by Collateral
    int256 public collat_borrowed_sum; // Across all AMOs

    // USDK balance related
    uint256 public usdkDollarBalanceStored;

    // Collateral balance related
    uint256 public collatDollarBalanceStored;

    // AMO balance corrections
    mapping(address => int256[2]) public correction_offsets_amos;
    // [amo_address][0] = AMO's usdk_val_e18
    // [amo_address][1] = AMO's collat_val_e18

    /* ========== CONSTRUCTOR ========== */
    
    function initialize(
        address _locator,
        address _custodian_address
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
        usdk_address = locator.usdk();
        krome_address = locator.krome();
        custodian_address = _custodian_address;

        /* ------------- default congfigurations ------------- */

        min_cr = 810000;

        collat_borrow_cap = int256(10000000e18);

        // Max amount of USDK and KROME this contract can mint
        usdk_mint_cap = int256(100000000e18);
        krome_mint_cap = int256(100000000e18);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        managerPermissionRequired();
        _;
    }

    modifier validAMO(address amo_address) {
        require(amos[amo_address], "Invalid AMO");
        _;
    }

    /* ========== VIEWS ========== */

    function collatDollarBalance() external view returns (uint256) {
        (, uint256 collat_val_e18) = dollarBalances();
        return collat_val_e18;
    }

    function dollarBalances() public view returns (uint256 usdk_val_e18, uint256 collat_val_e18) {
        usdk_val_e18 = usdkDollarBalanceStored;
        collat_val_e18 = collatDollarBalanceStored;
    }

    function allAMOAddresses() external view returns (address[] memory) {
        return amos_array;
    }

    function allAMOsLength() external view returns (uint256) {
        return amos_array.length;
    }

    function usdkTrackedGlobal() external view returns (int256) {
        return int256(usdkDollarBalanceStored) - usdk_mint_sum - (collat_borrowed_sum);
    }

    function usdkTrackedAMO(address amo_address) external view returns (int256) {
        (uint256 usdk_val_e18, ) = IAMO(amo_address).dollarBalances();
        int256 usdk_val_e18_corrected = int256(usdk_val_e18) + correction_offsets_amos[amo_address][0];
        return usdk_val_e18_corrected - usdk_mint_balances[amo_address] - amo_collat_borrowed_balances[amo_address];
    }

    function allCollaterals() external view returns (Collateral[] memory) {
        return collaterals;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    function safe_uint256(int256 v) internal pure returns (uint256) {
        if (v < 0) return 0;
        return uint256(v);
    }

    // Callable by anyone willing to pay the gas
    function syncDollarBalances() public {
        uint256 total_usdk_value_d18 = 0;
        uint256 total_collateral_value_d18 = 0; 
        for (uint i = 0; i < amos_array.length; i++){ 
            // Exclude null addresses
            address amo_address = amos_array[i];
            if (amo_address != address(0)){
                (uint256 usdk_val_e18, uint256 collat_val_e18) = IAMO(amo_address).dollarBalances();
                total_usdk_value_d18 += safe_uint256(int256(usdk_val_e18) + correction_offsets_amos[amo_address][0]);
                total_collateral_value_d18 += safe_uint256(int256(collat_val_e18) + correction_offsets_amos[amo_address][1]);
            }
        }
        usdkDollarBalanceStored = total_usdk_value_d18;
        collatDollarBalanceStored = total_collateral_value_d18;
    }

    /* ========== OWNER / GOVERNANCE FUNCTIONS ONLY ========== */
    // Only owner or timelock can call, to limit risk 

    // ------------------------------------------------------------------
    // ------------------------------ USDK ------------------------------
    // ------------------------------------------------------------------

    // This contract is essentially marked as a 'pool' so it can call OnlyPools functions like pool_mint and pool_burn_from
    // on the main USDK contract
    function mintUsdkForAMO(address destination_amo, uint256 usdk_amount) external onlyByOwnGov validAMO(destination_amo) {
        int256 usdk_amt_i256 = int256(usdk_amount);

        // Make sure you aren't minting more than the mint cap
        require((usdk_mint_sum + usdk_amt_i256) <= usdk_mint_cap, "Mint cap reached");
        usdk_mint_balances[destination_amo] += usdk_amt_i256;
        usdk_mint_sum += usdk_amt_i256;

        // Make sure the USDK minting wouldn't push the CR down too much
        // This is also a sanity check for the int256 math
        uint256 current_collateral_E18 = IUsdk(usdk_address).globalCollateralValue();
        uint256 cur_usdk_supply = ERC20(usdk_address).totalSupply();
        uint256 new_usdk_supply = cur_usdk_supply + usdk_amount;
        uint256 new_cr = (current_collateral_E18 * PRICE_PRECISION) / new_usdk_supply;
        require(new_cr >= min_cr, "CR would be too low");

        // Mint the USDK to the AMO
        IUsdk(usdk_address).pool_mint(destination_amo, usdk_amount);

        // Sync
        syncDollarBalances();
    }

    function burnUsdkFromAMO(uint256 usdk_amount) external validAMO(msg.sender) {
        int256 usdk_amt_i256 = int256(usdk_amount);

        // Burn first
        IUsdk(usdk_address).pool_burn_from(msg.sender, usdk_amount);

        // Then update the balances
        usdk_mint_balances[msg.sender] -= usdk_amt_i256;
        usdk_mint_sum -= usdk_amt_i256;

        // Sync
        syncDollarBalances();
    }

    // ------------------------------------------------------------------
    // ------------------------------- KROME ------------------------------
    // ------------------------------------------------------------------

    function mintKromeForAMO(address destination_amo, uint256 krome_amount) external onlyByOwnGov validAMO(destination_amo) {
        int256 krome_amt_i256 = int256(krome_amount);

        // Make sure you aren't minting more than the mint cap
        require((krome_mint_sum + krome_amt_i256) <= krome_mint_cap, "Mint cap reached");
        krome_mint_balances[destination_amo] += krome_amt_i256;
        krome_mint_sum += krome_amt_i256;

        // Mint the KROME to the AMO
        IKrome(krome_address).pool_mint(destination_amo, krome_amount);

        // Sync
        syncDollarBalances();
    }

    function burnKromeFromAMO(uint256 krome_amount) external validAMO(msg.sender) {
        int256 krome_amt_i256 = int256(krome_amount);

        // Burn first
        IKrome(krome_address).pool_burn_from(msg.sender, krome_amount);

        // Then update the balances
        krome_mint_balances[msg.sender] -= krome_amt_i256;
        krome_mint_sum -= krome_amt_i256;

        // Sync
        syncDollarBalances();
    }

    // ------------------------------------------------------------------
    // --------------------------- Collateral ---------------------------
    // ------------------------------------------------------------------

    function giveCollatToAMO(
        address destination_amo,
        address collateral_address,
        uint256 collat_amount
    ) external onlyByOwnGov validAMO(destination_amo) {
        uint256 collat_order = collateral_order[collateral_address];
        require(collat_order > 0, "invalid collateral");

        Collateral memory collat = collaterals[collat_order - 1];

        require(collat_amount < 2 ** 255 / (10 ** collat.missing_decimals), "collat_amount overflow");
        int256 collat_amount_i256 = int256(collat_amount * (10 ** collat.missing_decimals));

        require((collat_borrowed_sum + collat_amount_i256) <= collat_borrow_cap, "Borrow cap");
        amo_collat_borrowed_balances[destination_amo] += collat_amount_i256;
        collat_borrowed_balances[collateral_address] += collat_amount_i256;
        collat_borrowed_sum += collat_amount_i256;

        IUsdkPoolV5 pool = IUsdkPoolV5(collat.pool_address);

        // Borrow the collateral
        pool.amoMinterBorrow(collat.col_idx, collat_amount);

        // Give the collateral to the AMO
        TransferHelper.safeTransfer(collateral_address, destination_amo, collat_amount);

        // Sync
        syncDollarBalances();
    }

    function receiveCollatFromAMO(address collateral_address, uint256 collat_amount) external validAMO(msg.sender) {
        uint256 collat_order = collateral_order[collateral_address];
        require(collat_order > 0, "invalid collateral");

        Collateral memory collat = collaterals[collat_order - 1];

        IUsdkPoolV5 pool = IUsdkPoolV5(collat.pool_address);

        require(collat_amount < 2 ** 255 / (10 ** collat.missing_decimals), "collat_amount overflow");
        int256 collat_amt_i256 = int256(collat_amount * (10 ** collat.missing_decimals));

        // Give back first
        TransferHelper.safeTransferFrom(collateral_address, msg.sender, address(pool), collat_amount);

        // Then update the balances
        amo_collat_borrowed_balances[msg.sender] -= collat_amt_i256;
        collat_borrowed_balances[collateral_address] -= collat_amt_i256;
        collat_borrowed_sum -= collat_amt_i256;

        // Sync
        syncDollarBalances();
    }

    function rebalanceCollatBorrowing(address collateral_from, address collateral_to, uint256 collat_amount_e18) external onlyByOwnGov {
        uint256 collat_from_order = collateral_order[collateral_from];
        require(collat_from_order> 0, "invalid collateral from address");
        uint256 collat_to_order = collateral_order[collateral_to];
        require(collat_to_order> 0, "invalid collateral to address");

        require(collat_amount_e18 < 2 ** 255, "collat_amount overflow");
        int256 collat_amt_i256 = int256(collat_amount_e18);

        collat_borrowed_balances[collateral_from] -= collat_amt_i256;
        collat_borrowed_balances[collateral_to] += collat_amt_i256;
    }

    // migrate borrowing from old minter
    function migrateBorrowing(address amo_address, address collateral_address, uint256 collat_amount_e18) external onlyByOwnGov {
        uint256 collat_order = collateral_order[collateral_address];
        require(collat_order> 0, "invalid collateral from address");

        require(collat_amount_e18 < 2 ** 255, "collat_amount overflow");
        int256 collat_amount_i256 = int256(collat_amount_e18);

        amo_collat_borrowed_balances[amo_address] += collat_amount_i256;
        collat_borrowed_balances[collateral_address] += collat_amount_i256;
        collat_borrowed_sum += collat_amount_i256;
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function addCollateral(address collateral_address, address pool_address) public onlyByOwnGov {
        require(collateral_order[collateral_address] == 0, "duplicated collateral");
        require(IUsdkPoolV5(pool_address).enabled_collaterals(collateral_address), "invalid or disabled collateral");
        uint256 col_idx = IUsdkPoolV5(pool_address).collateralAddrToIdx(collateral_address);
        require(col_idx < 2**96, "too big col_idx");

        collaterals.push(Collateral({
            collateral_address: collateral_address,
            missing_decimals: uint8(18) - ERC20(collateral_address).decimals(),
            pool_address: pool_address,
            col_idx: uint96(col_idx)
        }));
        collateral_order[collateral_address] = collaterals.length;
    }

    function updateCollateral(address collateral_address, address pool_address) public onlyByOwnGov {
        uint256 collat_order = collateral_order[collateral_address];
        require(collateral_order[collateral_address] > 0, "duplicated collateral");
        require(IUsdkPoolV5(pool_address).enabled_collaterals(collateral_address), "invalid or disabled collateral");
        uint256 col_idx = IUsdkPoolV5(pool_address).collateralAddrToIdx(collateral_address);
        require(col_idx < 2**96, "too big col_idx");

        collaterals[collat_order - 1] = Collateral({
            collateral_address: collateral_address,
            missing_decimals: uint8(18) - ERC20(collateral_address).decimals(),
            pool_address: pool_address,
            col_idx: uint96(col_idx)
        });
    }

    // Adds an AMO 
    function addAMO(address amo_address, bool sync_too) public onlyByOwnGov {
        require(amo_address != address(0), "Zero address detected");

        (uint256 usdk_val_e18, uint256 collat_val_e18) = IAMO(amo_address).dollarBalances();
        require(usdk_val_e18 >= 0 && collat_val_e18 >= 0, "Invalid AMO");

        require(amos[amo_address] == false, "Address already exists");
        amos[amo_address] = true; 
        amos_array.push(amo_address);

        // Mint balances
        usdk_mint_balances[amo_address] = 0;
        krome_mint_balances[amo_address] = 0;
        amo_collat_borrowed_balances[amo_address] = 0;

        // Offsets
        correction_offsets_amos[amo_address][0] = 0;
        correction_offsets_amos[amo_address][1] = 0;

        if (sync_too) syncDollarBalances();

        emit AMOAdded(amo_address);
    }

    // Removes an AMO
    function removeAMO(address amo_address, bool sync_too) public onlyByOwnGov {
        require(amo_address != address(0), "Zero address detected");
        require(amos[amo_address] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete amos[amo_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint i = 0; i < amos_array.length; i++){ 
            if (amos_array[i] == amo_address) {
                amos_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        if (sync_too) syncDollarBalances();

        emit AMORemoved(amo_address);
    }

    function setCustodian(address _custodian_address) external onlyByOwnGov {
        require(_custodian_address != address(0), "Custodian address cannot be 0");
        custodian_address = _custodian_address;
    }

    function setUsdkMintCap(uint256 _usdk_mint_cap) external onlyByOwnGov {
        usdk_mint_cap = int256(_usdk_mint_cap);
    }

    function setKromeMintCap(uint256 _krome_mint_cap) external onlyByOwnGov {
        krome_mint_cap = int256(_krome_mint_cap);
    }

    function setCollatBorrowCap(uint256 _collat_borrow_cap) external onlyByOwnGov {
        collat_borrow_cap = int256(_collat_borrow_cap);
    }

    function setMinimumCollateralRatio(uint256 _min_cr) external onlyByOwnGov {
        min_cr = _min_cr;
    }

    function setAMOCorrectionOffsets(address amo_address, int256 usdk_e18_correction, int256 collat_e18_correction) external onlyByOwnGov {
        correction_offsets_amos[amo_address][0] = usdk_e18_correction;
        correction_offsets_amos[amo_address][1] = collat_e18_correction;

        syncDollarBalances();
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        // Can only be triggered by owner or governance
        TransferHelper.safeTransfer(tokenAddress, owner, tokenAmount);
        
        emit Recovered(tokenAddress, tokenAmount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        return (success, result);
    }

    /* ========== EVENTS ========== */

    event AMOAdded(address amo_address);
    event AMORemoved(address amo_address);
    event Recovered(address token, uint256 amount);
}