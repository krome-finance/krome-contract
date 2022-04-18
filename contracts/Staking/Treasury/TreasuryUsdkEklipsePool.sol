// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../External/Eklipse/IEklipseSwap.sol";
import "../../External/Eklipse/IEklipseGauge.sol";
import "../../External/Eklipse/IEklipseLock.sol";
import "../../External/Eklipse/IEklipseVote.sol";
import "../StakingTreasury_ERC20V3.sol";
import "./Delegator/IEklipseDelegator.sol";

contract TreasuryUsdkEklipsePool is StakingTreasury_ERC20V3 {
    IEklipseSwap internal immutable swap;
    IERC20 internal immutable lp;
    uint8 internal immutable usdk_index;

    IEklipseDelegator eklipse_delegator;

    constructor(
        address _timelock_address,
        address _staking_boost_controller,
        address _usdk_address,
        address _eklipse_swap,
        address _eklipse_delegator_address
    ) StakingTreasury_ERC20V3(_timelock_address, _staking_boost_controller, IEklipseSwap(_eklipse_swap).getLpToken()) {
        swap = IEklipseSwap(_eklipse_swap);
        lp = IERC20(swap.getLpToken());
        usdk_index = swap.getTokenIndex(_usdk_address);

        eklipse_delegator = IEklipseDelegator(_eklipse_delegator_address);

        require(swap.getTokenIndex(_usdk_address) >= 0, "not usdk pool");
    }

    function usdkPerLPToken() public override view returns (uint256) {
        // (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
        uint256 total_supply = lp.totalSupply();
        return total_supply > 0 ? swap.getTokenBalance(usdk_index) * 1e18 / lp.totalSupply() : 0;
    }

    function getVirtualPrice() public override view returns(uint256) {
        return swap.getVirtualPrice();
    }

    function _onBeforeUnstake(address, uint256 amount) internal override {
        if (address(eklipse_delegator) != address(0)) {
            eklipse_delegator.withdraw(amount);
        }
    }

    function _onAfterStake(address, uint256 amount) internal override {
        if (address(eklipse_delegator) != address(0)) {
            TransferHelper.safeApprove(address(lp), address(eklipse_delegator), amount);
            eklipse_delegator.deposit(amount);
        }
    }

    function _onSync() internal override {
        if (address(eklipse_delegator) != address(0)) {
            eklipse_delegator.manage();
        }
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

    function setEklipseDelegator(address _delegator) external onlyByOwnGov {
        eklipse_delegator = IEklipseDelegator(_delegator);

        emit SetEklipseDelegator(_delegator);
    }

    event SetEklipseDelegator(address);
}