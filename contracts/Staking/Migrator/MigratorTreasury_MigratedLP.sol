// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../Common/LocatorBasedProxyV2.sol";
import "../../Libs/TransferHelper.sol";
import "../../ERC20/IERC20.sol";

interface ITreasury_ERC20 {
    function lp_token_address() external view returns (address);
    function lockedLiquidityOf(address account) external view returns (uint256);
    function lockedStakesOf(address account) external view returns (LockedStake[] memory);
    function migrator_stakeLocked_for(address staker_address, uint256 amount, uint256 secs, uint256 start_timestamp) external;
    function migrator_withdraw_locked(address staker_address, bytes32 kek_id) external;
    function reward_comptroller() external view returns (address);
    function toggleMigrations() external;
    function migrationsOn() external view returns (bool);

    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }
}

interface IStakingRewardComptroller {
    function getAllRewardTokens() external returns (address[] memory);
}

contract MigratorTreasury_MigratedLP is LocatorBasedProxyV2 {
    ITreasury_ERC20 public source_treasury;
    ITreasury_ERC20 public target_treasury;
    uint256 public source_liquidity;
    uint256 public target_liquidity;

    mapping(address => mapping(bytes32 => bool)) public migrated_kek_ids; // (account, kek_id) => boolean
    mapping(address => bytes32[]) public migrated_kek_id_array; // (account, kek_id) => boolean
    mapping(address => uint256) public migrated_liquidity; // (account, kek_id) => boolean

    uint256 public migrated_source_liquidity;
    uint256 public migrated_target_liquidity;

    uint256 public __unused1; // max_migrate_count;

    /* ========== EVENT ========== */

    event SetMigration(address source, address target, bool migrate_reward);
    event Migrate(address account, bytes32 kek_id, address caller);

    /* ========== Modifiers ========== */

    modifier onlyByManager() {
        require(msgByManager(), "Not manager");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    function initialize (
        address _locator,
        address _source_treausry_address,
        address _target_treausry_address
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);

        source_treasury = ITreasury_ERC20(_source_treausry_address);
        target_treasury = ITreasury_ERC20(_target_treausry_address);
    }

    /* =========== VIEW FUNCTIONS ============= */
    function getAllMigrated(address _account) external view returns (bytes32[] memory) {
        return migrated_kek_id_array[_account];
    }

    /* =========== OWNER CONFIGURE METHODS ============= */

    function setSourceLiquidity(uint256 _amount) external onlyByManager() {
        source_liquidity = _amount;
    }

    function setTargetLiquidity(uint256 _amount) external onlyByManager() {
        target_liquidity = _amount;
    }

    /* =========== MAIN METHODS ============= */

    function migrate(uint256 max_migrate_count) external {
        _migrate(msg.sender, max_migrate_count);
    }

    function _find_stake(ITreasury_ERC20.LockedStake[] memory stakes, bytes32 kek_id) internal pure returns (ITreasury_ERC20.LockedStake memory) {
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].kek_id == kek_id) {
                return stakes[i];
            }
        }
        revert("invalid kek_id");
    }

    function _migrate(address _account, uint256 max_migrate_count) internal {
        require(address(source_treasury) != address(0));
        require(address(target_treasury) != address(0));
        require(source_liquidity > 0);
        require(target_liquidity > 0);
        require(migrated_liquidity[_account] < source_treasury.lockedLiquidityOf(_account), "all liquidity migrated");

        // migrate stakes
        {
            IERC20 target_lp = IERC20(target_treasury.lp_token_address());

            ITreasury_ERC20.LockedStake[] memory stakes = source_treasury.lockedStakesOf(_account);

            uint256 migrated_count = 0;
            for (uint256 i = 0; i < stakes.length && migrated_count < max_migrate_count; i++) {
                ITreasury_ERC20.LockedStake memory thisStake = stakes[i];
                bytes32 kek_id = thisStake.kek_id;
                if (migrated_kek_ids[_account][kek_id]) {
                    continue;
                }

                if (thisStake.ending_timestamp - thisStake.start_timestamp >= 100 * 365 * 24 * 3600) {
                    continue;
                }

                uint256 new_liquidity = thisStake.liquidity * target_liquidity / source_liquidity;
                TransferHelper.safeApprove(address(target_lp), address(target_treasury), new_liquidity);
                target_treasury.migrator_stakeLocked_for(_account, new_liquidity, thisStake.ending_timestamp - thisStake.start_timestamp, thisStake.start_timestamp);

                migrated_kek_ids[_account][kek_id] = true;
                migrated_kek_id_array[_account].push(kek_id);
                migrated_liquidity[_account] += thisStake.liquidity;
                migrated_source_liquidity += thisStake.liquidity;
                migrated_target_liquidity += new_liquidity;

                migrated_count++;

                emit Migrate(_account, kek_id, msg.sender);
            }
        }
    }

    /* =========== OWNER OPERATION METHODS ============= */

    function migrateAccount(address _account, uint256 max_migrate_count) external onlyByManager {
        _migrate(_account, max_migrate_count);
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByManager {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, payable(msg.sender), amount);
    }

    // Generic proxy
    function execute(
        address _to,
        uint256 _value,
        bytes calldata _data
    ) external onlyByManager returns (bool, bytes memory) {
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