// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../Common/LocatorBasedProxyV2.sol";
import "../../Libs/TransferHelper.sol";
import "../../ERC20/IERC20.sol";
import "../IStakingBoostController.sol";

interface ITreasury_ERC20 {
    function lp_token_address() external view returns (address);
    function boost_controller() external view returns (address);
    function getVirtualPrice() external view returns (uint256);
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
    function usdkPerLPToken() external view returns (uint256);

    struct LockedStake {
        bytes32 kek_id;
        uint256 start_timestamp;
        uint256 liquidity;
        uint256 ending_timestamp;
        uint256 lock_multiplier; // 18 decimals of precision. 1x = E18, 1x ~ (1+lock_max_multiplier)x
    }
}

interface IKromePriceProvider {
    function usdk_price() external view returns (uint256);
    function krome_price() external view returns (uint256);
}

interface IStakingRewardComptroller {
    function getAllRewardTokens() external returns (address[] memory);
}

contract ManageStakeMigratorV1 is LocatorBasedProxyV2 {
    uint256 public constant LP_PRICE_PRECISION = 10**18;
    // uint256 public constant KROME_PRICE_PRECISION = 10**6;
    // uint256 public constant RATE_PRECISION = 10**6;

    uint256 public unlock_fee_received;

    // in e6, 1000000 == 100%
    uint256 public min_unlock_fee_rate;
    uint256 public max_unlock_fee_rate;
    bool public unlock_allowed;

    mapping(address => bool) public old_treasuries;

    /* ========== Modifiers ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == owner || msg.sender == timelock_address || msg.sender == local_manager_address, "Not owner or timelock");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */

    function initialize (
        address _locator
    ) external initializer {
        LocatorBasedProxyV2.initializeLocatorBasedProxy(_locator);
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

    function unlockStake(address _treasury_address, bytes32 kek_id, uint256 max_fee) external {
        _unlockStake(_treasury_address, msg.sender, kek_id, max_fee);
    }

    function _unlockStake(address _treasury_address, address _account, bytes32 kek_id, uint256 max_fee) internal {
        require(unlock_allowed, "not allowed");
        ITreasury_ERC20 treasury = ITreasury_ERC20(_treasury_address);

        bool migrationToggled = false;
        if (!treasury.migrationsOn()) {
            treasury.toggleMigrations();
            migrationToggled = true;
        }
        // unlock stake
        {
            IERC20 lp = IERC20(treasury.lp_token_address());
            ITreasury_ERC20.LockedStake[] memory stakes = treasury.lockedStakesOf(_account);

            uint256 lp_balance0 = lp.balanceOf(address(this));

            ITreasury_ERC20.LockedStake memory thisStake = _find_stake(stakes, kek_id);
            require(thisStake.ending_timestamp - thisStake.start_timestamp < 100 * 365 * 24 * 3600, "Invalid stake kek_id");
            require(thisStake.ending_timestamp > block.timestamp, "already unlcoked");

            uint256 required_fee;
            {
                uint256 lpInUsd;
                if (old_treasuries[address(treasury)]) {
                    lpInUsd = (thisStake.liquidity * treasury.usdkPerLPToken() * 2 / 1e18) * IKromePriceProvider(locator.usdk()).usdk_price() / 1e6;
                } else {
                    lpInUsd = thisStake.liquidity * treasury.getVirtualPrice() / LP_PRICE_PRECISION;
                }
                uint256 unlock_fee_rate = (thisStake.ending_timestamp - block.timestamp) * (max_unlock_fee_rate - min_unlock_fee_rate) / IStakingBoostController(treasury.boost_controller()).lock_time_for_max_multiplier() + min_unlock_fee_rate;
                required_fee = lpInUsd * unlock_fee_rate / IKromePriceProvider(locator.usdk()).krome_price();
            }
            if (required_fee > 0) {
                require(required_fee <= max_fee, "slippage");
                TransferHelper.safeTransferFrom(locator.krome(), _account, address(this), required_fee);
                unlock_fee_received += required_fee;
            }

            treasury.migrator_withdraw_locked(_account, thisStake.kek_id);
            require(lp.balanceOf(address(this)) == lp_balance0 + thisStake.liquidity, "lp not withdrawn");

            TransferHelper.safeTransfer(address(lp), _account, thisStake.liquidity);
            require(lp.balanceOf(address(this)) == lp_balance0, "lp not transferred");

            emit Unlock(_treasury_address, _account, msg.sender, kek_id, thisStake.liquidity, required_fee);
        }
        if (migrationToggled) {
            treasury.toggleMigrations();
        }
    }

    /* ========== Only for managers ========== */

    function mergeForAccount(address _account, address _treasury_address, bytes32[] calldata kek_ids) external onlyByOwnGov {
        _merge(_treasury_address, _account, kek_ids);
    }

    function unlockStakeForAccount(address _account, address _treasury_address, bytes32 kek_id, uint256 krome) external onlyByOwnGov {
        _unlockStake(_treasury_address, _account, kek_id, krome);
        require(false, "ok");
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

    /* =============== set configuration ============== */
    function setUnlockFeeRate(uint256 _min, uint256 _max) external onlyByOwnGov {
        min_unlock_fee_rate = _min;
        max_unlock_fee_rate = _max;

        emit SetUnlockFeeRate(_min, _max);
    }

    function setUnlockAllowed(bool _v) external onlyByOwnGov {
        unlock_allowed = _v;

        emit SetUnlockAllowed(_v);
    }

    function setOldTreasury(address _treasury, bool _v) external onlyByOwnGov {
        old_treasuries[_treasury] = _v;

        emit SetOldTreasury(_treasury, _v);
    }

    /* ========== EVENT ========== */
    event Migrate(address treasury, address account, address caller);
    event Unlock(address treasury, address account, address caller, bytes32 kek_id, uint256 liquidity, uint256 fee);
    event SetUnlockFeeRate(uint256 _min, uint256 _max);
    event SetUnlockAllowed(bool _v);
    event SetOldTreasury(address _treasury, bool _v);

}