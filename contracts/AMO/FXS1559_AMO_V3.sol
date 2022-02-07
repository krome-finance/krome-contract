// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// ====================================================================
// |     ______                   _______                             |
// |    / _____________ __  __   / ____(_____  ____ _____  ________   |
// |   / /_  / ___/ __ `| |/_/  / /_  / / __ \/ __ `/ __ \/ ___/ _ \  |
// |  / __/ / /  / /_/ _>  <   / __/ / / / / / /_/ / / / / /__/  __/  |
// | /_/   /_/   \__,_/_/|_|  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/   |
// |                                                                  |
// ====================================================================
// ========================== FXS1559_AMO_V3 ==========================
// ====================================================================
// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian

// Modified by : https://github.com/krome-finance

import "../ERC20/IERC20.sol";
import "../Usdk/IUsdk.sol";
import "../Usdk/IAMOMinter.sol";
import "../Usdk/IUsdkPool.sol";
import "../Oracle/IPairPriceOracle.sol";
import '../Libs/TransferHelper.sol';
import "../Common/Owned.sol";
import "../VeKrome/IYieldDistributor.sol";
import "../Helper/ITokenSwapHelper.sol";

contract FXS1559_AMO_V3 is Owned {
    // SafeMath automatically included in Solidity >= 8.0.0

    /* ========== STATE VARIABLES ========== */

    address immutable usdk_address;
    address immutable krome_address;
    ITokenSwapHelper private tokenSwapHelper;
    IAMOMinter public amo_minter;
    IUsdkPool public pool;
    IYieldDistributor public yieldDistributor;
    
    // address private constant collateral_address = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public timelock_address;
    address public custodian_address;
    address public amo_minter_address;

    // uint256 private missing_decimals;
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;

    // USDK -> KROME max slippage
    uint256 public max_slippage;

    // Burned vs given to yield distributor
    uint256 public burn_fraction; // E6. Fraction of KROME burned vs transferred to the yield distributor

    /* ========== CONSTRUCTOR ========== */
    
    constructor (
        address _owner_address,
        address _usdk,
        address _krome,
        address _yield_distributor_address,
        address _amo_minter_address,
        address _pool_address,
        address _token_swap_helper_address
    ) Owned(_owner_address) {
        owner = _owner_address;
        usdk_address = _usdk;
        krome_address = _krome;
        // collateral_token = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        // missing_decimals = uint(18).sub(collateral_token.decimals());
        yieldDistributor = IYieldDistributor(_yield_distributor_address);
        
        // Initializations
        amo_minter_address = _amo_minter_address;
        amo_minter = IAMOMinter(_amo_minter_address);
        pool = IUsdkPool(_pool_address);
        tokenSwapHelper = ITokenSwapHelper(_token_swap_helper_address);

        max_slippage = 50000; // 5%
        burn_fraction = 0; // Give all to veKROME initially

        // Get the custodian and timelock addresses from the minter
        custodian_address = amo_minter.custodian_address();
        timelock_address = amo_minter.timelock_address();
    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCust() {
        require(msg.sender == timelock_address || msg.sender == owner || msg.sender == custodian_address, "Not owner, tlck, or custd");
        _;
    }

    modifier onlyByMinter() {
        require(msg.sender == address(amo_minter), "Not minter");
        _;
    }

    /* ========== VIEWS ========== */

    function dollarBalances() public view returns (uint256 usdk_val_e18, uint256 collat_val_e18) {
        usdk_val_e18 = IERC20(usdk_address).balanceOf(address(this));
        // collat_val_e18 = usdk_val_e18.mul(COLLATERAL_RATIO_PRECISION).div(IUsdk(usdk_address).global_collateral_ratio());
        collat_val_e18 = usdk_val_e18 * IUsdk(usdk_address).global_collateral_ratio() / COLLATERAL_RATIO_PRECISION;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function _swapUSDKforKROME(uint256 usdk_amount) internal returns (uint256 usdk_spent, uint256 krome_received) {
        // KROME price
        uint256 min_krome_out = pool.getUsdkPrice() * usdk_amount / pool.getKromePrice();
        min_krome_out = min_krome_out - (min_krome_out * max_slippage / PRICE_PRECISION);

        (bool success, bytes memory returnData) = address(tokenSwapHelper).delegatecall(
            abi.encodeWithSignature("swap(address,uint256,address,uint256)", usdk_address, usdk_amount, krome_address, min_krome_out)
        );
        require(success, success ? "" : _getRevertMsg(returnData));
        // require(success, 'swap failed');
        (usdk_spent, krome_received) = abi.decode(returnData, (uint256, uint256));
        require(krome_received >= min_krome_out, 'under slippage');
    }


    // Burn unneeded or excess USDK
    function swapBurn(uint256 override_usdk_amount, bool use_override) public onlyByOwnGov {
        uint256 mintable_usdk;
        if (use_override){
            // mintable_usdk = override_USDC_amount.mul(10 ** missing_decimals).mul(COLLATERAL_RATIO_PRECISION).div(USDK.global_collateral_ratio());
            mintable_usdk = override_usdk_amount;
        }
        else {
            mintable_usdk = pool.buybackAvailableCollat();
        }

        (, uint256 krome_received ) = _swapUSDKforKROME(mintable_usdk);

        // Calculate the amount to burn vs give to the yield distributor
        uint256 amt_to_burn = krome_received * burn_fraction / PRICE_PRECISION;
        uint256 amt_to_yield_distributor = krome_received - amt_to_burn;

        // Burn some of the KROME
        burnKrome(amt_to_burn);

        // Give the rest to the yield distributor
        IERC20(krome_address).approve(address(yieldDistributor), amt_to_yield_distributor);
        yieldDistributor.notifyRewardAmount(amt_to_yield_distributor);
    }

    /* ========== Burns and givebacks ========== */

    // Burn unneeded or excess USDK. Goes through the minter
    function burnUsdk(uint256 usdk_amount) external onlyByOwnGovCust {
        IERC20(usdk_address).approve(address(amo_minter), usdk_amount);
        amo_minter.burnUsdkFromAMO(usdk_amount);
    }

    // Burn unneeded KROME. Goes through the minter
    function burnKrome(uint256 krome_amount) public onlyByOwnGovCust {
        IERC20(krome_address).approve(address(amo_minter), krome_amount);
        amo_minter.burnKromeFromAMO(krome_amount);
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function setBurnFraction(uint256 _burn_fraction) external onlyByOwnGov {
        require(_burn_fraction <= 1e6);
        burn_fraction = _burn_fraction;
    }

    function setUsdkPool(address _usdk_pool_address) external onlyByOwnGov {
        pool = IUsdkPool(_usdk_pool_address);
    }

    function setAMOMinter(address _amo_minter_address) external onlyByOwnGov {
        amo_minter = IAMOMinter(_amo_minter_address);

        custodian_address = amo_minter.custodian_address();
        // Get the timelock address from the minter
        timelock_address = amo_minter.timelock_address();

        // Make sure the new address is not address(0)
        require(timelock_address != address(0), "Invalid timelock");
    }

    function setSafetyParams(uint256 _max_slippage) external onlyByOwnGov {
        require(_max_slippage <= 1e6);
        max_slippage = _max_slippage;
    }

    function setTokenSwapHelper(address _token_swap_helper_address) external onlyByOwnGov {
        tokenSwapHelper = ITokenSwapHelper(_token_swap_helper_address);
    }

    function setYieldDistributor(address _yield_distributor_address) external onlyByOwnGov {
        yieldDistributor = IYieldDistributor(_yield_distributor_address);
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        TransferHelper.safeTransfer(tokenAddress, msg.sender, tokenAmount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByOwnGov returns (bool, bytes memory) {
        (bool success, bytes memory result) = _to.call{value:_value}(_data);
        // require(success, "execute failed");
        require(success, success ? "" : _getRevertMsg(result));
        return (success, result);
    }

    function _getRevertMsg(bytes memory _returnData) internal pure returns (string memory) {
        // If the _res length is less than 68, then the transaction failed silently (without a revert message)
        if (_returnData.length < 68) return "executeTransaction: Transaction execution reverted.";

        assembly {
            // Slice the sighash.
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string)); // All that remains is the revert string
    }
}