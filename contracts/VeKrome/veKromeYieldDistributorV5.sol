// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// =========================================================================
//    __ __                              _______
//   / //_/_________  ____ ___  ___     / ____(_)___  ____ _____  ________
//  / ,<  / ___/ __ \/ __ `__ \/ _ \   / /_  / / __ \/ __ `/ __ \/ ___/ _ \
// / /| |/ /  / /_/ / / / / / /  __/  / __/ / / / / / /_/ / / / / /__/  __/
///_/ |_/_/   \____/_/ /_/ /_/\___/  /_/   /_/_/ /_/\__,_/_/ /_/\___/\___/
//
// =========================================================================
// ================== veKromeYieldDistributor (USDK) =======================
// =========================================================================
// Distributes Frax protocol yield based on the claimer's veKROME balance
// V3: Yield will now not accrue for unlocked veKROME

// Frax Finance: https://github.com/FraxFinance

// Primary Author(s)
// Travis Moore: https://github.com/FortisFortuna

// Reviewer(s) / Contributor(s)
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian

// Originally inspired by Synthetix.io, but heavily modified by the Frax team (veKROME portion)
// https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../Math/Math.sol";
import "./IveKrome.sol";
import "../Libs/TransferHelper.sol";
import "../Common/LocatorBasedProxy.sol";
import "../ERC20/IERC20.sol";

// cp = checkpoint
// st = state
// ts = current timestamp
//

