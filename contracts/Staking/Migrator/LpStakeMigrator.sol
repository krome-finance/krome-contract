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

    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }
}

interface ILpMigrationTreasury is ITreasury_ERC20 {
    function migrated(address _account) external view returns (bool);
    function migrator_set_migrated(address staker_address) external;
}

interface IStakingRewardComptroller {
    function getAllRewardTokens() external returns (address[] memory);
}

contract LpStakeMigrator is LocatorBasedProxyV2 {
    /* ========== EVENT ========== */

    event Migrate(address treasury_from, address treasury_to, address account, address caller);

    /* ========== CONFIG VARIABLES ========== */
    mapping(address => address) public migration_map; // treasury_from => treasury_to
    mapping(address => uint256) public total_migrated_lp_liquidities; // treasury_from => total liquidity of target lp
    bool pauseMigration;

    /* ========== Modifiers ========== */

    modifier onlyByManager() {
        managerPermissionRequired();
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    function initialize (
        address _locator
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
    }

    function migrateForAccount(address _account, address _treasury_address) external onlyByManager {
        _migrate(_treasury_address, _account);
    }

    function migrate(address _treasury_address) external {
        _migrate(_treasury_address, msg.sender);
    }

    function _migrate(address _treasury_from_address, address _account) internal {
        require(!pauseMigration, "migration paused");

        ILpMigrationTreasury treasury_from = ILpMigrationTreasury(_treasury_from_address);
        ITreasury_ERC20 treasury_to = ITreasury_ERC20(migration_map[_treasury_from_address]);
        require(address(treasury_to) != address(0), "No migration defined");

        uint256 total_migrated_liquidity = total_migrated_lp_liquidities[_treasury_from_address];
        require(total_migrated_liquidity > 0, "Liquidity not ready");

        require(!treasury_from.migrated(_account), "Already migrated");
        require(treasury_from.lockedLiquidityOf(_account) > 0, "nothing to migrate");

        IERC20 lp = IERC20(treasury_to.lp_token_address());

        uint256 total_source_liquidity = treasury_from.totalLiquidityLocked();

        ITreasury_ERC20.LockedStake[] memory stakes = treasury_from.lockedStakesOf(_account);
        for (uint256 i = 0; i < stakes.length; i++)  {
            ITreasury_ERC20.LockedStake memory stake = stakes[i];

            uint256 liquidity = stake.liquidity * total_migrated_liquidity / total_source_liquidity;

            // this contract should have lp to be migrated
            TransferHelper.safeApprove(address(lp), address(treasury_to), liquidity);
            treasury_to.migrator_stakeLocked_for(_account, liquidity, stake.ending_timestamp - stake.start_timestamp, stake.start_timestamp);
        }
        treasury_from.migrator_set_migrated(_account);
    }

    function addMigratedLp(address _treasury_from_address, uint256 amount) external onlyByManager {
        ITreasury_ERC20 treasury_to = ITreasury_ERC20(migration_map[_treasury_from_address]);
        require(address(treasury_to) != address(0), "Invalid treasury");

        address lp = treasury_to.lp_token_address();
        require(lp != address(0), "Invalid lp address");

        total_migrated_lp_liquidities[_treasury_from_address] = amount;

        TransferHelper.safeTransferFrom(lp, msg.sender, address(this), amount);
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