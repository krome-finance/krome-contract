// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

interface IEklipseRouter {
    function swap(
        address _fromAddress,
        address _toAddress,
        uint256 _inAmount,
        uint256 _outAmount,
        uint256 deadline
    ) external returns (uint256);
    function addLiquidity(
        address _swap,
        uint256[] calldata _amount,
        uint256 _minMintAmount,
        uint256 _deadline
    ) external returns (uint256);
    function removeLiquidity(
        address _swap,
        uint256 _amount,
        uint256[] calldata _minAmounts,
        uint256 _deadline
    ) external returns (uint256);
    function removeLiquidityOneToken(
        address _swap,
        uint256 _amount,
        uint8 tokenIndex,
        uint256 _minAmount,
        uint256 _deadline
    ) external returns (uint256);
    function reviewSwap(
        address _fromAddress,
        address _toAddress,
        uint256 _inAmount,
        uint256 _deadline
    ) external view returns (uint256);
    function reviewAddLiquidity(
        address _swap,
        uint256[] calldata _amount
    ) external view returns (uint256);
    function reviewRemoveLiquidity(
        address _swap,
        uint256 _amount,
        address _account
    ) external view returns (uint256[] memory);
    function reviewRemoveLiquidityOneToken(
        address _swap,
        uint256 _amount,
        uint8 tokenIndex,
        address _account
    ) external returns (uint256);
}
 