contract veKromeYieldDistributorV5 is LocatorBasedProxy, ReentrancyGuardUpgradeable {
    struct UserYieldCheckpoint {
        uint256 earned;
        uint256 nextYieldIndex;
        uint256 vekromeIndex;
    }

    struct UserVeKromeCheckpoint {
        uint256 veKrome; // veKromeBalance @ ts
        uint256 lockEnd; // lock End
        uint256 ts; // lock updated timestamp
        uint256 yieldLength;
    }

    struct Yield {
        uint256 yieldPerVeKrome; // E18
        uint256 ts;
    }

    struct PeriodYield {
        uint256 ts;
        uint256 yield;
    }

    struct YieldInfo {
        uint256 yieldKrome;
        uint256 lockedKrome;
        uint256 ts;
    }

    /* ========== STATE VARIABLES ========== */

    uint256 public constant YIELD_PERIOD_DURATION = 3600 * 24 * 7; // WEEK
    uint256 private constant YIELD_PRECISION = 1e18;
    uint256 private constant YIELD_PER_VEKROME_PRECISION = 1e18;

    // Instances
    IveKrome private veKROME;
    // Addresses
    address public emitted_token_address;

    uint256 public total_yield; // accumulated reward. never decreases.
    uint256 public claimed_yield; // accumulated reward. never decreases.
    // uint256 public yieldDuration = 604800; // 7 * 86400  (7 days)
    mapping(address => bool) public reward_notifiers;
    Yield[] public yields;

    PeriodYield[] public period_yields;

    // user checkpoint
    mapping(address => UserYieldCheckpoint) public user_yield_checkpoints;
    mapping(address => UserVeKromeCheckpoint[]) public user_vekrome_checkpoints;
    mapping(address => uint256) public user_earning_accumulated;

    // Greylists
    mapping(address => bool) public greylist;

    /* =========== CONFIGS ==============*/
    // Admin booleans for emergencies
    bool public yield_collection_paused; // For emergencies
    uint256 public max_checkpoint_yields;

    // update v1
    YieldInfo[] public yield_infos;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(msg.sender == locator.owner_address() || msg.sender == locator.timelock(), "Not owner or timelock");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    function initialize (
        address _locator,
        address _emittedToken,
        address _veKrome_address
    ) external initializer {
        LocatorBasedProxy.initializeLocatorBasedProxy(_locator);
        ReentrancyGuardUpgradeable.__ReentrancyGuard_init();
        emitted_token_address = _emittedToken;

        veKROME = IveKrome(_veKrome_address);

        reward_notifiers[locator.owner_address()] = true;

        // CONFIGS
        yield_collection_paused = false; // For emergencies
        max_checkpoint_yields = 30;
    }

    /* ========== VIEWS ========== */

    function _vekrome_on(UserVeKromeCheckpoint memory cp, uint256 ts) internal pure returns (uint256) {
        if (cp.veKrome == 0) return 0;
        if (ts < cp.ts) return 0;
        if (ts >= cp.lockEnd) return 0;
        if (cp.lockEnd <= cp.ts) return 0;
        uint256 lockPeriod = cp.lockEnd - cp.ts; // > 0
        uint256 leftPeriod = cp.lockEnd - ts; // > 0
        return cp.veKrome * leftPeriod / lockPeriod;
    }

    function earned(address account) public view returns (uint256 earning) {
        (earning,, ) = _earned(account, 0);
    }

    function _earned(address account, uint256 max_yield) internal view returns (uint256 earning, uint256 next_yield_index, uint256 vekrome_index) {
        UserYieldCheckpoint memory cp = user_yield_checkpoints[account];
        UserVeKromeCheckpoint[] memory vekromeCpList = user_vekrome_checkpoints[account];

        if (vekromeCpList.length == 0 || yields.length == 0) return (0, yields.length, 0); // not checkpointed

        earning = cp.earned;
        vekrome_index = cp.vekromeIndex;

        uint256 last_index = max_yield > 0 ? Math.min(cp.nextYieldIndex + max_yield, yields.length) : yields.length;
        for (next_yield_index = cp.nextYieldIndex; next_yield_index < last_index; next_yield_index++) {
            while (vekrome_index < vekromeCpList.length - 1 && vekromeCpList[vekrome_index + 1].yieldLength <= next_yield_index) vekrome_index++;
            uint256 vekrome = _vekrome_on(vekromeCpList[vekrome_index], yields[next_yield_index].ts);
            earning += vekrome * yields[next_yield_index].yieldPerVeKrome / YIELD_PER_VEKROME_PRECISION;
        }
    }

    function getState() external view returns (
        uint256 totalYield,
        uint256 claimedYield,
        uint256 recentAvgYield,
        uint256 totalPeriod
    ) {
        totalYield = total_yield;
        claimedYield = claimed_yield;

        if (period_yields.length > 1) {
            uint256 recentSum = 0;
            uint256 start = period_yields.length - 1;
            uint256 count = 0;
            for (uint256 i = start; i >= 0 && start - i < 3; i--) {
                recentSum += period_yields[i].yield;
                count++;
            }
            recentAvgYield = count > 0 ? recentSum  / count  : 0;
        } else {
            recentAvgYield = 0;
        }

        if (yields.length > 0) {
            totalPeriod = block.timestamp - yields[0].ts;
        } else {
            totalPeriod = 0;
        }

    }

    function getYieldLength() external view returns (uint256) {
        return yields.length;
    }

    function getYieldsPage(uint256 idx, uint256 size) external view returns (Yield[] memory yields_page) {
        uint256 end = Math.min(yields.length, idx + size);
        if (end < idx) return new Yield[](0);

        yields_page = new Yield[](end - idx);
        for (uint256 i = idx; i < end; i++) {
            yields_page[i - idx] = yields[i];
        }
    }

    function getPeriodYieldLength() external view returns (uint256) {
        return period_yields.length;
    }

    function getPeirodYieldsPage(uint256 idx, uint256 size) external view returns (PeriodYield[] memory yields_page) {
        uint256 end = Math.min(period_yields.length, idx + size);
        if (end < idx) return new PeriodYield[](0);

        yields_page = new PeriodYield[](end - idx);
        for (uint256 i = idx; i < end; i++) {
            yields_page[i - idx] = period_yields[i];
        }
    }

    function getPeriodYield() external view returns (uint256 yield) {
        if (period_yields.length == 0) return 0;
        PeriodYield memory periodYield = period_yields[period_yields.length - 1];
        uint256 cur_period_ts = (block.timestamp / YIELD_PERIOD_DURATION) * YIELD_PERIOD_DURATION;
        return (periodYield.ts == cur_period_ts) ? periodYield.yield : 0;
    }

    function getYieldInfoLength() external view returns (uint256) {
        return yield_infos.length;
    }

    function getYieldInfoPage(uint256 idx, uint256 size) external view returns (YieldInfo[] memory yields_page) {
        uint256 end = Math.min(yield_infos.length, idx + size);
        if (end < idx) return new YieldInfo[](0);

        yields_page = new YieldInfo[](end - idx);
        for (uint256 i = idx; i < end; i++) {
            yields_page[i - idx] = yield_infos[i];
        }
    }

    function getUserVeKromeCheckpointLength(address account) external view returns (uint256) {
        return user_vekrome_checkpoints[account].length;
    }

    function getCurrentVeKromeCheckpoint(address account) external view returns (UserVeKromeCheckpoint memory) {
        UserVeKromeCheckpoint[] memory checkpoints = user_vekrome_checkpoints[account];
        if (checkpoints.length == 0) return UserVeKromeCheckpoint(0, 0, 0, 0);
        return checkpoints[checkpoints.length - 1];
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // prevent underflows
    function _subToZero(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a > b) {
            return a - b;
        } else {
            return 0;
        }
    }

    function _checkpointUser(address account, uint256 max_yields) internal {
        UserVeKromeCheckpoint memory cp = UserVeKromeCheckpoint({
            veKrome: veKROME.balanceOf(account),
            lockEnd: veKROME.locked__end(account),
            ts: block.timestamp,
            yieldLength: yields.length
        });

        UserVeKromeCheckpoint[] storage vekrome_cp_list = user_vekrome_checkpoints[account];
        if (vekrome_cp_list.length == 0 || vekrome_cp_list[vekrome_cp_list.length - 1].yieldLength < yields.length) {
            vekrome_cp_list.push(cp);
        } else {
            vekrome_cp_list[vekrome_cp_list.length - 1] = cp;
        }

        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        (uint256 earning, uint256 next_yield_index, uint256 vekrome_index) = _earned(account, max_yields);

        user_yield_checkpoints[account] = UserYieldCheckpoint({
            earned: earning,
            nextYieldIndex: next_yield_index,
            vekromeIndex: vekrome_index
        });
    }

    // Anyone can checkpoint another user
    function checkpointOtherUser(address user_addr) external {
        _checkpointUser(user_addr, max_checkpoint_yields);
    }

    // Checkpoints the user
    function checkpoint() external {
        _checkpointUser(msg.sender, max_checkpoint_yields);
    }

    function _collectYieldFor(address account, address recipient) internal nonReentrant returns (uint256 earning) {
        require(yield_collection_paused == false, "Yield collection is paused");
        require(greylist[account] == false, "Address has been greylisted");
        // require(yields.length - user_yield_checkpoints[account].nextYieldIndex <= max_checkpoint_yields, "checkpoint required");

        _checkpointUser(account, max_checkpoint_yields);

        earning = user_yield_checkpoints[account].earned;

        if (earning > 0) {
            user_yield_checkpoints[account].earned = 0;
            user_earning_accumulated[account] += earning;
            claimed_yield += earning;

            TransferHelper.safeTransfer(
                emitted_token_address,
                recipient,
                earning
            );
            emit YieldCollected(account, earning, emitted_token_address, recipient);
        }
    }

    function collectYield() external returns (uint256 earning) {
        return _collectYieldFor(msg.sender, msg.sender);
    }

    function collectYieldFor(address account) external returns (uint256 earning) {
        return _collectYieldFor(account, account);
    }

    function collectYieldReApe() external returns (uint256 earning) {
        earning = _collectYieldFor(msg.sender, address(this));
        TransferHelper.safeApprove(emitted_token_address, address(veKROME), earning);
        veKROME.manage_deposit_for(msg.sender, earning, 0);
    }

    function notifyRewardAmount(uint256 amount) external {
        // Only whitelisted addresses can notify rewards
        require(reward_notifiers[msg.sender], "Sender not whitelisted");

        uint256 vekrome_total_supply = veKROME.totalSupply();
        require(vekrome_total_supply > 0, "no vekrome locked");

        // Handle the transfer of emission tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the smission amount
        TransferHelper.safeTransferFrom(emitted_token_address, msg.sender, address(this), amount);

        // Update some values beforehand

        total_yield += amount;
        yields.push(Yield({
            yieldPerVeKrome: amount * YIELD_PER_VEKROME_PRECISION / vekrome_total_supply,
            ts: block.timestamp
        }));
        yield_infos.push(YieldInfo({
            yieldKrome: amount,
            lockedKrome: veKROME.totalKromeSupply(),
            ts: block.timestamp
        }));

        uint256 cur_period_ts = (block.timestamp / YIELD_PERIOD_DURATION) * YIELD_PERIOD_DURATION;
        if (period_yields.length == 0 || period_yields[period_yields.length - 1].ts != cur_period_ts) {
            period_yields.push(PeriodYield({ts: cur_period_ts, yield: amount }));
        } else {
            period_yields[period_yields.length - 1].yield += amount;
        }

        emit RewardAdded(amount);
    }

    function lockChanged(address account) external {
        _checkpointUser(account, 0);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Added to support recovering LP Yield and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        // Only the owner address can ever receive the recovery withdrawal
        TransferHelper.safeTransfer(tokenAddress, locator.owner_address(), tokenAmount);
        emit RecoveredERC20(tokenAddress, tokenAmount);
    }

    function setGreylistAddress(address _address, bool v) external onlyByOwnGov {
        greylist[_address] = v;
        emit SetGreylistAddress(_address, v);
    }

    function setRewardNotifier(address notifier_addr, bool v) external onlyByOwnGov {
        reward_notifiers[notifier_addr] = v;
        emit SetRewardNotifier(notifier_addr, v);
    }

    function setMaxCheckpointYields(uint256 v) external onlyByOwnGov {
        max_checkpoint_yields = v;
        emit SetMaxCheckpointYields(v);
    }

    function setPause(bool _v) external onlyByOwnGov {
        yield_collection_paused = _v;
        emit SetPause(_v);
    }

    function migrateYieldInfo(uint256 idx, uint256 yieldKrome, uint256 lockedKrome, uint256 ts) external onlyByOwnGov {
        require(yield_infos.length >= idx, "invalid state");
        if (yield_infos.length == idx) {
            yield_infos.push(YieldInfo({
                yieldKrome: yieldKrome,
                lockedKrome: lockedKrome,
                ts: ts
            }));
        } else {
            yield_infos[idx] = YieldInfo({
                yieldKrome: yieldKrome,
                lockedKrome: lockedKrome,
                ts: ts
            });
        }
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event YieldCollected(address indexed user, uint256 yield, address token_address, address recipient);
    event RecoveredERC20(address token, uint256 amount);
    event SetGreylistAddress(address, bool);
    event SetRewardNotifier(address, bool);
    event SetMaxCheckpointYields(uint256);
    event SetPause(bool);

    /* ========== A CHICKEN ========== */
    //
    //         ,~.
    //      ,-'__ `-,
    //     {,-'  `. }              ,')
    //    ,( a )   `-.__         ,',')~,
    //   <=.) (         `-.__,==' ' ' '}
    //     (   )                      /)
    //      `-'\   ,                    )
    //          |  \        `~.        /
    //          \   `._        \      /
    //           \     `._____,'    ,'
    //            `-.             ,'
    //               `-._     _,-'
    //                   77jj'
    //                  //_||
    //               __//--'/`
    //             ,--'/`  '
    //
    // [hjw] https://textart.io/art/vw6Sa3iwqIRGkZsN1BC2vweF/chicken
}
