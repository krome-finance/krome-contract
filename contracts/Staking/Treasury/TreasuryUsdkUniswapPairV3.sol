// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../External/Claimswap/IUniswapV2Pair.sol";
import "../StakingTreasury_ERC20V3.sol";

interface IUsdkPriceProvider {
    function usdk_price() external view returns (uint256);
}


contract TreasuryUsdkUniswapPairV3 is StakingTreasury_ERC20V3 {
    IUniswapV2Pair internal immutable pair;
    address internal immutable usdk_address;

    constructor(
        address _timelock_address,
        address _staking_boost_controller,
        address _staking_token,
        address _usdk_address
    ) StakingTreasury_ERC20V3(_timelock_address, _staking_boost_controller, _staking_token) {
        pair = IUniswapV2Pair(_staking_token);
        usdk_address = _usdk_address;

        require(pair.token0() == _usdk_address || pair.token1() == _usdk_address, "not usdk pair");
    }

    function usdkPerLPToken() public override view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        return uint256((pair.token0() == usdk_address) ? reserve0 : reserve1) * 1e18 / pair.totalSupply();
    }

    function getVirtualPrice() public override view returns (uint256) {
        return 2 * usdkPerLPToken() * IUsdkPriceProvider(usdk_address).usdk_price() / 1e6;
    }
}