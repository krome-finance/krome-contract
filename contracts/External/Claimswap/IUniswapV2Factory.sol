// pragma solidity 0.5.6;
pragma solidity ^0.8.8;

interface IUniswapV2Factory {
    event PairCreated(
        address indexed token0,
        address indexed token1,
        address pair,
        uint256
    );

    function migrator() external view returns (address);

    function feeTo() external view returns (address);

    function feeToSetter() external view returns (address);

    function feeDistributor() external view returns (address);

    function klayBuybackFund() external view returns (address);

    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);

    function allPairs(uint256) external view returns (address pair);

    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB)
        external
        returns (address pair);

    function createPair(address tokenA, address tokenB, uint8 decimals)
        external
        returns (address pair);

    function setFeeTo(address) external;

    function setFeeToSetter(address) external;

    function setFeeDistributor(address) external;

    function setKlayBuybackFund(address) external;

    function setMigrator(address) external;
}