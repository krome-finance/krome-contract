// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Context.sol";
import "../Common/Owned.sol";
import "../Common/ReentrancyGuard.sol";
import "../ERC20/IERC20.sol";
import "../Libs/TransferHelper.sol";
import "../Math/Math.sol";

contract Presale is Context, Owned, ReentrancyGuard {
    address public paymentToken;
    uint256 public purchaseLimit;
    uint256 public totalPurchased;
    uint256 public perUserPurchaseCap;
    mapping(address => uint256) userPurchases;

    uint256 public salesStart;
    uint256 public salesFinish;

    address public rewardToken;
    uint256 public totalRewardAmount;
    uint256 public totalRewardClaimed;
    mapping(address => uint256) userRewardClaimed;

    uint256 public rewardVestingStart;
    uint256 public rewardVestingFinish;

    /* ======================= CONSTRUCTOR ==================== */

    constructor(
        address _payment_token,
        uint256 _purchaseLimit,
        uint256 _sales_start,
        uint256 _sales_duration,
        uint256 _reward_vesting_start,
        uint256 _reward_vesting_duration
    ) Owned(_msgSender()) {
        paymentToken = _payment_token;
        purchaseLimit = _purchaseLimit;
        require(_sales_start > block.timestamp, "sales start time is before current time");
        require(_sales_duration > 600, "sales duration time is less than 10 min");
        salesStart = _sales_start;
        salesFinish = _sales_start + _sales_duration;

        require(_reward_vesting_start > _sales_start + _sales_duration, "vesting start time is same or before sales finish");
        rewardVestingStart = _reward_vesting_start;
        rewardVestingFinish = _reward_vesting_start + _reward_vesting_duration;
    }

    /* ======================= VIEWS ==================== */

    function getPurchaseAmount(address account) external view returns(uint256) {
        return userPurchases[account];
    }

    function getRewardAmount(address account) public view returns(uint256) {
        return totalRewardAmount * userPurchases[account] / totalPurchased;
    }

    function getClaimedAmount(address account) external view returns(uint256) {
        return userRewardClaimed[account];
    }

    function getReleasedAmount(address account) public view returns(uint256 released) {
        uint256 reward_amount = getRewardAmount(account);
        if (rewardVestingFinish <= block.timestamp) {
            released = reward_amount;
        } else if (rewardVestingFinish == rewardVestingStart) {
            released = 0;
        } else {
            released = reward_amount * (block.timestamp - rewardVestingStart) / (rewardVestingFinish - rewardVestingStart);
        }
    }

    function getReleaseAmount(address account) public view returns(uint256 release_amount) {
        uint256 released_amount = getReleasedAmount(account);
        release_amount = userRewardClaimed[account] >= released_amount ? 0 : released_amount - userRewardClaimed[account];
    }

    /* ======================= VIEWS ==================== */

    // buy with paymentToken
    // approve required
    function buy(uint256 amount) external nonReentrant {
        require(salesStart < block.timestamp, "not started yet");
        require(salesFinish >= block.timestamp, "finished");
        require(totalPurchased < purchaseLimit, "Sold out");
        require(amount > 0, "zero amount");
        require(perUserPurchaseCap == 0 || userPurchases[msg.sender] < perUserPurchaseCap, "user purchase cap reached");
        uint256 _available = purchaseLimit - totalPurchased;
        if (perUserPurchaseCap > 0) {
            _available = userPurchases[msg.sender] >= perUserPurchaseCap ? 0 : Math.min(perUserPurchaseCap - userPurchases[msg.sender], _available);
        }
        uint256 _amount = _available >= amount ? amount : _available;

        TransferHelper.safeTransferFrom(paymentToken, _msgSender(), address(this), _amount);

        userPurchases[_msgSender()] += _amount;
        totalPurchased += _amount;

        emit Buy(_msgSender(), _amount);
    }

    function release() external nonReentrant {
        require(rewardToken != address(0), "reward token not set");
        require(rewardVestingStart <= block.timestamp, "not started yet");
        require(IERC20(rewardToken).balanceOf(address(this)) >= totalRewardAmount - totalRewardClaimed, "Insufficient balance");
        require(userPurchases[msg.sender] > 0, "Nothing to release");

       uint256 release_amount = getReleaseAmount(msg.sender);

        userRewardClaimed[msg.sender] += release_amount;

        TransferHelper.safeTransfer(rewardToken, _msgSender(), release_amount);

        emit Release(msg.sender, release_amount);
    }

    function withdraw(uint256 _amount) external onlyOwner {
        TransferHelper.safeTransfer(paymentToken, _msgSender(), _amount);

        emit Withdraw(_msgSender(), _amount);
    }

    /* ======================== OWNER ======================== */

    function setPerUserPurchaseCap(uint256 _amount) external onlyOwner {
        perUserPurchaseCap = _amount;
        
        emit SetPerUserPurchaseCap(_amount);
    }

    function setSalesDuration(uint256 _start, uint256 _duration) external onlyOwner {
        require(_duration > 600, "sales duration time is less than 10 min");
        require(_start + _duration < rewardVestingStart, "sales finish time is same or after rewawrd start");
        salesStart = _start;
        salesFinish = _start + _duration;
        
        emit SetRewardDuration(_start, _duration);
    }

    function setRewardVesting(address _reward_token, uint256 _amount) external onlyOwner {
        rewardToken = _reward_token;
        totalRewardAmount = _amount;
        
        emit SetReward(_reward_token, _amount);
    }

    function setRewardDuration(uint256 _start, uint256 _duration) external onlyOwner {
        require(_start > salesFinish, "vesting start time is same or before sales finish");
        rewardVestingStart = _start;
        rewardVestingFinish = _start + _duration;
        
        emit SetRewardDuration(_start, _duration);
    }

    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        TransferHelper.safeTransfer(_token, msg.sender, _amount);
    }

    event SetPerUserPurchaseCap(uint256 _amount);
    event SetReward(address _token, uint256 _amount);
    event SetRewardDuration(uint256 _start, uint256 _duration);
    event Buy(address _buyer, uint256 amount);
    event Release(address _buyer, uint256 amount);
    event Withdraw(address _to, uint256 amount);
}