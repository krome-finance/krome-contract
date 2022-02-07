// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../Common/Context.sol";
import "../Common/TimelockOwned.sol";
import "../ERC20/IERC20.sol";
import "../Libs/TransferHelper.sol";
import "../Math/Math.sol";

interface IFarm {
    function collectRewardFor(address) external returns (uint256[] memory);
    function withdrawLockedFor(address, bytes32) external;
}

interface IVeKrome {
    function manage_deposit_for(address _addr, uint256 _value, uint256 _unlock_time) external;
}

contract KromeRewardForStakingDelegator is Context, TimelockOwned {
    address public immutable krome_address;
    address public immutable vekrome_address;

    struct Reward {
        uint256 i;
        bool withdrawn;
        uint256 krome_amount;
        uint256 collectTime;
    }

    struct QueueItem {
        address account;
        address farm;
        uint256 collectTime;
    }

    mapping(address => bool) public farms;

    // account => (farm => reward)
    mapping(address => mapping(address => Reward[])) public collected;
    mapping(address => mapping(address => uint256)) public next_withdraw_index;
    QueueItem[] internal global_queue;
    uint256 internal next_global_queue_index;

    uint256 public total_reward_locked;

    address public custodian_address;
    uint256 public withdraw_delay = 21 * 24 * 3600; // 21 DAYS
    uint256 public min_vekrome_lock_time = 30 * 24 * 3600; // 30 DAYS
    uint256 public max_queue_handling = 30;

    /* =============== EVENT ================ */
    event RewardCollectedForWithdraw(address account, address farm, uint256 amount);
    event RewardCollectedForVeKrome(address account, address farm, uint256 amount, uint256 unlock_time);
    event RewardWithdrawn(address account, address farm, uint256 amount);

    event WithdrawDelaySet(uint256);
    event MinVeKromeLockTimeSet(uint256);
    event MaxQueueHandlingSet(uint256);
    event FarmToggled(address,bool);
    event CustodianSet(address);
    event RecoverERC20(address token, address to, uint256 amount);

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    modifier onlyByOwnGovCustodian() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == custodian_address, "Not owner or timelock or custodian");
        _;
    }

    modifier onlyValidFarm(address farm) {
        require(farms[farm], "Unknown farm");
        _;
    }


    constructor(
        address _krome_address,
        address _vekrome_address,
        address _timelock_address,
        address _custodian_address
    ) TimelockOwned(msg.sender, _timelock_address) {
        krome_address = _krome_address;
        vekrome_address = _vekrome_address;
        custodian_address = _custodian_address;
    }

    /* ================ VIEWS =============== */

    function collectedRewards(address account, address farm) external view returns (Reward[] memory) {
        return collected[account][farm];
    }

    function collectedRewardsLength(address account, address farm) external view returns (uint256) {
        return collected[account][farm].length;
    }

    function collectedRewardsPage(address account, address farm, uint256 start, uint256 length) external view returns (Reward[] memory) {
        Reward[] memory rewards = collected[account][farm];
        Reward[] memory result = new Reward[](Math.min(length, start <= rewards.length ? rewards.length - start : 0));
        for (uint256 i = start; i < start + result.length; i++) {
            result[i - start] = rewards[i];
        }
        return result;
    }

    /* ================ MUTATIVE FUNCTIONS =============== */

    function _collectReward(address farm) internal returns (uint256) {
        _handle_queued();

        uint256 balance0 = IERC20(krome_address).balanceOf(address(this));
        uint256[] memory rewards = IFarm(farm).collectRewardFor(msg.sender);
        uint256 balance = IERC20(krome_address).balanceOf(address(this));

        require(rewards.length == 1, "reward length mismatch");
        require(balance - balance0 == rewards[0], "reward balance");

        return rewards[0];
    }

    function _withdrawLocked(address farm, bytes32 kek_id) internal {
        _handle_queued();

        IFarm(farm).withdrawLockedFor(msg.sender, kek_id);
    }

    function _lockReward(address account, address farm, uint256 amount) internal returns (uint256) {
        uint256 collectTime = block.timestamp;

        Reward[] storage rewards = collected[account][farm];
        uint256 i = rewards.length;
        rewards.push(Reward(
            i,
            false,
            amount,
            collectTime
        ));
        global_queue.push(QueueItem(
            account,
            farm,
            collectTime
        ));
        total_reward_locked += amount;
        
        emit RewardCollectedForWithdraw(account, farm, amount);

        return i;
    }

    function collectRewardForWithdraw(address farm) external onlyValidFarm(farm) returns (uint256) {
        uint256 amount = _collectReward(farm);

        if (amount > 0) {
            return _lockReward(msg.sender, farm, amount);
        }
        return 0;
    }

    function collectRewardForVeKrome(address farm, uint256 vekrome_lock_time) onlyValidFarm(farm) external {
        require(vekrome_lock_time >= min_vekrome_lock_time, "unlock_time is less than minimum");
        uint256 amount = _collectReward(farm);

        if (amount > 0) {
            TransferHelper.safeApprove(krome_address, vekrome_address, amount);
            IVeKrome(vekrome_address).manage_deposit_for(msg.sender, amount, block.timestamp + vekrome_lock_time);
    
            emit RewardCollectedForVeKrome(msg.sender, farm, amount, vekrome_lock_time);
        }
    }

    function withdrawLockedWithRewardLock(address farm, bytes32 kek_id) external onlyValidFarm(farm) returns (uint256) {
        _withdrawLocked(farm, kek_id);
        uint256 amount = _collectReward(farm);
        if (amount > 0) {
            return _lockReward(msg.sender, farm, amount);
        }
        return 0;
    }

    function withdrawLockedWithVeKromeLock(address farm, bytes32 kek_id, uint256 vekrome_lock_time) external onlyValidFarm(farm) {
        require(vekrome_lock_time >= min_vekrome_lock_time, "unlock_time is less than minimum");
        _withdrawLocked(farm, kek_id);

        uint256 amount = _collectReward(farm);
        if (amount > 0) {
            TransferHelper.safeApprove(krome_address, vekrome_address, amount);
            IVeKrome(vekrome_address).manage_deposit_for(msg.sender, amount, block.timestamp + vekrome_lock_time);
        }
 
        emit RewardCollectedForVeKrome(msg.sender, farm, amount, vekrome_lock_time);
    }

    function _withdraw(address account, address farm) internal returns (uint256) {
        Reward[] storage rewards = collected[account][farm];
        uint256 start = next_withdraw_index[account][farm];

        uint256 total_amount;
        uint256 i = start;
        for (; i < rewards.length; i++) {
            if (rewards[i].collectTime + withdraw_delay > block.timestamp) {
                break;
            }
            if (rewards[i].withdrawn) {
                continue;
            }
            uint256 amount = rewards[i].krome_amount;

            rewards[i].withdrawn = true;

            total_reward_locked -= amount;
            TransferHelper.safeTransfer(krome_address, account, amount);

            emit RewardWithdrawn(account, farm, amount);
            total_amount += amount;
        }
        if (i != start) {
            next_withdraw_index[account][farm] = i;
        }
        return total_amount;
    }

    function withdraw(address farm) external returns (uint256) {
        return _withdraw(msg.sender, farm);
    }

    function _handle_queued() internal returns (uint256 handled) {
        uint256 end = Math.min(next_global_queue_index + max_queue_handling, global_queue.length);
        uint256 i = next_global_queue_index;
        for (i = next_global_queue_index; i < end; i++) {
            QueueItem memory item = global_queue[i];
            if (item.collectTime + withdraw_delay > block.timestamp) {
                break;
            }
            _withdraw(item.account, item.farm);
            delete global_queue[i];
        }
        handled = i - next_global_queue_index;
        next_global_queue_index = i;
    }

    function handle_queued() external returns (uint256) {
        return _handle_queued();
    }

    /* ================== OWNER ================== */

    function setWithdrawDelay(uint256 v) external onlyByOwnGovCustodian {
        withdraw_delay = v;
        emit WithdrawDelaySet(v);
    }

    function setMinVeKromeLockTime(uint256 v) external onlyByOwnGovCustodian {
        min_vekrome_lock_time = v;
        emit MinVeKromeLockTimeSet(v);
    }

    function setMaxQueueHandling(uint256 v) external onlyByOwnGovCustodian {
        max_queue_handling = v;
        emit MaxQueueHandlingSet(v);
    }

    function toggleFarm(address farm, bool v) external onlyByOwnGovCustodian {
        farms[farm] = v;
        emit FarmToggled(farm, v);
    }

    function setCustodian(address _custodian_address) external onlyByOwnGov {
        custodian_address = _custodian_address;
        emit CustodianSet(_custodian_address);
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, _msgSender(), amount);
        emit RecoverERC20(_token, _msgSender(), amount);
    }
}