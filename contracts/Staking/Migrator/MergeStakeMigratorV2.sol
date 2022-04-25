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
    function valid_migrators(address) external view returns (bool);
    function collectRewardFor(address rewardee) external returns (uint256[] memory);
    function collect_reward_delegator() external returns (address);
    function setCollectRewardDelegator(address _delegator_address) external;

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

contract MergeStakeMigratorV2 is LocatorBasedProxyV2 {
    /* ========== EVENT ========== */

    event Migrate(address treasury, address account, address caller);

    /* ========== Modifiers ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    function initialize (
        address _locator
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
    }

    function mergeForAccount(address _account, address _treasury_address, bytes32[] calldata kek_ids) external onlyByOwnGov {
        _merge(_treasury_address, _account, kek_ids);
    }

    function merge(address _treasury_address, bytes32[] calldata kek_ids) external {
        _merge(_treasury_address, msg.sender, kek_ids);
    }

    function _find_stake(ITreasury_ERC20.LockedStake[] memory stakes, bytes32 kek_id) internal pure returns (ITreasury_ERC20.LockedStake memory) {
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].kek_id == kek_id) {
                return stakes[i];
            }
        }
        revert("invalid kek_id");
    }

    function _merge(address _treasury_address, address _account, bytes32[] calldata kek_ids) internal {
        ITreasury_ERC20 treasury = ITreasury_ERC20(_treasury_address);

        bool migrationToggled = false;
        if (!treasury.migrationsOn()) {
            treasury.toggleMigrations();
            migrationToggled = true;
        }
        // migrate stakes
        {
            uint256 liquidity = 0;
            uint256 start_timestamp;
            uint256 ending_timestamp;

            IERC20 lp = IERC20(treasury.lp_token_address());
            ITreasury_ERC20.LockedStake[] memory stakes = treasury.lockedStakesOf(_account);

            uint256 lp_balance0 = lp.balanceOf(address(this));

            for (uint256 i = 0; i < kek_ids.length; i++) {
                ITreasury_ERC20.LockedStake memory thisStake = _find_stake(stakes, kek_ids[i]);
                if (thisStake.ending_timestamp - thisStake.start_timestamp >= 100 * 365 * 24 * 3600) {
                    continue;
                }
                if (thisStake.ending_timestamp > ending_timestamp) {
                    start_timestamp = thisStake.start_timestamp;
                    ending_timestamp = thisStake.ending_timestamp;
                }
                liquidity += thisStake.liquidity;

                treasury.migrator_withdraw_locked(_account, thisStake.kek_id);
                require(lp.balanceOf(address(this)) == lp_balance0 + liquidity, "lp not withdrawn");
            }

            require(ending_timestamp > 0 && start_timestamp > 0, "invalid timestamp");

            TransferHelper.safeApprove(address(lp), _treasury_address, liquidity);
            treasury.migrator_stakeLocked_for(_account, liquidity, ending_timestamp - start_timestamp, start_timestamp);
            require(lp.balanceOf(address(this)) == lp_balance0, "lp not staked");
        }
        if (migrationToggled) {
            treasury.toggleMigrations();
        }
    }

    // collect reward without locktime for owner
    function collectReward(address _treasury_address) external onlyByOwnGov {
        ITreasury_ERC20 treasury = ITreasury_ERC20(_treasury_address);
        IStakingRewardComptroller rewardComp = IStakingRewardComptroller(treasury.reward_comptroller());

        address[] memory tokens = rewardComp.getAllRewardTokens();

        address org_reward_delegator = treasury.collect_reward_delegator();
        treasury.setCollectRewardDelegator(address(this));

        uint256[] memory rewards = treasury.collectRewardFor(msg.sender);
        require(rewards.length == tokens.length, "invalid reward length");
        for (uint256 i = 0; i < tokens.length; i++) {
            if (rewards[i] > 0) {
                TransferHelper.safeTransfer(tokens[i], msg.sender, rewards[i]);
            }
        }
        treasury.setCollectRewardDelegator(org_reward_delegator);
    }

    // delegate toggleMigrations for migrators
    function toggleMigration(address _treasury_address) external {
        ITreasury_ERC20 treasury = ITreasury_ERC20(_treasury_address);
        require(treasury.valid_migrators(msg.sender), "Invalid migrator");
        treasury.toggleMigrations();
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyByOwnGov {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, payable(msg.sender), amount);
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
}