// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../../Common/TimelockOwnedProxy.sol";
import "../../../Libs/TransferHelper.sol";
import "../../../ERC20/IERC20.sol";
import "../../../External/Eklipse/IEklipseSwap.sol";
import "../../../External/Eklipse/IEklipseGauge.sol";
import "../../../External/Eklipse/IEklipseLock.sol";
import "../../../External/Eklipse/IEklipseVote.sol";
import "./IEklipseDelegator.sol";

contract EklipseDelegator is TimelockOwnedProxy, IEklipseDelegator{
    // ============ UPGRADABLE PROXY STORAGE ========================
    // V1 
    IEklipseSwap internal swap;
    IEklipseGauge internal gauge;
    IEklipseLock internal lock;
    IEklipseVote internal vote;
    IERC20 internal lp;
    IERC20 internal ekl;
    uint8 internal usdk_index;

    bool public auto_lock_ekl;
    bool public manage_eklipse;
    uint256 public manage_ekl_threshold;
    uint256 public auto_ekl_lock_period;

    mapping(address => uint256) public valid_pool_order;
    address[] public valid_pools;


    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    modifier onlyByPoolOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address || valid_pool_order[msg.sender] > 0, "Not valid pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    function initialize(
        address _timelock_address,
        address _usdk_address,
        address _eklipse_swap,
        address _eklipse_gauge,
        address _eklipse_lock,
        address _eklipse_vote,
        address _ekl_address
    ) public initializer {
        TimelockOwnedProxy.initializeTimelockOwned(msg.sender, _timelock_address);
        swap = IEklipseSwap(_eklipse_swap);
        gauge = IEklipseGauge(_eklipse_gauge);
        lock = IEklipseLock(_eklipse_lock);
        vote = IEklipseVote(_eklipse_vote);
        lp = IERC20(swap.getLpToken());
        ekl = IERC20(_ekl_address);

        usdk_index = swap.getTokenIndex(_usdk_address);

        auto_lock_ekl = true;
        manage_eklipse = true;
        manage_ekl_threshold = 10e18;
        auto_ekl_lock_period = 1440;

        require(swap.getTokenIndex(_usdk_address) >= 0, "not usdk pool");
    }

    /* ============================ BY POOL ========================== */

    function withdraw(uint256 amount) external override onlyByPoolOwnGov {
        gauge.withdraw(amount);
        TransferHelper.safeTransfer(address(lp), msg.sender, amount);
    }

    function deposit(uint256 amount) external override onlyByPoolOwnGov {
        TransferHelper.safeTransferFrom(address(lp), msg.sender, address(this), amount);
        TransferHelper.safeApprove(address(lp), address(gauge), amount);
        gauge.deposit(amount);
    }

    function manage() external override onlyByPoolOwnGov {
        if (manage_eklipse) {
            _manageEklipse();
        }
    }

    function manageEklipse() external onlyByOwnGov {
        _manageEklipse();
    }

    function _manageEklipse() internal {
        if (gauge.pendingEKL(address(this)) > manage_ekl_threshold) {
            gauge.withdraw(0);
        }
        uint256 feeReward = lock.calculateFeeReward(address(this));
        if (feeReward > manage_ekl_threshold) {
            lock.withdrawFeeReward();
        }
        if (auto_lock_ekl) {
            uint256 eklBalance = ekl.balanceOf(address(this));
            if (eklBalance > manage_ekl_threshold) {
                lock.addLock(eklBalance, auto_ekl_lock_period);
            }
        }
        uint256 vekl = vote.getLeftVotingPower(address(this));
        if (vekl > manage_ekl_threshold) {
            vote.voteForGauge(address(gauge), vekl);
        }
    }

    /* ============================ VIEWS ========================== */

    function getPools() external view returns (address[] memory) {
        return valid_pools;
    }

    function isValidPool(address pool) external view returns (bool) {
        return valid_pool_order[pool] > 0;
    }

    function getEklipseRewards() external view returns (
        uint256 pending_ekl,
        uint256 pending_post_ekl,
        uint256 fee_reward
    ) {
        pending_ekl = gauge.pendingEKL(address(this));
        pending_post_ekl = gauge.pendingPostEKL(address(this));
        fee_reward = lock.calculateFeeReward(address(this));
    }

    function getEklipseState() external view returns (
        uint256 lp_total_supply,
        uint256 lp_usdk_balance,
        uint256 lp_deposited,
        uint256 reward_dept,
        uint256 post_ekl_reward_dept,
        uint256 applied_boost,
        uint256 calculated_boost,
        uint256 ekl_locked,
        uint256 ekl_lock_started,
        uint256 ekl_lock_period,
        uint256 vekl
    ) {
        lp_total_supply = lp.totalSupply();
        lp_usdk_balance = swap.getTokenBalance(usdk_index);
        (lp_deposited, reward_dept, post_ekl_reward_dept) = gauge.userInfo(address(this));
        applied_boost = gauge.userAppliedBoost(address(this));
        calculated_boost = gauge.calculateBoost(address(this));
        (ekl_locked, ekl_lock_started, ekl_lock_period,) = lock.userInfo(address(this));
        vekl = lock.getUserVekl(address(this));
    }

    /* ============================ MANAGEMENT ========================== */

    function addPool(address pool) external onlyByOwnGov {
        require(valid_pool_order[pool] == 0, "duplicated pool");
        valid_pools.push(pool);
        valid_pool_order[pool] = valid_pools.length;
    }

    function removePool(address pool) external onlyByOwnGov {
        require(valid_pool_order[pool] > 0, "duplicated pool");
        uint256 idx = valid_pool_order[pool] - 1;
        address last = valid_pools[idx - 1];
        if (last != pool) {
            valid_pools[idx] = last;
            valid_pool_order[last] = idx + 1;
        }
        valid_pool_order[pool] = 0;
        valid_pools.pop();
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        TransferHelper.safeTransfer(_token, payable(msg.sender), amount);
        emit RecoverERC20(_token, payable(msg.sender), amount);
    }

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

    function collectEkl() external onlyByOwnGov {
        gauge.withdraw(0);
    }

    function collectEklFeeReward() external onlyByOwnGov{
        lock.withdrawFeeReward();
    }

    function lockEkl(uint256 amount, uint256 period) external onlyByOwnGov {
        lock.addLock(amount, period);
    }

    function withdrawEkl() external onlyByOwnGov {
        lock.withdrawEkl();
    }

    function setAutoEkLockPeriod(uint256 v) external onlyByOwnGov {
        auto_ekl_lock_period = v;
    }

    function setAutoLockEkl(bool v) external onlyByOwnGov {
        auto_lock_ekl = v;
    }

    function setManageEklipse(bool v) external onlyByOwnGov {
        manage_eklipse = v;
    }

    function setManageEKLThreashold(uint256 v) external onlyByOwnGov {
        manage_ekl_threshold = v;
    }

    /* ============================ EVENTS ========================== */

    event RecoverERC20(address token, address to, uint256 amount);
}