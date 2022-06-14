// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../Common/Context.sol";
import "../Common/LocatorBasedProxyV2.sol";
import "../ERC20/IERC20.sol";
import "../Libs/TransferHelper.sol";
import "../Math/Math.sol";

interface IFarm {
    function collectRewardFor(address) external returns (uint256[] memory);
    function withdrawLockedFor(address, bytes32) external;
    function reward_comptroller() external view returns (address);
}

interface IRewardComptroller {
    function getAllRewardTokens() external view returns (address[] memory);
}

interface IVeKrome {
    function manage_deposit_for(address _addr, uint256 _value, uint256 _unlock_time) external;
}

struct Reward {
    uint256 i;
    bool withdrawn;
    uint256 krome_amount;
    uint256 collectTime;
}

interface ISourceDelegator {
    function collected(address, address, uint256) external view returns (Reward memory);
    function next_withdraw_index(address, address) external view returns (uint256);
    function collectedRewardsLength(address account, address farm) external view returns (uint256);
    function collectedRewardsPage(address account, address farm, uint256 start, uint256 length) external view returns (Reward[] memory);
}

contract KromeRewardForStakingDelegatorV2 is Context, LocatorBasedProxyV2 {
    address public krome_address;
    address public vekrome_address;
    address public custodian_address;

    uint256 public withdraw_delay;
    uint256 public min_vekrome_lock_time;
    uint256 public max_queue_handling;
    uint256 public max_withdraw;

    bool public paused;

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

    /* =============== EVENT ================ */
    event RewardCollectedForWithdraw(address account, address farm, uint256 amount);
    event RewardCollectedForVeKrome(address account, address farm, uint256 amount, uint256 unlock_time);
    event RewardWithdrawn(address account, address farm, uint256 amount, uint256 count);

    event WithdrawDelaySet(uint256);
    event MinVeKromeLockTimeSet(uint256);
    event MaxQueueHandlingSet(uint256);
    event FarmToggled(address,bool);
    event CustodianSet(address);
    event PausedSet(bool);
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


    function initialize(
        address _locator_address,
        address _vekrome_address,
        address _custodian_address
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator_address);
        krome_address = locator.krome();
        vekrome_address = _vekrome_address;
        custodian_address = _custodian_address;

        withdraw_delay = 21 * 24 * 3600; // 21 DAYS
        min_vekrome_lock_time = 30 * 24 * 3600; // 30 DAYS
        max_queue_handling = 0;
        max_withdraw = 20;
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

    function _collectReward(address _farm_address) internal returns (uint256) {
        _handle_queued();

        IFarm farm = IFarm(_farm_address);
        IRewardComptroller reward_comptroller = IRewardComptroller(farm.reward_comptroller());

        address[] memory reward_tokens = reward_comptroller.getAllRewardTokens();

        uint256 balance0 = IERC20(krome_address).balanceOf(address(this));
        uint256[] memory rewards = farm.collectRewardFor(msg.sender);
        uint256 balance = IERC20(krome_address).balanceOf(address(this));

        require(rewards.length == reward_tokens.length, "reward length mismatch");

        for (uint i = 0; i < reward_tokens.length; i++) {
            if (reward_tokens[i] == krome_address) {
                require(balance - balance0 == rewards[i], "reward balance");
            } else {
                TransferHelper.safeTransfer(reward_tokens[i], msg.sender, rewards[i]);
            }
        }

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
        require(!paused, "paused");
        uint256 amount = _collectReward(farm);

        if (amount > 0) {
            return _lockReward(msg.sender, farm, amount);
        }
        return 0;
    }

    function collectRewardForVeKrome(address farm, uint256 vekrome_lock_time) onlyValidFarm(farm) external {
        require(!paused, "paused");
        require(vekrome_lock_time >= min_vekrome_lock_time, "unlock_time is less than minimum");
        uint256 amount = _collectReward(farm);

        if (amount > 0) {
            TransferHelper.safeApprove(krome_address, vekrome_address, amount);
            IVeKrome(vekrome_address).manage_deposit_for(msg.sender, amount, block.timestamp + vekrome_lock_time);
    
            emit RewardCollectedForVeKrome(msg.sender, farm, amount, vekrome_lock_time);
        }
    }

    function withdrawLockedWithRewardLock(address farm, bytes32 kek_id) external onlyValidFarm(farm) returns (uint256) {
        require(!paused, "paused");
        _withdrawLocked(farm, kek_id);
        uint256 amount = _collectReward(farm);
        if (amount > 0) {
            return _lockReward(msg.sender, farm, amount);
        }
        return 0;
    }

    function withdrawLockedWithVeKromeLock(address farm, bytes32 kek_id, uint256 vekrome_lock_time) external onlyValidFarm(farm) {
        require(!paused, "paused");
        require(vekrome_lock_time >= min_vekrome_lock_time, "unlock_time is less than minimum");
        _withdrawLocked(farm, kek_id);

        uint256 amount = _collectReward(farm);
        if (amount > 0) {
            TransferHelper.safeApprove(krome_address, vekrome_address, amount);
            IVeKrome(vekrome_address).manage_deposit_for(msg.sender, amount, block.timestamp + vekrome_lock_time);
        }
 
        emit RewardCollectedForVeKrome(msg.sender, farm, amount, vekrome_lock_time);
    }

    function _withdraw(address account, address farm, uint256 max_count) internal returns (uint256) {
        Reward[] storage rewards = collected[account][farm];
        uint256 start = next_withdraw_index[account][farm];

        uint256 total_amount;
        uint256 i = start;
        uint256 end = Math.min(i + max_count, rewards.length);
        uint256 count = 0;
        for (; i < end; i++) {
            if (rewards[i].collectTime + withdraw_delay > block.timestamp) {
                break;
            }
            if (rewards[i].withdrawn) {
                continue;
            }
            uint256 amount = rewards[i].krome_amount;

            rewards[i].withdrawn = true;

            total_reward_locked -= amount;
            total_amount += amount;
            count++;
        }
        if (i != start) {
            next_withdraw_index[account][farm] = i;
        }

        if (total_amount > 0) {
            TransferHelper.safeTransfer(krome_address, account, total_amount);
            emit RewardWithdrawn(account, farm, total_amount, count);
        }

        return total_amount;
    }

    function withdraw(address farm) external returns (uint256) {
        require(!paused, "paused");
        return _withdraw(msg.sender, farm, max_withdraw);
    }

    function withdrawAtMost(address farm, uint256 max_count) external returns (uint256) {
        require(!paused, "paused");
        return _withdraw(msg.sender, farm, max_count);
    }

    function _handle_queued() internal returns (uint256 handled) {
        uint256 end = Math.min(next_global_queue_index + max_queue_handling, global_queue.length);
        uint256 i = next_global_queue_index;
        for (i = next_global_queue_index; i < end; i++) {
            QueueItem memory item = global_queue[i];
            if (item.collectTime + withdraw_delay > block.timestamp) {
                break;
            }
            _withdraw(item.account, item.farm, max_withdraw);
            delete global_queue[i];
        }
        handled = i - next_global_queue_index;
        next_global_queue_index = i;
    }

    function handle_queued() external returns (uint256) {
        require(!paused, "paused");
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

    function setPaused(bool v) external onlyByOwnGov {
        paused = v;
        emit PausedSet(v);
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, _msgSender(), amount);
        emit RecoverERC20(_token, _msgSender(), amount);
    }

    function migrate(address source_address, address account, address farm, uint256 migrate_count) external onlyByOwnGov {
        ISourceDelegator source = ISourceDelegator(source_address);
        uint256 sourceLength = source.collectedRewardsLength(account, farm);
        Reward[] storage rewards = collected[account][farm];
        if (rewards.length < sourceLength) {
            Reward[] memory source_rewards = source.collectedRewardsPage(account, farm, rewards.length, migrate_count);
            for (uint i = 0; i < source_rewards.length; i++) {
                collected[account][farm].push(source_rewards[i]);
                total_reward_locked += source_rewards[i].krome_amount;
            }
        }
    }
}