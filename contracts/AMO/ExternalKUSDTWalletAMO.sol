// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./ExternalCollateralWalletAMO.sol";
import "../External/Eklipse/IEklipseSwap.sol";
import "../External/Eklipse/IEklipseGauge.sol";
import "../External/Kleva/IKlevaIBToken.sol";
import "../External/Kleva/IKlevaStakePool.sol";
import "../External/Kokoa/IKokoaLedger.sol";
import "../External/Kokoa/IKokoaBond.sol";
import "../ERC20/ERC20.sol";
import "../Usdk/IUsdk.sol";

contract ExternalKUSDTWalletAMO is ExternalCollateralWalletAMO {
    uint256 constant public IBTOKEN_PRICE_PRECISTION = 1e9;
    uint256 constant public MISSING_PRECISION = 1e12;
    IKokoaLedger constant public kokoaLedger = IKokoaLedger(0x1242ECA3F543699173d1fAEc299552fAb65E0924);

    struct Token {
        address token_address;
        uint8 decimals;
    }

    struct EklipsePool {
        address eklp_address;
        address swap_address;
        address gauge_address;
    }

    struct KlevaPool {
        uint256 pool_index;
        address ib_token_address;
        uint8 decimals;
    }

    struct KokoaBond {
        bytes32 collateral_type;
        address bond_address;
        uint8 decimals;
    }

    uint256 public eklipse_value_stored;
    uint256 public kleva_value_stored;
    uint256 public kokoa_value_stored;

    Token[] public stable_tokens;
    mapping(address => uint256) stable_token_order;
    EklipsePool[] public eklipse_pools;
    mapping(address => uint256) eklipse_pool_order;
    KlevaPool[] public kleva_pools;
    mapping(uint256 => uint256) kleva_pool_order;
    KokoaBond[] public kokoa_bonds;
    mapping(bytes32 => uint256) kokoa_bond_order;

    /* ========== INITIALIZER ========== */

    function initialize(
        address _locator_address,
        address _amo_minter,
        address _external_wallet
    ) public initializer {
        ExternalCollateralWalletAMO.initializeExternalWalletAMO(_locator_address, _amo_minter, _external_wallet);
        require(10 ** amo_minter.missing_decimals() == MISSING_PRECISION, "Invalid missing decimals");
    }

    /* ========== FINANCIAL VIEW ========== */

    function stable_tokens_length() external view returns (uint256) {
        return stable_tokens.length;
    }

    function getStableTokens() external view returns (Token[] memory) {
        return stable_tokens;
    }

    function eklipse_pools_length() external view returns (uint256) {
        return eklipse_pools.length;
    }

    function getEklipsePools() external view returns (EklipsePool[] memory) {
        return eklipse_pools;
    }

    function kleva_pools_length() external view returns (uint256) {
        return kleva_pools.length;
    }

    function getKlevaPools() external view returns (KlevaPool[] memory) {
        return kleva_pools;
    }

    function kokoa_bonds_length() external view returns (uint256) {
        return kokoa_bonds.length;
    }

    function getKokoaBonds() external view returns (KokoaBond[] memory) {
        return kokoa_bonds;
    }

    function dollarBalances() external view returns (uint256 usdk_val_e18, uint256 collat_val_e18) {
        usdk_val_e18 = 0;

        uint256 tokens_value = 0;
        for (uint256 i = 0; i < stable_tokens.length; i++) {
            tokens_value += IERC20(stable_tokens[i].token_address).balanceOf(external_wallet_address) * (10 ** (18 - stable_tokens[i].decimals));
        }

        // only CR portion of borrowed USDK is considered as collateral
        collat_val_e18 = IERC20(amo_minter.collateral_address()).balanceOf(external_wallet_address) * MISSING_PRECISION + tokens_value + eklipse_value_stored + kleva_value_stored + kokoa_value_stored;
    }

    function eklipse_value() public view returns (uint256 value) {
        for (uint i = 0; i < eklipse_pools.length; i++) {
            EklipsePool memory entry = eklipse_pools[i];
            IERC20 eklp = IERC20(entry.eklp_address);
            IEklipseSwap swap = IEklipseSwap(entry.swap_address);
            IEklipseGauge eklp_gauge = IEklipseGauge(entry.gauge_address);

            (uint256 deposit_amount,,) = eklp_gauge.userInfo(external_wallet_address);

            value += (eklp.balanceOf(external_wallet_address) + deposit_amount) * swap.getVirtualPrice() / 1e18;
        }
    }

    function kleva_value() public view returns (uint256) {
        address kleva_pool_address = locator.kleva_pool();
        if (kleva_pool_address == address(0)) return 0;
        IKlevaStakePool klevaPool = IKlevaStakePool(kleva_pool_address);

        uint256 value = 0;
        for (uint i = 0; i < kleva_pools.length; i++) {
            IKlevaIBToken ibToken = IKlevaIBToken(kleva_pools[i].ib_token_address);
            uint256 ibTokenPrice;
            {
                uint256 totalSupply = ibToken.totalSupply();
                uint256 totalToken = ibToken.getTotalToken();
                ibTokenPrice = totalToken * IBTOKEN_PRICE_PRECISTION / totalSupply;
            }

            uint256 ibTokenBalance = ibToken.balanceOf(external_wallet_address);
            (uint256 ibTokenDeposited,,) = klevaPool.userInfos(kleva_pools[i].pool_index, external_wallet_address);

            value += (ibTokenBalance + ibTokenDeposited) * (10 ** (18 - kleva_pools[i].decimals)) * ibTokenPrice / IBTOKEN_PRICE_PRECISTION;
        }

        return value;
    }

    function kokoa_value() public view returns (uint256 value) {
        for (uint i = 0; i < kokoa_bonds.length; i++) {
            (uint256 locked_amount,) = kokoaLedger.accountInfo(kokoa_bonds[i].collateral_type, external_wallet_address);

            IKokoaBond bond = IKokoaBond(kokoa_bonds[i].bond_address);
            value += bond.toTokenAmount(locked_amount);
        }
    }

    /* ========== SYNC ========== */

    function syncEklipse() public {
        eklipse_value_stored = eklipse_value();
    }

    function syncKleva() public {
        kleva_value_stored = kleva_value();
    }

    function syncKokoa() internal {
        kokoa_value_stored = kokoa_value();
    }

    function sync() external {
        syncEklipse();
        syncKleva();
        syncKokoa();
    }

    /* ========== MANAGE ========== */

    function addStableToken(address token) external onlyByManager {
        require(stable_token_order[token] == 0, "duplicated token");
        stable_tokens.push(Token(token, ERC20(token).decimals()));
        stable_token_order[token] = stable_tokens.length;
    }

    function removeStableToken(address token) external onlyByManager {
        require(stable_token_order[token] > 0, "unknown token");
        uint256 order = stable_token_order[token];
        if (order < stable_tokens.length) {
            stable_tokens[order - 1] = stable_tokens[stable_tokens.length - 1];
            stable_token_order[stable_tokens[order - 1].token_address] = order;
        }
        stable_tokens.pop();
        stable_token_order[token] = 0;
    }

    function addEklipsePool(address eklp_address, address swap_address, address gauge_address) external onlyByManager {
        require(eklipse_pool_order[eklp_address] == 0, "duplicated eklp");
        eklipse_pools.push(EklipsePool(eklp_address, swap_address, gauge_address));
        eklipse_pool_order[eklp_address] = eklipse_pools.length;
    }

    function removeEklipsePool(address eklp_address) external onlyByManager {
        require(eklipse_pool_order[eklp_address] > 0, "unknown eklp");
        uint256 order = eklipse_pool_order[eklp_address];
        if (order < eklipse_pools.length) {
            eklipse_pools[order - 1] = eklipse_pools[eklipse_pools.length - 1];
            eklipse_pool_order[eklipse_pools[order - 1].eklp_address] = order;
        }
        eklipse_pools.pop();
        eklipse_pool_order[eklp_address] = 0;
    }

    function addKlevaPool(uint256 pool_index, address ib_token) external onlyByManager {
        require(kleva_pool_order[pool_index] == 0, "duplicated index");
        kleva_pools.push(KlevaPool(pool_index, ib_token, ERC20(ib_token).decimals()));
        kleva_pool_order[pool_index] = kleva_pools.length;
    }

    function removeKlevaPool(uint256 pool_index) external onlyByManager {
        require(kleva_pool_order[pool_index] > 0, "unknown index");
        uint256 order = kleva_pool_order[pool_index];
        if (order < kleva_pools.length) {
            kleva_pools[order - 1] = kleva_pools[kleva_pools.length - 1];
            kleva_pool_order[kleva_pools[order - 1].pool_index] = order;
        }
        kleva_pools.pop();
        kleva_pool_order[pool_index] = 0;
    }

    function addKokoaBond(bytes32 collateral_type, address bond_token) external onlyByManager {
        require(kokoa_bond_order[collateral_type] == 0, "duplicated collat type");
        kokoa_bonds.push(KokoaBond(collateral_type, bond_token, ERC20(bond_token).decimals()));
        kokoa_bond_order[collateral_type] = kokoa_bonds.length;
    }

    function removeKokoaBond(bytes32 collateral_type) external onlyByManager {
        require(kokoa_bond_order[collateral_type] > 0, "unknown collat type");
        uint256 order = kokoa_bond_order[collateral_type];
        if (order < kokoa_bonds.length) {
            kokoa_bonds[order - 1] = kokoa_bonds[kokoa_bonds.length - 1];
            kokoa_bond_order[kokoa_bonds[order - 1].collateral_type] = order;
        }
        kokoa_bonds.pop();
        kokoa_bond_order[collateral_type] = 0;
    }
}