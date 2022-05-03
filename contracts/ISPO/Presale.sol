// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../Common/Context.sol";
import "../Common/Owned.sol";
import "../Common/OwnedUpgradeable.sol";
import "../Common/ReentrancyGuard.sol";
import "../ERC20/IERC20.sol";
import "../Libs/TransferHelper.sol";
import "../Math/Math.sol";

contract Presale is OwnedUpgradeable, ReentrancyGuardUpgradeable {
    address public paymentToken;
    uint256 public purchaseLimit;
    uint256 public totalPurchased;
    uint256 public perUserPurchaseCap;
    mapping(address => uint256) public userPurchases;

    uint256 public saleStart;
    uint256 public saleFinish;

    address public rewardToken;
    uint256 public totalRewardAmount;
    uint256 public totalRewardClaimed;
    mapping(address => uint256) public userRewardClaimed;

    uint256 public rewardVestingStart;
    uint256 public rewardVestingFinish;

    bool public refunding;
    mapping(address => uint256) public userRefunded;

    /* ======================= CONSTRUCTOR ==================== */

    function initialize(
        address _payment_token,
        uint256 _purchaseLimit,
        uint256 _sale_start,
        uint256 _sale_duration,
        uint256 _reward_vesting_start,
        uint256 _reward_vesting_duration
    ) public initializer {
        OwnedUpgradeable.__Owned_init(payable(msg.sender));
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

        paymentToken = _payment_token;
        purchaseLimit = _purchaseLimit;
        require(_sale_start > block.timestamp, "sale start time is before current time");
        require(_sale_duration > 600, "sale duration time is less than 10 min");
        saleStart = _sale_start;
        saleFinish = _sale_start + _sale_duration;

        require(_reward_vesting_start >= _sale_start + _sale_duration, "vesting start time is same or before sale finish");
        rewardVestingStart = _reward_vesting_start;
        rewardVestingFinish = _reward_vesting_start + _reward_vesting_duration;
    }

    /* ======================= VIEWS ==================== */

    function info() external view returns(
        address payment_token,
        uint256 purchase_limit,
        uint256 total_purchased,
        uint256 per_user_purchase_cap,
        uint256 sale_start,
        uint256 sale_finish,
        address reward_token,
        uint256 total_reward_amount,
        uint256 total_reward_claimed,
        uint256 vesting_start,
        uint256 vesting_finish,
        bool is_refunding
    ) {
        payment_token = paymentToken;
        purchase_limit = purchaseLimit;
        total_purchased = totalPurchased;
        per_user_purchase_cap = perUserPurchaseCap;
        sale_start = saleStart;
        sale_finish = saleFinish;
        reward_token = rewardToken;
        total_reward_amount = totalRewardAmount;
        total_reward_claimed = totalRewardClaimed;
        vesting_start = rewardVestingStart;
        vesting_finish = rewardVestingFinish;
        is_refunding = refunding;
    }

    function userInfo(address account) external view returns(
        uint256 purchased,
        uint256 reward_amount,
        uint256 reward_released,
        uint256 reward_claimed,
        uint256 refunded
    ) {
        purchased = userPurchases[account];
        reward_amount = rewardAmount(account);
        reward_released = releasedAmount(account);
        reward_claimed = userRewardClaimed[account];
        refunded = userRefunded[account];
    }

    function purchaseAmount(address account) external view returns(uint256) {
        return userPurchases[account];
    }

    function rewardAmount(address account) public view returns(uint256) {
        return totalRewardAmount * userPurchases[account] / purchaseLimit;
    }

    function claimedAmount(address account) external view returns(uint256) {
        return userRewardClaimed[account];
    }

    function totalRewardReleased() public view returns(uint256 released) {
        if (rewardVestingFinish <= block.timestamp) {
            released = totalRewardAmount;
        } else if (rewardVestingStart >= block.timestamp || rewardVestingFinish == rewardVestingStart) {
            released = 0;
        } else {
            released = totalRewardAmount * (block.timestamp - rewardVestingStart) / (rewardVestingFinish - rewardVestingStart);
        }
    }

    function releasedAmount(address account) public view returns(uint256 released) {
        uint256 reward_amount = rewardAmount(account);
        if (rewardVestingFinish <= block.timestamp) {
            released = reward_amount;
        } else if (rewardVestingStart >= block.timestamp || rewardVestingFinish == rewardVestingStart) {
            released = 0;
        } else {
            released = reward_amount * (block.timestamp - rewardVestingStart) / (rewardVestingFinish - rewardVestingStart);
        }
    }

    function releaseAmount(address account) public view returns(uint256 release_amount) {
        uint256 released_amount = releasedAmount(account);
        release_amount = userRewardClaimed[account] >= released_amount ? 0 : released_amount - userRewardClaimed[account];
    }

    /* ======================= VIEWS ==================== */

    // buy with paymentToken
    // approve required
    function buy(uint256 amount) external nonReentrant {
        require(!refunding, "refunding");
        require(saleStart < block.timestamp, "not started yet");
        require(saleFinish >= block.timestamp, "finished");
        require(totalPurchased < purchaseLimit, "Sold out");
        require(amount > 0, "zero amount");
        require(perUserPurchaseCap == 0 || userPurchases[msg.sender] < perUserPurchaseCap, "user purchase cap reached");
        uint256 _available = purchaseLimit - totalPurchased;
        if (perUserPurchaseCap > 0) {
            _available = userPurchases[msg.sender] >= perUserPurchaseCap ? 0 : Math.min(perUserPurchaseCap - userPurchases[msg.sender], _available);
        }
        uint256 _amount = _available >= amount ? amount : _available;

        TransferHelper.safeTransferFrom(paymentToken, msg.sender, address(this), _amount);

        userPurchases[msg.sender] += _amount;
        totalPurchased += _amount;

        emit Buy(msg.sender, _amount);
    }

    function refund() external nonReentrant {
        require(refunding, "not refunding");
        require(userPurchases[msg.sender] > 0 && (userPurchases[msg.sender] > userRefunded[msg.sender]), "nothing to refund");

        uint256 _refund_amount = userPurchases[msg.sender] - userRefunded[msg.sender];
        userRefunded[msg.sender] += _refund_amount;

        TransferHelper.safeTransferFrom(paymentToken, address(this), msg.sender, _refund_amount);

        emit Refund(msg.sender, _refund_amount);
    }

    function _release(address payable account) internal nonReentrant {
        require(!refunding, "refunding");
        require(rewardToken != address(0), "reward token not set");
        require(totalRewardAmount > 0, "reward token not set");
        require(rewardVestingStart <= block.timestamp, "not started yet");
        require(IERC20(rewardToken).balanceOf(address(this)) + totalRewardClaimed >= totalRewardAmount, "Insufficient balance");
        require(userPurchases[account] > 0, "Nothing to release");

        uint256 release_amount = releaseAmount(account);
        require(release_amount > 0, "Nothing to release");

        userRewardClaimed[account] += release_amount;
        totalRewardClaimed += release_amount;

        TransferHelper.safeTransfer(rewardToken, account, release_amount);

        emit Release(account, release_amount);
    }

    function release() external {
        _release(payable(msg.sender));
    }

    /* ======================== OWNER ======================== */

    function withdraw(uint256 _amount) external onlyOwner {
        TransferHelper.safeTransfer(paymentToken, msg.sender, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    function releaseFor(address payable account) external onlyOwner {
        _release(account);
    }

    /* ======================== CONFIGURATION ======================== */

    function setPerUserPurchaseCap(uint256 _amount) external onlyOwner {
        perUserPurchaseCap = _amount;
        
        emit SetPerUserPurchaseCap(_amount);
    }

    function setSaleDuration(uint256 _start, uint256 _duration) external onlyOwner {
        require(_duration > 600, "sales duration time is less than 10 min");
        require(_start + _duration <= rewardVestingStart, "sales finish time is same or after rewawrd start");
        saleStart = _start;
        saleFinish = _start + _duration;
        
        emit SetRewardDuration(_start, _duration);
    }

    function setReward(address _reward_token, uint256 _amount) external onlyOwner {
        rewardToken = _reward_token;
        totalRewardAmount = _amount;
        
        emit SetReward(_reward_token, _amount);
    }

    function setRewardDuration(uint256 _start, uint256 _duration) external onlyOwner {
        require(_start >= saleFinish, "vesting start time is same or before sale finish");
        rewardVestingStart = _start;
        rewardVestingFinish = _start + _duration;
        
        emit SetRewardDuration(_start, _duration);
    }

    function setRefunding(bool _v) external onlyOwner {
        refunding = _v;
        emit SetRefunding(_v);
    }

    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        TransferHelper.safeTransfer(_token, msg.sender, _amount);
    }

    event SetPerUserPurchaseCap(uint256 _amount);
    event SetReward(address _token, uint256 _amount);
    event SetRewardDuration(uint256 _start, uint256 _duration);
    event SetRefunding(bool v);
    event Buy(address _buyer, uint256 amount);
    event Refund(address _buyer, uint256 amount);
    event Release(address _buyer, uint256 amount);
    event Withdraw(address _to, uint256 amount);
}