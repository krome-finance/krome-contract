// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../Common/Owned.sol";
import "../../Libs/TransferHelper.sol";
import "../../ERC20/IERC20.sol";

interface ITreasury_ERC20 {
    function lp_token_address() external view returns (address);
    function lockedLiquidityOf(address account) external view returns (uint256);
    function lockedStakesOf(address account) external view returns (LockedStake[] memory);
    function migrator_stakeLocked_for(address staker_address, uint256 amount, uint256 secs, uint256 start_timestamp) external;
    function migrator_withdraw_locked(address staker_address, bytes32 kek_id) external;
    function reward_comptroller() external view returns (address);

    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }
}

interface IRewardComptroller {
    function earned(address account) external view returns (uint[] memory earned_arr);
    function migrate_earned(address account, uint[] memory earned_arr) external;
}


contract MigratorTreasury_ERC20 is Owned {
    mapping(address => address) public migration_map;
    mapping(address => bool) public migrate_reward_map;
    mapping(address => uint256) public corrections;

    /* ========== EVENT ========== */

    event SetMigration(address source, address target, bool migrate_reward);
    event ClearMigration(address source, address target);
    event Migrate(address treasury, address account, address caller);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address[] memory _source_addresses,
        address[] memory _target_addresses,
        bool[] memory migrate_reward
    ) Owned(payable(msg.sender)) {
        for (uint256 i = 0; i < _source_addresses.length; i++) {
            _setMigration(_source_addresses[i], _target_addresses[i], migrate_reward[i]);
        }
    }

    function _setMigration(address _source_address, address _target_address, bool _migrate_reward) internal {
        require(_source_address != address(0) && _target_address != address(0) && _source_address != _target_address);
        require(ITreasury_ERC20(_source_address).lp_token_address() == ITreasury_ERC20(_target_address).lp_token_address(), "lp token mismatch");

        migration_map[_source_address] = _target_address;
        migrate_reward_map[_source_address] = _migrate_reward;

        emit SetMigration(_source_address, _target_address, _migrate_reward);
    }

    function setMigration(address _source_address, address _target_address, bool _migrate_reward) external onlyOwner {
        _setMigration(_source_address, _target_address, _migrate_reward);
    }

    function clearMigration(address _source_address) external onlyOwner {
        address _target = migration_map[_source_address];
        require(_target != address(0), "Not exists");

        migration_map[_source_address] = address(0);
        migrate_reward_map[_source_address] = false;

        emit ClearMigration(_source_address, _target);
    }

    function migrateAccount(address _treasury_address, address _account) external onlyOwner {
        _migrate(_treasury_address, _account);
    }

    function migrate(address _treasury_address) external {
        _migrate(_treasury_address, msg.sender);
    }

    function _migrate(address _treasury_address, address _account) internal {
        address target_address = migration_map[_treasury_address];
        require(target_address != address(0), "No migration set");
        bool migrate_reward = migrate_reward_map[_treasury_address];

        ITreasury_ERC20 source_treasury = ITreasury_ERC20(_treasury_address);
        ITreasury_ERC20 target_treasury = ITreasury_ERC20(target_address);

        IRewardComptroller source_reward = IRewardComptroller(source_treasury.reward_comptroller());
        IRewardComptroller target_reward = IRewardComptroller(target_treasury.reward_comptroller());

        // console.log("migrate_reward", migrate_reward ? 1 : 0);
        uint256[] memory source_earned;
        if (migrate_reward) {
            source_earned = source_reward.earned(_account);
            // console.log("source_earned", source_earned[0]);
        }

        // migrate stakes
        {
            ITreasury_ERC20.LockedStake[] memory stakes = source_treasury.lockedStakesOf(_account);
            uint256 lockedLiquidity = source_treasury.lockedLiquidityOf(_account);
            uint256 realLockedLiquidity = 0;
            for (uint256 i = 0; i < stakes.length; i++) {
                if (stakes[i].ending_timestamp - stakes[i].start_timestamp < 100 * 365 * 24 * 3600) {
                    realLockedLiquidity += stakes[i].liquidity;
                }
            }
            if (realLockedLiquidity > lockedLiquidity) {
                uint256 correction = realLockedLiquidity - lockedLiquidity;
                TransferHelper.safeApprove(source_treasury.lp_token_address(), address(source_treasury), correction);
                source_treasury.migrator_stakeLocked_for(_account, correction, 1e8 * 365 * 24 * 3600, block.timestamp);
                corrections[address(source_treasury)] += correction;
            }
            IERC20 lp = IERC20(source_treasury.lp_token_address());
            for (uint256 i = 0; i < stakes.length; i++) {
                if (stakes[i].ending_timestamp - stakes[i].start_timestamp >= 100 * 365 * 24 * 3600) {
                    continue;
                }
                uint256 lp_balance0 = lp.balanceOf(address(this));
                source_treasury.migrator_withdraw_locked(_account, stakes[i].kek_id);

                require(lp.balanceOf(address(this)) == lp_balance0 + stakes[i].liquidity, "lp not withdrawn");

                TransferHelper.safeApprove(source_treasury.lp_token_address(), target_address, stakes[i].liquidity);
                target_treasury.migrator_stakeLocked_for(_account, stakes[i].liquidity, stakes[i].ending_timestamp - stakes[i].start_timestamp, stakes[i].start_timestamp);
                require(lp.balanceOf(address(this)) == lp_balance0, "lp not staked");
                realLockedLiquidity -= stakes[i].liquidity;
            }
            require(realLockedLiquidity == 0, "liquidity left");
        }

        // migrate earnings
        if (migrate_reward) {
            // source reward should be reset
            uint256[] memory new_source_earned = source_reward.earned(_account);
            uint256 new_source_earned_total = 0;
            for (uint256 i = 0; i < new_source_earned.length; i++) {
                new_source_earned_total += new_source_earned[i];
            }

            if (new_source_earned_total == 0) {
                uint256[] memory target_earned = target_reward.earned(_account);
                target_reward.migrate_earned(_account, source_earned);

                uint256[] memory new_target_earned = target_reward.earned(_account);
                for (uint256 i = 0; i < source_earned.length; i++) {
                    // console.log("new_source_earned", new_target_earned[i], source_earned[i] + target_earned[i], target_earned[i]);
                    require(new_target_earned[i] == source_earned[i] + target_earned[i], "earning not migrated");
                }
            }
        }
    }

    function unstake(address _treasury_address) external onlyOwner {
        ITreasury_ERC20 treasury = ITreasury_ERC20(_treasury_address);
        ITreasury_ERC20.LockedStake[] memory stakes = treasury.lockedStakesOf(msg.sender);
        for (uint256 i = 0; i < stakes.length; i++) {
            treasury.migrator_withdraw_locked(msg.sender, stakes[i].kek_id);
        }
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyOwner {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, payable(msg.sender), amount);
    }
}