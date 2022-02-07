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

// cp = checkpoint
// st = state
// ts = current timestamp
//

contract veKromeYieldDistributorV4 is TimelockOwned, ReentrancyGuard {
    struct LockState {
        uint256 lockEnd; // lock End
        uint256 lockedKrome; // locked Krome
        uint256 veKromeBalance; // veKromeBalance @ ts
        uint256 ts; // lock updated timestamp
    }

    struct EarningCheckpoint {
        uint256 earned;
        uint256 claimed;
        uint256 yieldPerShareStored;
    }

    // total weight of the period
    //      
    struct PeriodState {
        uint256 ts; // ts for period state, period - YIELD_DURATION < ts <= period
        uint256 bias; // vekrome balance - base @ ts. always positive
        uint256 slope; // decrease slope for vekrome balance from ts. always positive
        uint256 yieldPerShare; // accumulated yieldPerWeight @ ts. never decrease
        uint256 distributedYield; // global accumulated distributedReward @ ts. never decreases.
        uint256 totalShares; // sum of unexpired shares, share = initial veKROME balance.
        uint256 passedWeight; // passed weight @ ts
    }

    /* ========== STATE VARIABLES ========== */

    // Instances
    IveKrome private immutable veKROME;

    uint256 public constant YIELD_DURATION = 3600 * 24 * 7; // WEEK

    // Addresses
    address public immutable emitted_token_address;

    uint256 private constant YIELD_PRECISION = 1e18;

    // Constant for price precision
    uint256 private constant PRICE_PRECISION = 1e6;

    uint256 public totalYield; // accumulated reward. never decreases.
    uint256 public claimedYield; // accumulated reward. never decreases.
    uint256 public totalWeight; // sum all weights(weight = veKROME * lockedSeconds / 2). never decrease
    // uint256 public yieldDuration = 604800; // 7 * 86400  (7 days)
    mapping(address => bool) public reward_notifiers;
    uint256 public lastStatePeriod;
    mapping(uint256 => PeriodState) periodStates; // period end ts => PeriodState
    mapping(uint256 => uint256) slopeChanges; // period end ts => slope change after the period
    mapping(uint256 => uint256) totalSharesChanges; // period end ts => totalShares change after the period

    // veKROME tracking
    mapping(address => uint256) public userShares;
    mapping(address => LockState) public lockCheckpointed;
    mapping(address => EarningCheckpoint) public earningCheckpointed;
    mapping(address => bool) public earningInitialized;

    // Greylists
    mapping(address => bool) public greylist;

    // Admin booleans for emergencies
    bool public yieldCollectionPaused = false; // For emergencies

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
        lastStatePeriod = ((block.timestamp / YIELD_DURATION) + 1) * YIELD_DURATION;
    }

    /* ========== VIEWS ========== */

    function earned(address account) external view returns (uint256) {
        if (!earningInitialized[account]) return 0;

        uint256 lockEnd = lockCheckpointed[account].lockEnd;

        // Uninitialized users should not earn anything yet
        if (lockEnd == 0) return 0;

        PeriodState memory _periodState = _calcPeriodState(Math.min(lockEnd, block.timestamp));
        EarningCheckpoint memory cp = earningCheckpointed[account];

        return cp.earned + (_periodState.yieldPerShare - cp.yieldPerShareStored) * userShares[account] / YIELD_PRECISION;
    }

    function distributedYield() external view returns (uint256) {
        PeriodState memory _periodState = _calcPeriodState(block.timestamp);
        return _periodState.distributedYield;
    }

    function totalShares() external view returns (uint256) {
        PeriodState memory _periodState = _calcPeriodState(block.timestamp);
        return _periodState.totalShares;
    }

    function yieldPerVeKrome() external view returns (uint256) {
        PeriodState memory _periodState = _calcPeriodState(block.timestamp);
        return (totalYield - _periodState.distributedYield) / _periodState.totalShares;
    }

    function periodState() external view returns (PeriodState memory) {
        return _calcPeriodState(block.timestamp);
    }

    function getState() external view returns (
        uint256 total_shares,
        uint256 left_weight,
        uint256 bias,
        uint256 slope,
        uint256 distributed_yield,
        uint256 left_yield,
        uint256 claimed_yield
    ) {
        PeriodState memory _periodState = _calcPeriodState(block.timestamp);
        total_shares = _periodState.totalShares;
        left_weight = totalWeight - _periodState.passedWeight;
        bias = _periodState.bias;
        slope = _periodState.slope;
        distributed_yield = _periodState.distributedYield;
        left_yield = totalYield - _periodState.distributedYield;
        claimed_yield = claimedYield;
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

    function _syncPeriodState(uint256 maxPeriod) internal {
        PeriodState memory _periodState = periodStates[lastStatePeriod];

        uint256 thisEnd = ((block.timestamp - 1) / YIELD_DURATION) * YIELD_DURATION + YIELD_DURATION;
        if (maxPeriod > 0) {
            thisEnd = Math.min(lastStatePeriod + YIELD_DURATION * maxPeriod, thisEnd);
        }
        uint256 periodEnd;
        for (periodEnd = lastStatePeriod; periodEnd <= thisEnd; periodEnd += YIELD_DURATION) {
            if (block.timestamp > _periodState.ts) {
                uint256 ts = Math.min(block.timestamp, periodEnd);

                uint256 oldBias = _periodState.bias;
                _periodState.bias = _subToZero(_periodState.bias, _periodState.slope * (ts - _periodState.ts));

                if (totalWeight > _periodState.passedWeight && _periodState.totalShares > 0) {
                    uint256 periodWeight = (ts - _periodState.ts) * (oldBias + _periodState.bias);
                    uint256 periodYield = (totalYield - _periodState.distributedYield) * periodWeight / (totalWeight - _periodState.passedWeight);

                    _periodState.yieldPerShare = _periodState.yieldPerShare + periodYield * YIELD_PRECISION / _periodState.totalShares;
                    _periodState.distributedYield += periodYield; // distributedYield @ ts
                    _periodState.passedWeight += periodWeight; // passed unexpired weight @ ts
                }

                _periodState.ts = ts;
            }
            //

            periodStates[periodEnd] = _periodState;
            lastStatePeriod = periodEnd;

            if (periodEnd < thisEnd) {
                _periodState.slope = _subToZero(_periodState.slope, slopeChanges[periodEnd]);
                _periodState.totalShares = _subToZero(_periodState.totalShares, totalSharesChanges[periodEnd]);
            }
        }
    }

    function _calcPeriodState(uint t) internal view returns (PeriodState memory _periodState){
        uint256 thisEnd = ((t - 1) / YIELD_DURATION) * YIELD_DURATION + YIELD_DURATION;
        _periodState = periodStates[Math.min(lastStatePeriod, thisEnd)];

        if (thisEnd <= _periodState.ts) {
            return _periodState;
        }

        for (uint256 periodEnd = lastStatePeriod; periodEnd <= thisEnd; periodEnd += YIELD_DURATION) {
            if (t > _periodState.ts) {
                uint256 ts = Math.min(t, periodEnd);

                uint256 oldBias = _periodState.bias;
                _periodState.bias = _subToZero(_periodState.bias, _periodState.slope * (ts - _periodState.ts));

                if (totalWeight > _periodState.passedWeight && _periodState.totalShares > 0) {
                    uint256 periodWeight = (ts - _periodState.ts) * (oldBias + _periodState.bias);
                    uint256 periodYield = (totalYield - _periodState.distributedYield) * periodWeight / (totalWeight - _periodState.passedWeight);

                    _periodState.yieldPerShare = _periodState.yieldPerShare + periodYield * YIELD_PRECISION / _periodState.totalShares;
                    _periodState.distributedYield += periodYield; // distributedYield @ ts
                    _periodState.passedWeight += periodWeight; // passed unexpired weight @ ts
                }

                _periodState.ts = ts;
            }
            //

            if (periodEnd < thisEnd) {
                _periodState.slope = _subToZero(_periodState.slope, slopeChanges[periodEnd]);
                _periodState.totalShares = _subToZero(_periodState.totalShares, totalSharesChanges[periodEnd]);
            }
        }
    }

    function _syncLockChange(address account, LockState memory oldState, LockState memory newState) internal {
        PeriodState memory _periodState = periodStates[lastStatePeriod];
        require(_periodState.ts == block.timestamp); // should be already synced

        uint256 oldSlope;
        uint256 oldBias;
        uint256 oldWeight;
        uint256 oldShare;
        if (oldState.lockEnd > block.timestamp) {
            oldSlope = oldState.veKromeBalance / (oldState.lockEnd - oldState.ts);
            oldBias = oldSlope * (oldState.lockEnd - block.timestamp);
            // weight for current time
            oldWeight = oldBias * (oldState.lockEnd - block.timestamp);
            oldShare = userShares[account];
        } // else all 0

        uint256 newSlope = newState.veKromeBalance / (newState.lockEnd - newState.ts);
        uint256 newBias = newSlope * (newState.lockEnd - newState.ts);
        uint256 newWeight = newBias * (newState.lockEnd - newState.ts);
        uint256 newShare;

        if (newState.veKromeBalance > oldShare) {
            newShare = newState.veKromeBalance;
        } else {
            newShare = (
                oldShare * (oldState.lockEnd - block.timestamp)
                + newState.veKromeBalance * (newState.lockEnd - block.timestamp)
            ) / (oldState.lockEnd + newState.lockEnd - (2 * block.timestamp));
        }
        _periodState.totalShares = _periodState.totalShares + newShare - oldShare;
        userShares[account] = newShare;

        if (newWeight != oldWeight) {
            totalWeight = totalWeight + newWeight - oldWeight;
        }

        _periodState.slope = _subToZero(_periodState.slope + newSlope, oldSlope);
        _periodState.bias = _subToZero(_periodState.bias + newBias, oldBias);

        periodStates[lastStatePeriod] = _periodState;

        if (oldState.lockEnd == newState.lockEnd) {
            slopeChanges[oldState.lockEnd] = _subToZero(slopeChanges[oldState.lockEnd] + newSlope, oldSlope);
            totalSharesChanges[oldState.lockEnd] = _subToZero(totalSharesChanges[oldState.lockEnd] + newShare, oldShare);
        } else {
            if (oldState.lockEnd > block.timestamp) {
                slopeChanges[oldState.lockEnd] = _subToZero(slopeChanges[oldState.lockEnd], oldSlope);
                totalSharesChanges[oldState.lockEnd] = _subToZero(totalSharesChanges[oldState.lockEnd], oldShare);
            }

            slopeChanges[newState.lockEnd] += newSlope;
            totalSharesChanges[newState.lockEnd] += newShare;
        }
    }

    function _syncEarned(address account, LockState memory lockState) internal {
        PeriodState memory _periodState = periodStates[Math.min(lockState.lockEnd, lastStatePeriod)];

        EarningCheckpoint memory cp = earningCheckpointed[account];
        if (!earningInitialized[account]) {
            return;
        }
        if (_periodState.yieldPerShare > cp.yieldPerShareStored) {
            cp.earned = cp.earned + (_periodState.yieldPerShare - cp.yieldPerShareStored) * userShares[account] / YIELD_PRECISION;
            cp.yieldPerShareStored = _periodState.yieldPerShare;
            earningCheckpointed[account] = cp;
        }
    }

    function _checkpointUser(address account) internal {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        _syncPeriodState(0);

        LockState memory oldLockState = lockCheckpointed[account];

        _syncEarned(account, oldLockState);

        // update checkpoint if required
        IveKrome.LockedBalance memory lockedBalance = veKROME.locked(account);
        if (lockedBalance.amount == oldLockState.lockedKrome && lockedBalance.end == oldLockState.lockEnd) {
            return;
        }

        if (lockedBalance.end < block.timestamp) {
            return;
        }

        // reset yieldPerShareStored on new lock
        earningCheckpointed[account].yieldPerShareStored = periodStates[lastStatePeriod].yieldPerShare;
        if (!earningInitialized[account]) {
            earningInitialized[account] = true;
        }

        LockState memory newLockState = LockState({
            veKromeBalance: veKROME.balanceOf(account),
            lockEnd: lockedBalance.end,
            lockedKrome: lockedBalance.amount,
            ts: block.timestamp
        });

        // Update the user's stored veKROME balance
        lockCheckpointed[account] = newLockState;

        _syncLockChange(account, oldLockState, newLockState);
    }

    // Anyone can checkpoint another user
    function checkpointOtherUser(address user_addr) external {
        _checkpointUser(user_addr);
    }

    // Checkpoints the user
    function checkpoint() external {
        _checkpointUser(msg.sender);
    }

    function collectYield() external nonReentrant returns (uint256 yield0) {
        require(yieldCollectionPaused == false, "Yield collection is paused");
        require(greylist[msg.sender] == false, "Address has been greylisted");

        _checkpointUser(msg.sender);

        yield0 = earningCheckpointed[msg.sender].earned;
        if (yield0 > 0) {
            earningCheckpointed[msg.sender].earned = 0;
            earningCheckpointed[msg.sender].claimed += yield0;
            claimedYield += yield0;
            TransferHelper.safeTransfer(
                emitted_token_address,
                msg.sender,
                yield0
            );
            emit YieldCollected(msg.sender, yield0, emitted_token_address);
        }
    }

    function sync() external {
        _syncPeriodState(50);
    }

    function notifyRewardAmount(uint256 amount) external {
        // Only whitelisted addresses can notify rewards
        require(reward_notifiers[msg.sender], "Sender not whitelisted");

        // Handle the transfer of emission tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the smission amount
        TransferHelper.safeTransferFrom(emitted_token_address, msg.sender, address(this), amount);

        // Update some values beforehand
        _syncPeriodState(0);

        totalYield += amount;

        emit RewardAdded(amount);
    }

    function lockChanged(address account) external {
        require(msg.sender == address(veKROME));

        _checkpointUser(account);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Added to support recovering LP Yield and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnGov {
        // Only the owner address can ever receive the recovery withdrawal
        TransferHelper.safeTransfer(tokenAddress, owner, tokenAmount);
        emit RecoveredERC20(tokenAddress, tokenAmount);
    }

    function greylistAddress(address _address) external onlyByOwnGov {
        greylist[_address] = !(greylist[_address]);
    }

    function toggleRewardNotifier(address notifier_addr) external onlyByOwnGov {
        reward_notifiers[notifier_addr] = !reward_notifiers[notifier_addr];
    }

    function setPauses(bool _yieldCollectionPaused) external onlyByOwnGov {
        yieldCollectionPaused = _yieldCollectionPaused;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event YieldCollected(address indexed user, uint256 yield, address token_address);
    event YieldDurationUpdated(uint256 newDuration);
    event RecoveredERC20(address token, uint256 amount);

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
