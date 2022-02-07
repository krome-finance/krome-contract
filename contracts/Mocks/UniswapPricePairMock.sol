// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../ERC20/ERC20CustomMock.sol";
import "../Math/Math.sol";

contract UniswapPricePairMock is ERC20CustomMock{
  uint256 internal constant PRECISION = 10**9;
  uint256 internal constant Q112 = 2 ** 112;

  address public immutable token0;
  address public immutable token1;
  uint112 public reserve0;
  uint112 public reserve1;
  uint256 public price0CumulativeLast;
  uint256 public price1CumulativeLast;

  uint256 public constant MINIMUM_LIQUIDITY = 10**3;

  uint32 public last_time;

  constructor(
    address _tokenA,
    address _tokenB,
    uint112 _reserveA,
    uint112 _reserveB,
    string memory _name,
    string memory _symbol
  ) ERC20CustomMock(_name, _symbol, 18, msg.sender, Math.sqrt(uint256(_reserveA) * uint256(_reserveB)) - MINIMUM_LIQUIDITY)  {
    (token0, token1, reserve0, reserve1) = _tokenA < _tokenB ? (_tokenA, _tokenB, _reserveA, _reserveB) : (_tokenB, _tokenA, _reserveB, _reserveA);
    _update();
  }

  // in E9
  function setPrice(address _token, uint256 _price) public {
    require(_token == token0 || _token == token1, "Invalid token");
    uint256 k = uint256(reserve0) * uint256(reserve1);
    uint112 rA = safe_uint112(Math.sqrt(k * PRECISION / _price));
    uint112 rB = safe_uint112(k / uint256(rA));

    (reserve0, reserve1) = _token == token0 ? (rA, rB) : (rB, rA);
    _update();
  }

  function getReserves() external view returns (uint112, uint112, uint32) {
    return (reserve0, reserve1, uint32(block.timestamp));
  }

  function _update() internal {
    uint32 t = uint32(block.timestamp % 2**32);
    price0CumulativeLast += uint256(uint224(reserve1) * uint224(Q112) / reserve0) * (t - last_time);
    price1CumulativeLast += uint256(uint224(reserve0) * uint224(Q112) / reserve1) * (t - last_time); 
    last_time = t;
  }

  function safe_uint112(uint256 v) internal pure returns (uint112) {
    require(v < 2**112, "uint112 overflow");
    return uint112(v);
  }
}