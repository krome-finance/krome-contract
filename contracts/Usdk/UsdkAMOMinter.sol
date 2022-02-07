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
import "../Krome/IKrome.sol";
import "./IUsdkPool.sol";
import "../ERC20/ERC20.sol";
import "../Common/TimelockOwned.sol";
import '../Libs/TransferHelper.sol';
import '../AMO/IAMO.sol';

contract UsdkAMOMinter is TimelockOwned {
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== STATE VARIABLES ========== */

    // Core
    address immutable usdk_address;
    address immutable krome_address;
    ERC20 public collateral_token;
    IUsdkPool public pool;
    address public custodian_address;

    // Collateral related
    address public collateral_address;
    uint256 public col_idx;

    // AMO addresses
    address[] public amos_array;
    mapping(address => bool) public amos; // Mapping is also used for faster verification

    // Price constants
    uint256 private constant PRICE_PRECISION = 1e6;

    // Max amount of collateral the contract can borrow from the UsdkPool
    int256 public collat_borrow_cap = int256(10000000e6);

    // Max amount of USDK and KROME this contract can mint
    int256 public usdk_mint_cap = int256(100000000e18);
    int256 public krome_mint_cap = int256(100000000e18);

    // Minimum collateral ratio needed for new USDK minting
    uint256 public min_cr = 810000;

    // Usdk mint balances
    mapping(address => int256) public usdk_mint_balances; // Amount of USDK the contract minted, by AMO
    int256 public usdk_mint_sum = 0; // Across all AMOs

    // Krome mint balances
    mapping(address => int256) public krome_mint_balances; // Amount of KROME the contract minted, by AMO
    int256 public krome_mint_sum = 0; // Across all AMOs

    // Collateral borrowed balances
    mapping(address => int256) public collat_borrowed_balances; // Amount of collateral the contract borrowed, by AMO
    int256 public collat_borrowed_sum = 0; // Across all AMOs

    // USDK balance related
    uint256 public usdkDollarBalanceStored = 0;

    // Collateral balance related
    uint256 public missing_decimals;
    uint256 public collatDollarBalanceStored = 0;

    // AMO balance corrections
    mapping(address => int256[2]) public correction_offsets_amos;
    // [amo_address][0] = AMO's usdk_val_e18
    // [amo_address][1] = AMO's collat_val_e18

    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _usdk,
        address _krome,
        address _owner_address,
        address _timelock_address,
        address _custodian_address,
        address _collateral_address,
        address _pool_address
    ) TimelockOwned(_owner_address, _timelock_address) {
        usdk_address = _usdk;
        krome_address = _krome;
        custodian_address = _custodian_address;

        // Pool related
        pool = IUsdkPool(_pool_address);

        // Collateral related
        collateral_address = _collateral_address;
        col_idx = pool.collateralAddrToIdx(_collateral_address);
        collateral_token = ERC20(_collateral_address);
        missing_decimals = uint(18) - collateral_token.decimals();
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
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
        return int256(usdkDollarBalanceStored) - usdk_mint_sum - (collat_borrowed_sum * int256(10 ** missing_decimals));
    }

    function usdkTrackedAMO(address amo_address) external view returns (int256) {
        (uint256 usdk_val_e18, ) = IAMO(amo_address).dollarBalances();
        int256 usdk_val_e18_corrected = int256(usdk_val_e18) + correction_offsets_amos[amo_address][0];
        return usdk_val_e18_corrected - usdk_mint_balances[amo_address] - ((collat_borrowed_balances[amo_address]) * int256(10 ** missing_decimals));
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
        uint256 collat_amount
    ) external onlyByOwnGov validAMO(destination_amo) {
        int256 collat_amount_i256 = int256(collat_amount);

        require((collat_borrowed_sum + collat_amount_i256) <= collat_borrow_cap, "Borrow cap");
        collat_borrowed_balances[destination_amo] += collat_amount_i256;
        collat_borrowed_sum += collat_amount_i256;

        // Borrow the collateral
        pool.amoMinterBorrow(collat_amount);

        // Give the collateral to the AMO
        TransferHelper.safeTransfer(collateral_address, destination_amo, collat_amount);

        // Sync
        syncDollarBalances();
    }

    function receiveCollatFromAMO(uint256 collat_amount) external validAMO(msg.sender) {
        int256 collat_amt_i256 = int256(collat_amount);

        // Give back first
        TransferHelper.safeTransferFrom(collateral_address, msg.sender, address(pool), collat_amount);

        // Then update the balances
        collat_borrowed_balances[msg.sender] -= collat_amt_i256;
        collat_borrowed_sum -= collat_amt_i256;

        // Sync
        syncDollarBalances();
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

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
        collat_borrowed_balances[amo_address] = 0;

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

    function setUsdkPool(address _pool_address) external onlyByOwnGov {
        pool = IUsdkPool(_pool_address);

        // Make sure the collaterals match, or balances could get corrupted
        require(pool.collateralAddrToIdx(collateral_address) == col_idx, "col_idx mismatch");
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