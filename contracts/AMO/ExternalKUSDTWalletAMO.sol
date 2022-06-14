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

    struct TokenValue {
        address token_address;
        uint256 amount;
    }

    struct EklipsePool {
        address eklp_address;
        address swap_address;
        address gauge_address;
    }

    struct EklipseValue {
        address eklp_address;
        uint256 amount;
    }

    struct KlevaPool {
        uint256 pool_index;
        address ib_token_address;
        uint8 decimals;
    }

    struct KlevaValue {
        address ib_token_address;
        uint256 amount;
    }

    struct KokoaBond {
        bytes32 collateral_type;
        address bond_address;
        uint8 decimals;
    }

    struct KokoaValue {
        bytes32 collateral_type;
        uint256 amount;
    }

    struct BridgedValue {
        bytes32 where;
        uint256 amount;
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

    // added 2022.05.06
    uint256 public tokens_value_stored;

    BridgedValue[] public bridged_collaterals;
    mapping(bytes32 => uint256) bridged_collateral_order;
    uint256 public bridged_value_stored;

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

        // only CR portion of borrowed USDK is considered as collateral
        collat_val_e18 = tokens_value_stored + eklipse_value_stored + kleva_value_stored + kokoa_value_stored + bridged_value_stored;
    }

    function _token_value(Token memory _entry) internal view returns (uint256) {
        return IERC20(_entry.token_address).balanceOf(external_wallet_address) * (10 ** (18 - _entry.decimals));
    }

    function tokens_value() public view returns (uint256 value) {
        for (uint256 i = 0; i < stable_tokens.length; i++) {
            value += _token_value(stable_tokens[i]);
        }
    }

    function token_values() external view returns (TokenValue[] memory values) {
        values = new TokenValue[](stable_tokens.length);
        for (uint256 i = 0; i < stable_tokens.length; i++) {
            values[i].token_address = stable_tokens[i].token_address;
            values[i].amount = _token_value(stable_tokens[i]);
        }
    }

    function _eklipse_pool_value(EklipsePool memory entry) internal view returns (uint256) {
        IERC20 eklp = IERC20(entry.eklp_address);
        IEklipseSwap swap = IEklipseSwap(entry.swap_address);
        IEklipseGauge eklp_gauge = IEklipseGauge(entry.gauge_address);

        (uint256 deposit_amount,,) = eklp_gauge.userInfo(external_wallet_address);

        return (eklp.balanceOf(external_wallet_address) + deposit_amount) * swap.getVirtualPrice() / 1e18;
    }

    function eklipse_value() public view returns (uint256 value) {
        for (uint i = 0; i < eklipse_pools.length; i++) {
            EklipsePool memory entry = eklipse_pools[i];
            value += _eklipse_pool_value(entry);
        }
    }

    function eklipse_values() external view returns (EklipseValue[] memory values) {
        values = new EklipseValue[](eklipse_pools.length);
        for (uint i = 0; i < eklipse_pools.length; i++) {
            EklipsePool memory entry = eklipse_pools[i];
            values[i].amount = _eklipse_pool_value(entry);
            values[i].eklp_address = eklipse_pools[i].eklp_address;
        }
 
    }

    function _kleva_pool_value(IKlevaStakePool klevaPool, KlevaPool memory entry) internal view returns (uint256) {
        IKlevaIBToken ibToken = IKlevaIBToken(entry.ib_token_address);
        uint256 ibTokenPrice;
        {
            uint256 totalSupply = ibToken.totalSupply();
            uint256 totalToken = ibToken.getTotalToken();
            ibTokenPrice = totalToken * IBTOKEN_PRICE_PRECISTION / totalSupply;
        }

        uint256 ibTokenBalance = ibToken.balanceOf(external_wallet_address);
        (uint256 ibTokenDeposited,,) = klevaPool.userInfos(entry.pool_index, external_wallet_address);

        return (ibTokenBalance + ibTokenDeposited) * (10 ** (18 - entry.decimals)) * ibTokenPrice / IBTOKEN_PRICE_PRECISTION;
    }

    function kleva_value() public view returns (uint256) {
        address kleva_pool_address = locator.kleva_pool();
        if (kleva_pool_address == address(0)) return 0;
        IKlevaStakePool klevaPool = IKlevaStakePool(kleva_pool_address);

        uint256 value = 0;
        for (uint i = 0; i < kleva_pools.length; i++) {
            value += _kleva_pool_value(klevaPool, kleva_pools[i]);
        }

        return value;
    }

    function kleva_values() external view returns (KlevaValue[] memory values) {
        address kleva_pool_address = locator.kleva_pool();
        if (kleva_pool_address == address(0)) return new KlevaValue[](0);
        IKlevaStakePool klevaPool = IKlevaStakePool(kleva_pool_address);
        
        values = new KlevaValue[](kleva_pools.length);
        for (uint i = 0; i < kleva_pools.length; i++) {
            values[i].ib_token_address = kleva_pools[i].ib_token_address;
            values[i].amount = _kleva_pool_value(klevaPool, kleva_pools[i]);
        }
    }

    function _kokoa_bond_value(KokoaBond memory _entry) internal view returns (uint256) {
        (uint256 locked_amount,) = kokoaLedger.accountInfo(_entry.collateral_type, external_wallet_address);

        IKokoaBond bond = IKokoaBond(_entry.bond_address);
        return bond.toTokenAmount(locked_amount) * (10 ** (18 - _entry.decimals));

    }

    function kokoa_value() public view returns (uint256 value) {
        for (uint i = 0; i < kokoa_bonds.length; i++) {
            value += _kokoa_bond_value(kokoa_bonds[i]);
        }
    }

    function kokoa_values() external view returns (KokoaValue[] memory values) {
        values = new KokoaValue[](kokoa_bonds.length);
        for (uint i = 0; i < kokoa_bonds.length; i++) {
            values[i].collateral_type = kokoa_bonds[i].collateral_type;
            values[i].amount = _kokoa_bond_value(kokoa_bonds[i]);
        }
    }

    function bridged_value() public view returns (uint256 value) {
        for (uint i = 0; i < bridged_collaterals.length; i++) {
            value += bridged_collaterals[i].amount;
        }
    }

    function bridged_values() public view returns (BridgedValue[] memory values) {
        return bridged_collaterals;
    }

    /* ========== SYNC ========== */

    function syncStableTokens() public {
        tokens_value_stored = tokens_value();
    }

    function syncEklipse() public {
        eklipse_value_stored = eklipse_value();
    }

    function syncKleva() public {
        kleva_value_stored = kleva_value();
    }

    function syncKokoa() internal {
        kokoa_value_stored = kokoa_value();
    }

    function syncBridgedValue() internal {
        bridged_value_stored = bridged_value();
    }

    function sync() external {
        syncStableTokens();
        syncEklipse();
        syncKleva();
        syncKokoa();
        syncBridgedValue();
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

    function addKokoaBond(bytes32 collateral_type, address bond_token, uint8 decimals) external onlyByManager {
        require(kokoa_bond_order[collateral_type] == 0, "duplicated collat type");
        kokoa_bonds.push(KokoaBond(collateral_type, bond_token, decimals));
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

    function setBridgedValue(bytes32 _where, uint256 _value) external onlyByManager {
        uint256 order = bridged_collateral_order[_where];
        if (order > 0) {
            uint256 idx = order - 1;
            bridged_collaterals[idx].amount = _value;
        } else {
            bridged_collaterals.push(BridgedValue({
                where: _where,
                amount: _value
            }));
            bridged_collateral_order[_where] = bridged_collaterals.length;
        }
    }

    function removeBridgedValue(bytes32 _where) external onlyByManager {
        require(bridged_collateral_order[_where] > 0, "unknown collat type");
        uint256 order = bridged_collateral_order[_where];
        if (order < bridged_collaterals.length) {
            bridged_collaterals[order - 1] = bridged_collaterals[bridged_collaterals.length - 1];
            bridged_collateral_order[bridged_collaterals[order - 1].where] = order;
        }
        bridged_collaterals.pop();
        bridged_collateral_order[_where] = 0;
    }
}