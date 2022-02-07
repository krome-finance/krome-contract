// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Context.sol";
import "../Common/Owned.sol";
import "../Common/ReentrancyGuard.sol";
import "../Libs/TransferHelper.sol";

contract PresaleByKlaytn is Context, Owned, ReentrancyGuard {
    uint256 public tokenAmount;
    uint256 public purchaseLimit;
    uint256 public totalPurchased;
    mapping(address => uint256) user_purchases;

    uint256 public start;
    uint256 public finish;

    constructor(
        uint256 _tokenAmount,
        uint256 _purchaseLimit,
        uint256 _start,
        uint256 _duration
    ) Owned(_msgSender()) {
        tokenAmount = _tokenAmount;
        purchaseLimit = _purchaseLimit;
        require((_purchaseLimit * 1e18 / _tokenAmount) * _tokenAmount / 1e18 == _purchaseLimit, "unit price greater than 1e18");
        require(_start > block.timestamp, "Presale: start time is before current time");
        require(_start + _duration > block.timestamp, "Presale: finish time is before current time");
        start = _start;
        finish = _start + _duration;
    }

    // buy with klaytn
    // call this with klaytn value
    function buy(bool _fit) external payable nonReentrant {
        require(start < block.timestamp, "Presale: not started yet");
        require(finish >= block.timestamp, "Presale: finished");
        require(totalPurchased < purchaseLimit, "Presale: Sold out");
        require(msg.value > 0, "Presale: No value received");
        require(_fit || (msg.value + totalPurchased) <= purchaseLimit, "Presale: Insufficient stock");
        require(tokenAmount * msg.value / purchaseLimit * purchaseLimit / msg.value == tokenAmount, "No flooring");
        uint256 _available = purchaseLimit - totalPurchased;
        uint256 _amount = _available >= msg.value ? msg.value : _available;
        uint256 _change = msg.value - _amount;

        user_purchases[_msgSender()] += _amount;
        totalPurchased += _amount;

        if (_change > 0) {
            TransferHelper.safeTransferETH(_msgSender(), _change);
        }

        emit Buy(_msgSender(), _amount);
    }

    function getPurchaseLimit() external view returns(uint256) {
        return purchaseLimit;
    }

    function getPurchaseAmount(address account) external view returns(uint256) {
        return user_purchases[account];
    }

    function withdraw( uint256 _amount) external onlyOwner {
        TransferHelper.safeTransferETH(payable(msg.sender), _amount);

        emit Withdraw(payable(msg.sender), _amount);
    }

    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        TransferHelper.safeTransfer(_token, msg.sender, _amount);
    }

    event Buy(address _buyer, uint256 amount);
    event Withdraw(address _to, uint256 amount);
}