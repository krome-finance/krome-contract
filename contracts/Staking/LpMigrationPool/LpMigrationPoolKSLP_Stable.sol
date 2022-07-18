// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../LpMigrationTreasury_ERC20.sol";

interface KlaySwap is IERC20 {
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function getCurrentPool() external view returns (uint256, uint256);
}

contract LpMigrationPoolKSLP_Stable is LpMigrationTreasury_ERC20 {
    KlaySwap public swap;
    address public stable_address;
    uint256 public stable_missing_precistion;
    bool public stable_is_tokenA;
    bool public stable_is_usdk;

    function initialize(
        address _locator_address,
        address _staking_boost_controller,
        address _usdk_or_stable_address,
        address _klayswap,
        uint256 _closed_at,
        uint256 _lockend
    ) public initializer {
        LpMigrationTreasury_ERC20.__LpMigrationTreasury_init(_locator_address, _staking_boost_controller, _klayswap, _closed_at, _lockend);

        swap = KlaySwap(_klayswap);
        address usdk_address = locator.usdk();
        stable_address = _usdk_or_stable_address;
        uint8 stable_decimals = IERC20Decimals(_usdk_or_stable_address).decimals();
        stable_missing_precistion = 10 ** (18 - stable_decimals);
        stable_is_usdk = _usdk_or_stable_address == usdk_address;

        stable_is_tokenA = swap.tokenA() == stable_address;
    }

    function stablePerLpToken() public view returns (uint256) {
        (uint256 reserveA, uint256 reserveB) = swap.getCurrentPool();
        return uint256((stable_is_tokenA) ? reserveA : reserveB) * 1e18 / swap.totalSupply();
    }

    function usdkPerLPToken() public override view returns (uint256) {
        if (stable_is_usdk) {
            return stablePerLpToken();
        } else {
            return 0;
        }
    }

    // return in 1e18
    function getVirtualPrice() public override view returns(uint256) {
        return 2 * stablePerLpToken() * stable_missing_precistion;
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