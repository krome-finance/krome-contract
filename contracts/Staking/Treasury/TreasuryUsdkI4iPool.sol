// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../StakingTreasury_ERC20V5.sol";

interface I4ISwap {
    function token() external view returns (address);
    function coinIndex(address coin) external view returns (uint256);
    function balances(uint256 i) external view returns (uint256);
    function getVirtualPrice() external view returns (uint256);
}

contract TreasuryUsdkI4IPool is StakingTreasury_ERC20V5 {
    I4ISwap public swap;
    IERC20 public lp;
    uint256 public usdk_index;

    function initialize(
        address _locator_address,
        address _staking_boost_controller,
        address _i4i_swap
    ) public initializer {
        swap = I4ISwap(_i4i_swap);
        address lp_token = swap.token();
        StakingTreasury_ERC20V5.__StakingTreasury_init(_locator_address, _staking_boost_controller, lp_token);

        lp = IERC20(lp_token);
        usdk_index = swap.coinIndex(locator.usdk());
    }

    function usdkPerLPToken() public override view returns (uint256) {
        // (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 total_supply = lp.totalSupply();
        return total_supply > 0 ? swap.balances(usdk_index) * 1e18 / total_supply : 0;
    }

    function getVirtualPrice() public override view returns(uint256) {
        return swap.getVirtualPrice();
    }

    /* ============================ MANAGEMENT ========================== */

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