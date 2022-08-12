// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../Common/LocatorBasedProxyV2.sol";
import "../../Libs/TransferHelper.sol";
import "../../ERC20/IERC20.sol";

interface ITreasury_ERC20 {
    function lp_token_address() external view returns (address);
    function totalLiquidityLocked() external view returns (uint256);
    function lockedLiquidityOf(address account) external view returns (uint256);
    function lockedStakesOf(address account) external view returns (LockedStake[] memory);
    function migrator_stakeLocked_for(address staker_address, uint256 amount, uint256 secs, uint256 start_timestamp) external;
    function reward_comptroller() external view returns (address);

    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }
}

interface ILpMigrationTreasury is ITreasury_ERC20 {
    function getStakesToMigrate(uint256) external view returns (address[] memory stakers, ITreasury_ERC20.LockedStake[] memory stakes);
    function migrator_set_migrated(address staker_address, bytes32 kek_id) external;
}

interface IStakingRewardComptroller {
    function updateRewardAndBalance(address account, bool sync_too) external;
    function getAllRewardTokens() external returns (address[] memory);
    function earned(address account) external view returns (uint[] memory earned_arr);
    function migrate_earned(address account, uint[] memory earned_arr) external;
}

contract LpMigrationMigrator is LocatorBasedProxyV2 {
    /* ========== EVENT ========== */

    event SetMigration(address _source, address _target);
    event SetMigratedLp(address _source, uint256 _source_amount, uint256 _migrated_amount);
    event Migrate(address treasury_from, address treasury_to, address account, address caller);

    /* ========== CONFIG VARIABLES ========== */
    mapping(address => address) public migration_map; // treasury_from => treasury_to

    address[] public migration_source_array;
    mapping(address => uint256) migration_source_orders;

    mapping(address => uint256) public total_source_lp_liquidities; // treasury_from => total liquidity of target lp
    mapping(address => uint256) public total_migrated_lp_liquidities; // treasury_from => total liquidity of target lp
    bool pauseMigration;

    mapping(address => uint256[]) public migrated_earnings;
    mapping(address => mapping(address => uint256[])) public migrated_account_earnings;

    /* ========== Modifiers ========== */

    modifier onlyByManager() {
        managerPermissionRequired();
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize (
        address _locator
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
    }

    function migrate(address _treasury_address, uint256 migration_count) external onlyByManager {
        _migrate(_treasury_address, migration_count);
    }

    function _migrate(address _treasury_from_address, uint256 migration_count) internal {
        require(!pauseMigration, "migration paused");
        require(migration_count > 0);

        ILpMigrationTreasury treasury_from = ILpMigrationTreasury(_treasury_from_address);
        ITreasury_ERC20 treasury_to = ITreasury_ERC20(migration_map[_treasury_from_address]);
        require(address(treasury_to) != address(0), "No migration defined");

        uint256 total_source_liquidity = total_source_lp_liquidities[_treasury_from_address];
        uint256 total_migrated_liquidity = total_migrated_lp_liquidities[_treasury_from_address];
        require(total_source_liquidity > 0 && total_migrated_liquidity > 0, "Liquidity not ready");

        (address[] memory stakers, ITreasury_ERC20.LockedStake[] memory stakes) = ILpMigrationTreasury(_treasury_from_address).getStakesToMigrate(migration_count);
        require(stakers.length == stakes.length, "invalid stake length");
        
        IStakingRewardComptroller source_reward = IStakingRewardComptroller(treasury_from.reward_comptroller());
        address[] memory reward_tokens = source_reward.getAllRewardTokens();

        IERC20 lp = IERC20(treasury_to.lp_token_address());

        for (uint i = 0; i < stakers.length; i++) {
            address staker = stakers[i];
            ITreasury_ERC20.LockedStake memory stake = stakes[i];
            if (stakers[i] == address(0) || stake.liquidity == 0) {
                continue;
            }

            {
                source_reward.updateRewardAndBalance(staker, true);
                uint256[] memory source_earned = source_reward.earned(staker);
                for (uint256 j = 0; j < reward_tokens.length; j++) {
                    TransferHelper.safeTransfer(reward_tokens[j], staker, source_earned[j]);
                }
            }

            {
                uint256 liquidity = stake.liquidity * total_migrated_liquidity / total_source_liquidity;

                // this contract should have lp to be migrated
                TransferHelper.safeApprove(address(lp), address(treasury_to), liquidity);
                treasury_to.migrator_stakeLocked_for(staker, liquidity, stake.ending_timestamp - stake.start_timestamp, stake.start_timestamp);
                treasury_from.migrator_set_migrated(staker, stake.kek_id);
            }

            // _migrate_earnings(treasury_from.reward_comptroller(), treasury_to.reward_comptroller(), staker);
        }
    }

    // function _migrate_earnings(address _source_comptroller_address, address _target_comptroller_address, address _account) internal {
    //     IStakingRewardComptroller source = IStakingRewardComptroller(_source_comptroller_address);
    //     IStakingRewardComptroller target = IStakingRewardComptroller(_target_comptroller_address);
    //     source.updateRewardAndBalance(_account, true);

    //     uint256[] memory source_earned = source.earned(_account);
    //     uint256[] memory target_earned = target.earned(_account);

    //     uint256[] memory earning_to_migrate = new uint256[](source_earned.length);
    //     for (uint i = 0; i < source_earned.length; i++) {
    //         earning_to_migrate[i] = source_earned[i] - migrated_account_earnings[_source_comptroller_address][_account].length > 0 ? migrated_account_earnings[_source_comptroller_address][_account][i] : 0;
    //     }

    //     target.migrate_earned(_account, earning_to_migrate);

    //     if (migrated_earnings[_source_comptroller_address].length == 0) {
    //         migrated_earnings[_source_comptroller_address] = earning_to_migrate;
    //     } else if (migrated_earnings[_source_comptroller_address].length == earning_to_migrate.length) {
    //         for (uint256 i = 0; i < source_earned.length; i++) {
    //             migrated_earnings[_source_comptroller_address][i] += earning_to_migrate[i];
    //         }
    //     }

    //     migrated_account_earnings[_source_comptroller_address][_account] = source_earned;

    //     uint256[] memory new_target_earned = target.earned(_account);
    //     for (uint256 i = 0; i < earning_to_migrate.length; i++) {
    //         // console.log("new_source_earned", new_target_earned[i], source_earned[i] + target_earned[i], target_earned[i]);
    //         require(new_target_earned[i] == earning_to_migrate[i] + target_earned[i], "earning not migrated");
    //     }
    // }

    function setMigration(address _source_address, address _target_address) external onlyByManager {
        if (_target_address != address(0)) {
            // add new source
            if (migration_source_orders[_source_address] == 0) {
                migration_source_array.push(_source_address);
                migration_source_orders[_source_address] = migration_source_array.length;
            }
        } else {
            // remove source
            uint256 source_order = migration_source_orders[_source_address];
            if (source_order > 0) {
                address addr_to_replace = migration_source_array[migration_source_array.length - 1];
                
                migration_source_array[source_order] = addr_to_replace;
                migration_source_orders[addr_to_replace] = source_order;

                migration_source_orders[_source_address] = 0;
                migration_source_array.pop();
            }
        }

        migration_map[_source_address] = _target_address;
        emit SetMigration(_source_address, _target_address);
    }

    function setMigratedLp(address _treasury_from_address, uint256 source_amount, uint256 migrated_amount) external onlyByManager {
        ITreasury_ERC20 treasury_to = ITreasury_ERC20(migration_map[_treasury_from_address]);
        require(address(treasury_to) != address(0), "Invalid treasury");

        address lp = treasury_to.lp_token_address();
        require(lp != address(0), "Invalid lp address");

        total_source_lp_liquidities[_treasury_from_address] = source_amount;
        total_migrated_lp_liquidities[_treasury_from_address] = migrated_amount;

        // TransferHelper.safeTransferFrom(lp, msg.sender, address(this), migrated_amount);

        emit SetMigratedLp(_treasury_from_address, source_amount, migrated_amount);
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