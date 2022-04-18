// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../Common/Owned.sol";
import "../../Libs/TransferHelper.sol";
import "../../ERC20/IERC20.sol";
import "../../External/Claimswap/IUniswapV2Router02.sol";
import "../../External/Eklipse/IEklipseSwap.sol";
import "../../External/Eklipse/IEklipseRouter.sol";

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

// interface IRewardComptroller {
//     function earned(address account) external view returns (uint[] memory earned_arr);
//     function migrate_earned(address account, uint[] memory earned_arr) external;
// }


contract MigratorTreasury_USDT2Eklipse is Owned {
    address public source_address;
    address public target_address;
    IUniswapV2Router02 public claimswap_router;
    IEklipseRouter public eklipse_router;
    IEklipseSwap public eklipse_3moon;
    IEklipseSwap public eklipse_3moon_usdk;
    IERC20 public usdt;
    IERC20 public usdk;
    IERC20 public eklp;

    uint256 public max_migrate_count = 2;

    /* ========== EVENT ========== */

    event ClearMigration(address source, address target);
    event Migrate(address treasury, address account, address caller);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _source_address,
        address _target_address,
        address _claimswap_router,
        address _eklipse_router,
        address _eklipse_3moon,
        address _eklipse_3moon_usdk,
        address _usdt_address,
        address _usdk_address
    ) Owned(payable(msg.sender)) {
        source_address = _source_address;
        target_address = _target_address;
        claimswap_router = IUniswapV2Router02(_claimswap_router);
        eklipse_router = IEklipseRouter(_eklipse_router);
        eklipse_3moon = IEklipseSwap(_eklipse_3moon);
        eklipse_3moon_usdk = IEklipseSwap(_eklipse_3moon_usdk);
        usdt = IERC20(_usdt_address);
        usdk = IERC20(_usdk_address);

        ITreasury_ERC20 target_treasury = ITreasury_ERC20(target_address);

        eklp = IERC20(eklipse_3moon_usdk.getLpToken());

        require(target_treasury.lp_token_address() == address(eklp), "lp token mismatch");
    }

    function migrateAccount(address _account) external onlyOwner {
        _migrate(_account);
    }

    function migrate(address treasury_address) external {
        require(treasury_address == source_address, "invalid treasury address");
        _migrate(msg.sender);
    }

    function _migrate(address _account) internal {
        require(target_address != address(0), "No migration set");

        ITreasury_ERC20 source_treasury = ITreasury_ERC20(source_address);
        ITreasury_ERC20 target_treasury = ITreasury_ERC20(target_address);

        // migrate stakes
        {
            IERC20 eklp3moon = IERC20(eklipse_3moon.getLpToken());
            uint256 eklp_3moon_index = eklipse_3moon_usdk.getTokenIndex(address(eklp3moon));
            uint256 eklp_usdk_index = eklipse_3moon_usdk.getTokenIndex(address(usdk));

            ITreasury_ERC20.LockedStake[] memory stakes = source_treasury.lockedStakesOf(_account);

            IERC20 source_lp = IERC20(source_treasury.lp_token_address());
            for (uint256 i = 0; i < (stakes.length > max_migrate_count ? max_migrate_count : stakes.length); i++) {
                if (stakes[i].ending_timestamp - stakes[i].start_timestamp >= 100 * 365 * 24 * 3600) {
                    continue;
                }
                uint256 lp_balance0 = source_lp.balanceOf(address(this));
                source_treasury.migrator_withdraw_locked(_account, stakes[i].kek_id);

                require(source_lp.balanceOf(address(this)) == lp_balance0 + stakes[i].liquidity, "lp not withdrawn");

                TransferHelper.safeApprove(address(source_lp), address(claimswap_router), stakes[i].liquidity);
                (uint256 amountUsdt, uint256 amountUsdk) = claimswap_router.removeLiquidity(
                    address(usdt),
                    address(usdk),
                    stakes[i].liquidity,
                    1,
                    1,
                    address(this),
                    block.timestamp + 60
                );
                require(source_lp.balanceOf(address(this)) == lp_balance0, "lp not returned");
                require(usdt.balanceOf(address(this)) == amountUsdt, "invalid usdt balance");
                require(usdk.balanceOf(address(this)) == amountUsdk, "invalid usdk balance");

                uint256 eklp_balance0 = eklp.balanceOf(address(this));

                uint256 eklpAmount;
                {
                    uint256[] memory amounts = new uint256[](3);
                    amounts[1] = amountUsdt;
                    TransferHelper.safeApprove(address(usdt), address(eklipse_3moon), 2**255);
                    uint256 eklp3MoonAmount = eklipse_3moon.addLiquidity(amounts, 1, block.timestamp + 60);

                    uint256[] memory amounts2 = new uint256[](2);
                    amounts2[eklp_3moon_index] = eklp3MoonAmount;
                    amounts2[eklp_usdk_index] = amountUsdk;

                    TransferHelper.safeApprove(address(eklp3moon), address(eklipse_3moon_usdk), eklp3MoonAmount);
                    TransferHelper.safeApprove(address(usdk), address(eklipse_3moon_usdk), amountUsdk);
                    eklpAmount = eklipse_3moon_usdk.addLiquidity(amounts2, 1, block.timestamp + 60);
                }

                // uint256 eklpAmount;
                // {
                //     uint256[] memory amounts = new uint256[](4);
                //     amounts[1] = amountUsdt;
                //     amounts[3] = amountUsdk;
                //     uint256 eklpExpected = eklipse_router.reviewAddLiquidity(address(eklipse_3moon_usdk), amounts);
                //     require(eklpExpected > 0, "invalid eklp expected");
                //     console.log("usdt", amountUsdt);
                //     console.log("usdk", amountUsdk);
                //     console.log("eklpExpected", eklpExpected);
                //     console.log("eklpExpected", eklpExpected);
                //     TransferHelper.safeApprove(address(usdt), address(eklipse_router), 2**255);
                //     TransferHelper.safeApprove(address(usdk), address(eklipse_router), 2**255);
                //     eklpAmount = eklipse_router.addLiquidity(address(eklipse_3moon), amounts, 1, block.timestamp + 60);
                //     console.log("eklpAmount", eklpAmount);
                // }

                TransferHelper.safeApprove(address(eklp), target_address, eklpAmount);
                target_treasury.migrator_stakeLocked_for(_account, eklpAmount, stakes[i].ending_timestamp - stakes[i].start_timestamp, stakes[i].start_timestamp);
                require(eklp.balanceOf(address(this)) == eklp_balance0, "lp not staked");
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

    function setMaxMigrateCount(uint256 v) external onlyOwner {
        max_migrate_count = v;
    }
}