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

import "../ERC20/IERC20.sol";
import "../ERC20/ERC20Custom.sol";
import "../ERC20/ERC20KIP7.sol";
import "../ERC20/ERC20.sol";
import "../Common/TimelockOwned.sol";
import "../Oracle/IPairPriceOracle.sol";
import "../Oracle/IPriceOracle.sol";
import "./ICollatBalance.sol";

interface ICollateralRatioProvider {
    function collateral_ratio() external view returns (uint256);
}

contract KromeStablecoin is ERC20Custom, ERC20KIP7, TimelockOwned {
    /* ========== STATE VARIABLES ========== */
    enum PriceChoice {
        USDK,
        KROME
    }
    IPriceOracle private eth_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    IPairPriceOracle private usdkEthOracle;
    IPairPriceOracle private kromeEthOracle;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public creator_address;
    address public controller_address; // Controller contract to dynamically adjust system parameters automatically
    address public krome_address;
    address public collateral_ratio_provider_address;
    address public usdk_eth_oracle_address;
    address public krome_eth_oracle_address;
    uint256 public constant genesis_supply = 1_300_000e18; // 1.3M USDK (genesis supply on Mainnet). This is to help with establishing the Uniswap pools, as they need liquidity

    // The addresses in this array are added by the oracle and these contracts are able to mint usdk
    address[] public usdk_pools_array;

    // Mapping is also used for faster verification
    mapping(address => bool) public usdk_pools;

    // Constants for various precisions
    uint256 private constant PRICE_PRECISION = 1e6;

    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
        require(
            usdk_pools[msg.sender] == true,
            "Only usdk pools can call this function"
        );
        _;
    }

    modifier onlyByOwnerGovernanceOrController() {
        require(
            msg.sender == owner ||
                msg.sender == timelock_address ||
                msg.sender == controller_address,
            "Not the owner, controller, or the governance timelock"
        );
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner ||
                msg.sender == timelock_address ||
                usdk_pools[msg.sender] == true,
            "Not the owner, the governance timelock, or a pool"
        );
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator_address,
        address _timelock_address
    ) TimelockOwned(payable(msg.sender), _timelock_address) {
        require(_timelock_address != address(0), "Zero address detected");
        name = _name;
        symbol = _symbol;
        creator_address = _creator_address;

        _mint(creator_address, genesis_supply);
    }

    /* ========== VIEWS ========== */

    function global_collateral_ratio() public view returns (uint256) {
        if (collateral_ratio_provider_address == address(0)) return 1e6;
        return ICollateralRatioProvider(collateral_ratio_provider_address).collateral_ratio();
    }

    // Choice = 'USDK' or 'KROME' for now
    function oracle_price(PriceChoice choice) internal view returns (uint256) {
        // Get the ETH / USD price first, and cut it down to 1e6 precision
        uint256 __eth_usd_price = uint256(eth_usd_pricer.getLatestPrice());
        uint256 price_in_eth = 0;

        if (choice == PriceChoice.USDK) {
            price_in_eth = uint256(
                usdkEthOracle.consult(address(this), PRICE_PRECISION * 1000)
            ); // How much USDK if you put in PRICE_PRECISION WETH
        } else if (choice == PriceChoice.KROME) {
            price_in_eth = uint256(
                kromeEthOracle.consult(krome_address, PRICE_PRECISION * 1000)
            ); // How much KROME if you put in PRICE_PRECISION WETH
        } else
            revert(
                "INVALID PRICE CHOICE. Needs to be either 0 (USDK) or 1 (KROME)"
            );

        // Will be in 1e6 format
        return __eth_usd_price * price_in_eth / (uint256(10)**eth_usd_pricer_decimals) / 1000;
    }

    // Returns X USDK = 1 USD in 1e6
    function usdk_price() public view returns (uint256) {
        return oracle_price(PriceChoice.USDK);
    }

    // Returns X KROME = 1 USD in 1e6
    function krome_price() public view returns (uint256) {
        return oracle_price(PriceChoice.KROME);
    }

    // 1e6
    function eth_usd_price() public view returns (uint256) {
        return
            eth_usd_pricer.getLatestPrice() * (PRICE_PRECISION) / (
                uint256(10)**eth_usd_pricer_decimals
            );
    }

    // This is needed to avoid costly repeat calls to different getter functions
    // It is cheaper gas-wise to just dump everything and only use some of the info
    function usdk_info()
        public
        view
        returns (
            uint256,        // usdk_price
            uint256,        // krome_price
            uint256,        // total supply
            uint256,        // global collateral ratio
            uint256,        // global collateral value
            uint256         // eth-usd price
        )
    {
        return (
            oracle_price(PriceChoice.USDK), // usdk_price()
            oracle_price(PriceChoice.KROME), // krome_price()
            totalSupply(), // totalSupply()
            global_collateral_ratio(), // global_collateral_ratio()
            globalCollateralValue(), // globalCollateralValue
            eth_usd_pricer.getLatestPrice() * (PRICE_PRECISION) / (
                uint256(10)**eth_usd_pricer_decimals
            ) //eth_usd_price
        );
    }

    function usdk_pools_length() external view returns (uint256) {
        return usdk_pools_array.length;
    }

    // Iterate through all usdk pools and calculate all value of collateral in all pools globally
    function globalCollateralValue() public view returns (uint256) {
        uint256 total_collateral_value_d18 = 0;

        for (uint256 i = 0; i < usdk_pools_array.length; i++) {
            // Exclude null addresses
            if (usdk_pools_array[i] != address(0)) {
                total_collateral_value_d18 = total_collateral_value_d18 + (
                    ICollatBalance(usdk_pools_array[i]).collatDollarBalance()
                );
            }
        }
        return total_collateral_value_d18;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by pools when user redeems
    function pool_burn_from(address b_address, uint256 b_amount)
        public
        onlyPools
    {
        super._burnFrom(b_address, b_amount);
        emit UsdkBurned(b_address, msg.sender, b_amount);
    }

    // This function is what other usdk pools will call to mint new USDK
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit UsdkMinted(msg.sender, m_address, m_amount);
    }

    // Adds collateral addresses supported, such as tether and busd, must be ERC20
    function addPool(address pool_address)
        public
        onlyByOwnerGovernanceOrController
    {
        require(pool_address != address(0), "Zero address detected");

        require(usdk_pools[pool_address] == false, "Address already exists");
        require(ICollatBalance(pool_address).collatDollarBalance() >= 0, "Invalid Pool");   // check interface
        usdk_pools[pool_address] = true;
        usdk_pools_array.push(pool_address);

        emit PoolAdded(pool_address);
    }

    // Remove a pool
    function removePool(address pool_address)
        public
        onlyByOwnerGovernanceOrController
    {
        require(pool_address != address(0), "Zero address detected");
        require(usdk_pools[pool_address] == true, "Address nonexistant");

        // Delete from the mapping
        delete usdk_pools[pool_address];

        // 'Delete' from the array by setting the address to 0x0
        for (uint256 i = 0; i < usdk_pools_array.length; i++) {
            if (usdk_pools_array[i] == pool_address) {
                usdk_pools_array[i] = address(0); // This will leave a null in the array and keep the indices the same
                break;
            }
        }

        emit PoolRemoved(pool_address);
    }

    function setKromeAddress(address _krome_address)
        public
        onlyByOwnerGovernanceOrController
    {
        require(_krome_address != address(0), "Zero address detected");

        krome_address = _krome_address;

        emit KromeAddressSet(_krome_address);
    }

    function setEthUsdOracle(address _eth_usd_oracle_address)
        public
        onlyByOwnerGovernanceOrController
    {
        require(
            _eth_usd_oracle_address != address(0),
            "Zero address detected"
        );

        eth_usd_pricer = IPriceOracle(_eth_usd_oracle_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();

        emit EthUsdOracleSet(_eth_usd_oracle_address);
    }

    function setController(address _controller_address)
        external
        onlyByOwnerGovernanceOrController
    {
        require(_controller_address != address(0), "Zero address detected");

        controller_address = _controller_address;

        emit ControllerSet(_controller_address);
    }

    function setCollateralRatioProvider(address _collateral_ratio_provider_address)
        external
        onlyByOwnerGovernanceOrController
    {
        require(_collateral_ratio_provider_address!= address(0), "Zero address detected");

        collateral_ratio_provider_address = _collateral_ratio_provider_address;

        emit CollateralRatioProviderSet(_collateral_ratio_provider_address);
    }

    // Sets the USDK_ETH Uniswap oracle address
    function setUsdkEthOracle(address _usdk_oracle_addr)
        public
        onlyByOwnerGovernanceOrController
    {
        require(
            (_usdk_oracle_addr != address(0))/* && (_weth_address != address(0)) */,
            "Zero address detected"
        );
        usdk_eth_oracle_address = _usdk_oracle_addr;
        usdkEthOracle = IPairPriceOracle(_usdk_oracle_addr);

        emit UsdkEthOracleSet(_usdk_oracle_addr);
    }

    // Sets the KROME_ETH Uniswap oracle address
    function setKromeEthOracle(address _krome_oracle_addr)
        public
        onlyByOwnerGovernanceOrController
    {
        require(
            (_krome_oracle_addr != address(0))/* && (_weth_address != address(0))*/,
            "Zero address detected"
        );

        krome_eth_oracle_address = _krome_oracle_addr;
        kromeEthOracle = IPairPriceOracle(_krome_oracle_addr);

        emit KromeEthOracleSet(_krome_oracle_addr);
    }

    /* ========== EVENTS ========== */

    // Track USDK burned
    event UsdkBurned(address indexed from, address indexed to, uint256 amount);

    // Track USDK minted
    event UsdkMinted(address indexed from, address indexed to, uint256 amount);

    event PoolAdded(address pool_address);
    event PoolRemoved(address pool_address);
    event KromeAddressSet(address _krome_address);
    event EthUsdOracleSet(address eth_usd_oracle_address);
    event ControllerSet(address controller_address);
    event CollateralRatioProviderSet(address provider_address);
    event UsdkEthOracleSet(address usdk_oracle_addr);
    event KromeEthOracleSet(address krome_oracle_addr);
}
