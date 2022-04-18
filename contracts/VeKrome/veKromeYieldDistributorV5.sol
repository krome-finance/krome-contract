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

import "../Math/Math.sol";
import "./IveKrome.sol";
import "../Libs/TransferHelper.sol";
import "../Common/ReentrancyGuard.sol";
import "../Common/TimelockOwned.sol";
import "../ERC20/IERC20.sol";

// cp = checkpoint
// st = state
// ts = current timestamp
//

contract veKromeYieldDistributorV5 is TimelockOwned, ReentrancyGuard {
    struct UserCheckpoint {
        uint256 earned;
        uint256 nextYieldIndex;
        uint256 veKrome; // veKromeBalance @ ts
        uint256 lockEnd; // lock End
        uint256 ts; // lock updated timestamp
    }

    struct Yield {
        uint256 yieldPerVeKrome; // E18
        uint256 ts;
    }

    /* ========== STATE VARIABLES ========== */

    // Instances
    IveKrome private immutable veKROME;

    uint256 public constant YIELD_DURATION = 3600 * 24 * 7; // WEEK

    // Addresses
    address public immutable emitted_token_address;

    uint256 private constant YIELD_PRECISION = 1e18;
    uint256 private constant YIELD_PER_VEKROME_PRECISION = 1e18;

    // Constant for price precision
    uint256 private constant PRICE_PRECISION = 1e6;

    uint256 public total_yield; // accumulated reward. never decreases.
    uint256 public claimed_yield; // accumulated reward. never decreases.
    // uint256 public yieldDuration = 604800; // 7 * 86400  (7 days)
    mapping(address => bool) public reward_notifiers;
    Yield[] public yields;

    // user checkpoint
    mapping(address => UserCheckpoint) public user_checkpoints;
    mapping(address => uint256) public user_earning_accumulated;

    // Greylists
    mapping(address => bool) public greylist;

    // Admin booleans for emergencies
    bool public yield_collection_paused = false; // For emergencies

    uint256 public max_checkpoint_yields = 30;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require( msg.sender == owner || msg.sender == timelock_address, "Not owner or timelock");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _owner,
        address _emittedToken,
        address _timelock_address,
        address _veKrome_address
    ) TimelockOwned(_owner, _timelock_address) {
        emitted_token_address = _emittedToken;

        veKROME = IveKrome(_veKrome_address);

        reward_notifiers[_owner] = true;
    }

    /* ========== VIEWS ========== */

    function _vekrome_on(UserCheckpoint memory cp, uint256 ts) internal pure returns (uint256) {
        if (cp.veKrome == 0) return 0;
        if (ts < cp.ts) return 0;
        if (ts >= cp.lockEnd) return 0;
        if (cp.lockEnd <= cp.ts) return 0;
        uint256 lockPeriod = cp.lockEnd - cp.ts; // > 0
        uint256 leftPeriod = cp.lockEnd - ts; // > 0
        return cp.veKrome * leftPeriod / lockPeriod;
    }

    function earned(address account) public view returns (uint256 earning) {
        (earning, ) = _earned(account, 0);
    }

    function _earned(address account, uint256 max_yield) internal view returns (uint256 earning, uint256 next_yield_index) {
        UserCheckpoint memory cp = user_checkpoints[account];
        if (cp.ts == 0) return (0, yields.length); // not checkpointed

        uint256 last_index = max_yield > 0 ? Math.min(cp.nextYieldIndex + max_yield, yields.length) : yields.length;
        earning = cp.earned;
        for (next_yield_index = cp.nextYieldIndex; next_yield_index < last_index; next_yield_index++) {
            uint256 vekrome = _vekrome_on(cp, yields[next_yield_index].ts);
            earning += vekrome * yields[next_yield_index].yieldPerVeKrome / YIELD_PER_VEKROME_PRECISION;
        }
    }

    function getState() external view returns (
        uint256 totalYield,
        uint256 claimedYield
    ) {
        totalYield = total_yield;
        claimedYield = claimed_yield;
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
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        (uint256 earning, uint256 next_yield_index) = _earned(account, max_yields);

        if (next_yield_index >= yields.length) { // full update or new account
            user_checkpoints[account] = UserCheckpoint({
                earned: earning,
                nextYieldIndex: next_yield_index,
                veKrome: veKROME.balanceOf(account),
                lockEnd: veKROME.locked__end(account),
                ts: block.timestamp
            });
        } else { // partial update
            Yield memory nextYield = yields[next_yield_index];
            UserCheckpoint memory cp = user_checkpoints[account];

            user_checkpoints[account] = UserCheckpoint({
                earned: earning,
                nextYieldIndex: next_yield_index,
                veKrome: _vekrome_on(cp, nextYield.ts),
                lockEnd: cp.lockEnd,
                ts: nextYield.ts
            });
        }
    }

    // Anyone can checkpoint another user
    function checkpointOtherUser(address user_addr) external {
        _checkpointUser(user_addr, max_checkpoint_yields);
    }

    // Checkpoints the user
    function checkpoint() external {
        _checkpointUser(msg.sender, max_checkpoint_yields);
    }

    function _collectYieldFor(address account, address recipient) public nonReentrant returns (uint256 earning) {
        require(yield_collection_paused == false, "Yield collection is paused");
        require(greylist[account] == false, "Address has been greylisted");
        require(yields.length - user_checkpoints[account].nextYieldIndex <= max_checkpoint_yields, "checkpoint required");

        _checkpointUser(account, max_checkpoint_yields);

        earning = user_checkpoints[account].earned;

        if (earning > 0) {
            user_checkpoints[account].earned = 0;
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
        veKROME.deposit_for(msg.sender, earning);
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

        emit RewardAdded(amount);
    }

    function lockChanged(address account) external {
        require(msg.sender == address(veKROME));

        _checkpointUser(account, 0);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Added to support recovering LP Yield and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        // Only the owner address can ever receive the recovery withdrawal
        TransferHelper.safeTransfer(tokenAddress, owner, tokenAmount);
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
