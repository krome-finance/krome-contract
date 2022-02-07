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
// ======================== KromeStablecoin (USDK) =========================
// =========================================================================
// Original idea and credit:
// Curve Finance's veCRV
// https://resources.curve.fi/faq/vote-locking-boost
// https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy
// veFXS was basically a fork, with the key difference that 1 FXS locked for 1 second would be ~ 1 veFXS,
// but veKROME is like to veCRV, 1 KROME locked from 1 second would be ~ 1veKROME
// veKrome is solidity clone of veCRV
//
// Frax Reviewer(s) / Contributor(s)
// Travis Moore: https://github.com/FortisFortuna
// Jason Huan: https://github.com/jasonhuan
// Sam Kazemian: https://github.com/samkazemian
//
// Voting escrow to have time-weighted votes
// Votes have a weight depending on time, so that users are committed
// to the future of (whatever they are voting for).
// The weight in this implementation is linear, and lock cannot be more than maxtime:
// w ^
// 1 +                /
//     |            /
//     |        /
//     |    /
//     |/
// 0 +--------+------> time
//             maxtime (4 years?)


import "../Common/Owned.sol";
import "../Common/ReentrancyGuard.sol";
import "../Math/Math.sol";
import "../Libs/Address.sol";
import "../Libs/TransferHelper.sol";

struct Point {
    int128 bias;
    int128 slope;    // - dweight / dt
    uint256 ts;
    uint256 blk;    // block
    uint256 krome_amt;
}
// We cannot really do block numbers per se b/c slope is per time, not per block
// and per block could be fairly bad b/c Ethereum changes blocktimes.
// What we can do is to extrapolate ***At functions

struct LockedBalance {
    uint256 amount;
    uint256 end;
}

interface ERC20 {
    function decimals() external view returns(uint256);
    function balanceOf(address addr) external view returns(uint256);
    function name() external view returns(string memory);
    function symbol() external view returns(string memory);
    function transfer(address to, uint256 amount) external returns(bool);
    function transferFrom(address spender, address to, uint256 amount) external returns(bool);
}


// Interface for checking whether address belongs to a whitelisted
// type of a smart wallet.
// When new types are added - the whole contract is changed
// The check() method is modifying to be able to use caching
// for individual wallet addresses
interface SmartWalletChecker {
    function check(address addr) external returns(bool);
}


interface IVotingEscrowDelegation{
    function total_minted(address) external view returns (uint256);
}

interface IVotingEscrowTracker {
    function lockChanged(address) external;
}


contract veKrome is Owned, ReentrancyGuard {
    using Address for address;

    int128 constant DEPOSIT_FOR_TYPE = 0;
    int128 constant CREATE_LOCK_TYPE = 1;
    int128 constant INCREASE_LOCK_AMOUNT = 2;
    int128 constant INCREASE_UNLOCK_TIME = 3;
    int128 constant MANAGE_DEPOSIT_FOR_TYPE = 4;
    
    /* ============ EVENT ================ */

    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 type_, uint256 ts);

    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    event Supply(uint256 prevSupply, uint256 supply);

    event SmartWalletCheckerComitted(address future_smart_wallet_checker);

    event SmartWalletCheckerApplied(address smart_wallet_checker);

    event EmergencyUnlockToggled(bool emergencyUnlockActive);

    event DepositDelegatorWhitelistToggled(address deposit_delegator, bool v);

    
    /* ============ PROPERTIES ============ */
    uint256 constant WEEK = 7 * 86400;    // all future times are rounded by week
    uint256 constant MAXTIME = 4 * 365 * 86400;    // 4 years
    uint256 constant MULTIPLIER = 10 ** 18;

    uint256 constant VOTE_WEIGHT_MULTIPLIER = 48;    // 4x gives 300% boost at 4 years

    address public token;
    uint256 public supply;

    mapping(address => LockedBalance) public locked;

    uint256 public epoch;
    mapping(uint256 => Point) public point_history;    // epoch -> unsigned point
    mapping(address => mapping(uint256 => Point)) public user_point_history;    // user -> Point[user_epoch]
    mapping(address => uint256) public user_point_epoch;
    mapping(uint256 => int128) public slope_changes;    // time -> signed slope change

    // Aragon's view methods for compatibility
    address public controller;
    bool public transfersEnabled;

    // Emergency Unlock
    bool public emergencyUnlockActive;

    // ERC20 related
    string public name;
    string public symbol;
    string public version;
    uint256 public decimals;

    // Checker for whitelisted (smart contract) wallets which are allowed to deposit
    // The goal is to prevent tokenizing the escrow
    address public future_smart_wallet_checker;
    address public smart_wallet_checker;

    address public delegation_address;

    address[] public voting_escrow_tracker_array;

    // lock delegator contracts
    mapping(address => bool) public deposit_delegator_whitelist;

    /**
     * Contract constructor
     * @param token_addr `ERC20CRV` token address
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _version Contract version - required for Aragon compatibility
     */
    constructor(address token_addr, string memory _name, string memory _symbol, string memory _version) Owned(msg.sender) {
        token = token_addr;
        point_history[0].blk = block.number;
        point_history[0].ts = block.timestamp;
        point_history[0].krome_amt = 0;
        controller = msg.sender;
        transfersEnabled = true;

        uint256 _decimals = ERC20(token_addr).decimals();
        require(_decimals <= 255, "decimals should be at most 255");
        decimals = _decimals;

        name = _name;
        symbol = _symbol;
        version = _version;
    }

    /**
     * Set an external contract to check for approved smart contract wallets
     * @param addr Address of Smart contract checker
     */
    function commit_smart_wallet_checker(address addr) external onlyOwner {
        future_smart_wallet_checker = addr;

        emit SmartWalletCheckerComitted(future_smart_wallet_checker);
    }

    /**
     * Apply setting external contract to check approved smart contract wallets
     */
    function apply_smart_wallet_checker() external onlyOwner {
        smart_wallet_checker = future_smart_wallet_checker;

        emit SmartWalletCheckerApplied(smart_wallet_checker);
    }

    /**
     * @dev Used to allow early withdrawals of veKROME back into KROME, in case of an emergency
     */
    function toggleEmergencyUnlock() external onlyOwner {
        emergencyUnlockActive = !emergencyUnlockActive;

        emit EmergencyUnlockToggled(emergencyUnlockActive);
    }

    function toggleDepositDelegatorWhitelist(address deposit_delegator, bool v) external onlyOwner {
        if (deposit_delegator_whitelist[deposit_delegator] != v) {
            deposit_delegator_whitelist[deposit_delegator] = v;

            emit DepositDelegatorWhitelistToggled(deposit_delegator, v);
        }
    }

    /**
     * @dev Used to recover non-KROME ERC20 tokens
     */
    function recoverERC20(address token_addr, uint256 amount) external onlyOwner {
        require(token_addr != token, "Invalid token address");    // Cannot recover KROME. Use toggleEmergencyUnlock instead and have users pull theirs out individually
        TransferHelper.safeTransfer(token_addr, owner, amount);
    }

    /**
     * Check if the call is from a whitelisted smart contract, revert if not
     * @param addr Address to be checked
     */
    function assert_not_contract(address addr) internal {
        if (addr != tx.origin || addr.isContract()) {
            address checker = smart_wallet_checker;
            if (checker != address(0)) {
                if (SmartWalletChecker(checker).check(addr)) {
                    return;
                }
            }
            revert("Smart contract depositors not allowed");
        }
    }

    /**
     * Get the most recently recorded rate of voting power decrease for `addr`
     * @param addr Address of the user wallet
     * @return Value of the slope
     */
    function get_last_user_slope(address addr) external view returns(int128) {
        uint256 uepoch = user_point_epoch[addr];
        return user_point_history[addr][uepoch].slope;
    }

    /**
     * Get the timestamp for checkpoint `_idx` for `_addr`
     * @param _addr User wallet address
     * @param _idx User epoch number
     * @return Epoch time of the checkpoint
     */
    function user_point_history__ts(address _addr, uint256 _idx) external view returns(uint256) {
        return user_point_history[_addr][_idx].ts;
    }

    /**
     * Get timestamp when `_addr`'s lock finishes
     * @param _addr User wallet
     * @return Epoch time of the lock end
     */
    function locked__end(address _addr) external view returns(uint256) {
        return locked[_addr].end;
    }

    /**
     * @notice Record global and per-user data to checkpoint
     * @param addr User's wallet address. No user checkpoint if 0x0
     * @param old_locked Pevious locked amount / end lock time for the user
     * @param new_locked New locked amount / end lock time for the user
     */
    function _checkpoint(address addr, LockedBalance memory old_locked, LockedBalance memory new_locked, uint256 max_iteration) internal {
        Point memory u_old;
        Point memory u_new;
        int128 old_dslope = 0;
        int128 new_dslope = 0;
        uint256 _epoch = epoch;
        Point memory last_point;
        {
            if (addr != address(0)) {
                // Calculate slopes and biases
                // Kept at zero when they have to
                if (old_locked.end > block.timestamp && old_locked.amount > 0) {
                    u_old.slope = int128(int256(old_locked.amount / MAXTIME));
                    u_old.bias = u_old.slope * int128(uint128(old_locked.end - block.timestamp));
                    u_old.krome_amt = old_locked.amount;
                }
                if (new_locked.end > block.timestamp && new_locked.amount > 0) {
                    u_new.slope = int128(int256(new_locked.amount / MAXTIME));
                    u_new.bias = u_new.slope * int128(uint128(new_locked.end - block.timestamp));
                    u_new.krome_amt = safe_uint256(int256(new_locked.amount));
                }

                // Read values of scheduled changes in the slope
                // old_locked.end can be in the past and in the future
                // new_locked.end can ONLY by in the FUTURE unless everything expired: than zeros
                old_dslope = slope_changes[old_locked.end];
                if (new_locked.end != 0) {
                    if (new_locked.end == old_locked.end) {
                        new_dslope = old_dslope;
                    } else {
                        new_dslope = slope_changes[new_locked.end];
                    }
                }
            }

            last_point = Point({bias: 0, slope: 0, ts: block.timestamp, blk: block.number, krome_amt: 0});
            if (_epoch > 0) {
                last_point = point_history[_epoch];
            } else {
                last_point.krome_amt = ERC20(token).balanceOf(address(this)); // saves gas by only calling once
            }
            uint256 last_checkpoint = last_point.ts;
            // initial_last_point is used for extrapolation to calculate block number
            // (approximately, for *At methods) and save them
            // as we cannot figure that out exactly from inside the contract
            Point memory initial_last_point = Point({ bias: last_point.bias, slope: last_point.slope, ts: last_point.ts, blk: last_point.blk, krome_amt: last_point.krome_amt });
            uint256 block_slope = 0;    // dblock/dt
            if (block.timestamp > last_point.ts) {
                block_slope = MULTIPLIER * (block.number - last_point.blk) / (block.timestamp - last_point.ts);
            }
            // If last point is already recorded in this block, slope=0
            // But that's ok b/c we know the block in such case

            // Go over weeks to fill history and calculate what the current point is
            uint256 t_i = (last_checkpoint / WEEK) * WEEK;
            max_iteration = max_iteration > 0 ? max_iteration : 128;
            for (uint256 i = 0; i < max_iteration; i++) {
                // Hopefully it won't happen that this won't get used in 5 years!
                // If it does, users will be able to withdraw but vote weight will be broken
                t_i += WEEK;
                int128 d_slope = 0;
                if (t_i > block.timestamp) {
                    t_i = block.timestamp;
                } else {
                    d_slope = slope_changes[t_i];
                }
                last_point.bias -= last_point.slope * int128(uint128(t_i - last_checkpoint));
                last_point.slope += d_slope;
                if (last_point.bias < 0) {    // This can happen
                    last_point.bias = 0;
                }
                if (last_point.slope < 0) {    // This cannot happen - just in case
                    last_point.slope = 0;
                }
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.blk = initial_last_point.blk + block_slope * (t_i - initial_last_point.ts) / MULTIPLIER;
                _epoch += 1;

                // Fill for the current block, if applicable
                if (t_i == block.timestamp) {
                    last_point.blk = block.number;
                    break;
                } else {
                    point_history[_epoch] = last_point;
                }
            }

            epoch = _epoch;
            // Now point_history is filled until t=now
        }

        if (addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (u_new.slope - u_old.slope);
            last_point.bias += (u_new.bias - u_old.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
            last_point.krome_amt = last_point.krome_amt + u_new.krome_amt - u_old.krome_amt;
        }

        // Record the changed point into history
        point_history[_epoch] = last_point;

        if (addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            {
                if (old_locked.end > block.timestamp) {
                    // old_dslope was <something> - u_old.slope, so we cancel that
                    old_dslope += u_old.slope;
                    if (new_locked.end == old_locked.end) {
                            old_dslope -= u_new.slope; // It was a new deposit, not extension
                    }
                    slope_changes[old_locked.end] = old_dslope;
                }

                if (new_locked.end > block.timestamp) {
                    if (new_locked.end > old_locked.end) {
                        new_dslope -= u_new.slope;    // old slope disappeared at this point
                        slope_changes[new_locked.end] = new_dslope;
                    }
                    // else: we recorded it already in old_dslope
                }
            }

            // Now handle user history
            uint256 user_epoch = user_point_epoch[addr] + 1;

            user_point_epoch[addr] = user_epoch;
            u_new.ts = block.timestamp;
            u_new.blk = block.number;
            u_new.krome_amt = safe_uint256(int256(locked[addr].amount));
            user_point_history[addr][user_epoch] = u_new;
        }
    }

    /**
     * Deposit and lock tokens for a user
     * @param _addr User's wallet address
     * @param _value Amount to deposit
     * @param unlock_time New time when to unlock the tokens, or 0 if unchanged
     * @param locked_balance Previous locked amount / timestamp
     */
    function _deposit_for(address _from, address _addr, uint256 _value, uint256 unlock_time, LockedBalance memory locked_balance, int128 type_) internal {
        LockedBalance memory _locked = locked_balance;
        uint256 supply_before = supply;

        supply = supply_before + _value;
        LockedBalance memory old_locked = LockedBalance({amount: _locked.amount, end: _locked.end });
        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += _value;
        if (unlock_time != 0) {
            _locked.end = unlock_time;
        }
        locked[_addr] = _locked;

        // Possibilities:
        // Both old_locked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)
        _checkpoint(_addr, old_locked, _locked, 0);

        if (_value != 0) {
            bool result = ERC20(token).transferFrom(_from, address(this), _value);
            require(result);
        }

        for (uint i = 0; i < voting_escrow_tracker_array.length; i++) {
            IVotingEscrowTracker(voting_escrow_tracker_array[i]).lockChanged(_addr);
        }

        emit Deposit(_addr, _value, _locked.end, type_, block.timestamp);
        emit Supply(supply_before, supply_before + _value);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpoint() external {
        _checkpoint(address(0), LockedBalance(0, 0), LockedBalance(0, 0), 0);
    }

    /**
     * @notice Record global data to checkpoint
     */
    function checkpointFor(uint256 iterations) external {
        _checkpoint(address(0), LockedBalance(0, 0), LockedBalance(0, 0), iterations);
    }

    /**
     * Deposit `_value` tokens for `_addr` and add to the lock
     * @dev Anyone (even a smart contract) can deposit for someone else, but
     *            cannot extend their locktime and deposit for a brand new user
     * @param _addr User's wallet address
     * @param _value Amount to add to user's lock
     */
    function deposit_for(address _addr, uint256 _value) external nonReentrant {
        LockedBalance memory _locked = locked[_addr];

        require(_value > 0, "dev: need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");

        _deposit_for(_addr, _addr, _value, 0, locked[_addr], DEPOSIT_FOR_TYPE);
    }

    /**
     * Deposit `_value` tokens for `_addr` and add to the lock
     * If `_unlock_time` > 0, extend lock time,
     * if `_unlock_time` < existing lock time and `_value` > 0 it will be ignored
     * If no existing lock, create new lock
     * @dev Whitelisted contracts can deposit for someone else, and
     *            event extend their locktime and deposit for a brand new user
     * @param _addr User's wallet address
     * @param _value Amount to add to user's lock
     */
    function manage_deposit_for(address _addr, uint256 _value, uint256 _unlock_time) external nonReentrant {
        require(_addr == msg.sender || deposit_delegator_whitelist[msg.sender], "Only whitelisted deposit delegator may perform this action");
        if (!deposit_delegator_whitelist[msg.sender]) {
            assert_not_contract(msg.sender);
        }
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK;    // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[_addr];

        if (_locked.amount > 0) {
            require(_locked.end > block.timestamp, "Cannot deposit for expired lock. Withdraw");
            require(_value > 0 || unlock_time > 0, "dev: need non-zero value or non-zero unlock_time");
            require(_value > 0 || unlock_time > _locked.end, "Can only increase lock duration");
        } else {
            require(_value > 0, "dev: need non-zero value");
            require(unlock_time > block.timestamp, "Can only lock until time in the future");
        }
        require(unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");

        _deposit_for(msg.sender, _addr, _value, _locked.amount == 0 || unlock_time > _locked.end ? unlock_time : 0, locked[_addr], MANAGE_DEPOSIT_FOR_TYPE);
    }

    /**
     * Deposit `_value` tokens for `msg.sender` and lock until `_unlock_time`
     * @param _value Amount to deposit
     * @param _unlock_time Epoch time when tokens unlock, rounded down to whole weeks
     */
    function create_lock(uint256 _value, uint256 _unlock_time) external nonReentrant {
        assert_not_contract(msg.sender);
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK;    // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "dev: need non-zero value");
        require(_locked.amount == 0, "Withdraw old tokens first");
        require(unlock_time > block.timestamp, "Can only lock until time in the future");
        require(unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");

        _deposit_for(msg.sender, msg.sender, _value, unlock_time, _locked, CREATE_LOCK_TYPE);
    }

    /**
     * Deposit `_value` additional tokens for `msg.sender`
     * without modifying the unlock time
     * @param _value Amount of tokens to deposit and add to the lock
     */
    function increase_amount(uint256 _value) external nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "dev: need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > block.timestamp, "Cannot add to expired lock. Withdraw");

        _deposit_for(msg.sender, msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /**
     * Extend the unlock time for `msg.sender` to `_unlock_time`
     * @param _unlock_time New epoch time for unlocking
     */
    function increase_unlock_time(uint256 _unlock_time) external nonReentrant {
        assert_not_contract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlock_time = (_unlock_time / WEEK) * WEEK;    // Locktime is rounded down to weeks

        require(_locked.end > block.timestamp, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlock_time > _locked.end, "Can only increase lock duration");
        require(unlock_time <= block.timestamp + MAXTIME, "Voting lock can be 4 years max");

        _deposit_for(msg.sender, msg.sender, 0, unlock_time, _locked, INCREASE_UNLOCK_TIME);
    }

    /**
     * Withdraw all tokens for `msg.sender`
     * @dev Only possible if the lock has expired and all boosts cancelled
     */
    function withdraw() external nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        require(block.timestamp >= _locked.end || emergencyUnlockActive, "The lock didn't expire");
        require(delegation_address == address(0) || IVotingEscrowDelegation(delegation_address).total_minted(msg.sender) == 0, "Cancel boosts first");
        uint256 value = safe_uint256(int256(_locked.amount));

        LockedBalance memory old_locked = LockedBalance({amount: _locked.amount, end: _locked.end });
        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 supply_before = supply;
        supply = supply_before - value;

        // old_locked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, old_locked, _locked, 0);

        TransferHelper.safeTransfer(token, msg.sender, value);

        emit Withdraw(msg.sender, value, block.timestamp);
        emit Supply(supply_before, supply_before - value);
    }

    // The following ERC20/minime-compatible methods are not real balanceOf and supply!
    // They measure the weights for the purpose of voting, so they don't represent
    // real coins.
    // FRAX adds minimal 1-1 KROME/veKROME, as well as a voting multiplier

    /**
     * Binary search to estimate timestamp for block number
     * @param _block Block to find
     * @param max_epoch Don't go beyond this epoch
     * @return Approximate timestamp for block
     */
    function find_block_epoch(uint256 _block, uint256 max_epoch) internal view returns(uint256) {
        // Binary search
        uint256 _min = 0;
        uint256 _max = max_epoch;
        for (uint256 i = 0; i < 128; i++) {    // Will be always enough for 128-bit numbers
                if (_min >= _max) {
                        break;
                }
                uint256 _mid = (_min + _max + 1) / 2;
                if (point_history[_mid].blk <= _block) {
                        _min = _mid;
                } else {
                        _max = _mid - 1;
                }
        }
        return _min;
    }

    /**
     * Get the current voting power for `msg.sender`
     * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
     * @param addr User wallet address
     * @param _t Epoch time to return voting power at
     * @return User voting power
     */
    function _balanceOf(address addr, uint256 _t) internal view returns(uint256) {
        uint256 _epoch = user_point_epoch[addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[addr][_epoch];
            last_point.bias -= last_point.slope * int128(uint128(_t - last_point.ts));
            if (last_point.bias < 0) {
                // last_point.bias = 0;
                return 0;
            }

            // return safe_uint256(uint128(last_point.bias)); // Original from veCRV
            uint256 unweighted_supply = uint256(uint128(last_point.bias)); // Original from veCRV
            uint256 weighted_supply = VOTE_WEIGHT_MULTIPLIER * unweighted_supply;
            return weighted_supply;
        }
    }

    function balanceOf(address addr, uint256 _t) external view returns(uint256) {
        return _balanceOf(addr, _t);
    }

    function balanceOf(address addr) external view returns(uint256) {
        return _balanceOf(addr, block.timestamp);
    }

    function lockedKromeOf(address addr) external view returns (uint256) {
        uint256 _epoch = user_point_epoch[addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory last_point = user_point_history[addr][_epoch];
            return last_point.krome_amt;
        }
    }

    /**
     * Measure voting power of `addr` at block height `_block`
     * @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
     * @param addr User's wallet address
     * @param _block Block to calculate the voting power at
     * @return Voting power
     */
    function balanceOfAt(address addr, uint256 _block) external view returns(uint256) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        require(_block <= block.number);

        // Binary search
        uint256 _min = 0;
        uint256 _max = user_point_epoch[addr];
        for (uint256 i = 0; i < 128; i++) {    // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (user_point_history[addr][_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = user_point_history[addr][_min];

        uint256 max_epoch = epoch;
        uint256 _epoch = find_block_epoch(_block, max_epoch);
        Point memory point_0 = point_history[_epoch];
        uint256 d_block = 0;
        uint256 d_t = 0;
        if (_epoch < max_epoch) {
            Point memory point_1 = point_history[_epoch + 1];
            d_block = point_1.blk - point_0.blk;
            d_t = point_1.ts - point_0.ts;
        } else {
            d_block = block.number - point_0.blk;
            d_t = block.timestamp - point_0.ts;
        }
        uint256 block_time = point_0.ts;
        if (d_block != 0) {
            block_time += d_t * (_block - point_0.blk) / d_block;
        }

        upoint.bias -= upoint.slope * int128(uint128(block_time - upoint.ts));

        uint256 unweighted_supply = safe_uint256(int256(upoint.bias)); // Original from veCRV
        uint256 weighted_supply = VOTE_WEIGHT_MULTIPLIER * unweighted_supply;

        if ((upoint.bias >= 0) || (upoint.krome_amt >= 0)) {
            return weighted_supply;
        } else {
            return 0;
        }
    }

    /**
     * Calculate total voting power at some point in the past
     * @param point The point (bias/slope) to start search from
     * @param t Time to calculate the total voting power at
     * @return total - Total voting power at that time, krome amount
     */
    function supply_at(Point memory point, uint256 t) internal view returns (uint256 total) {
        require(t >= point.ts);

        Point memory last_point = point;
        uint256 t_i = (last_point.ts / WEEK) * WEEK;

        for (uint256 i = 0; i < 255; i++) {
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > t) {
                t_i = t;
            } else {
                d_slope = slope_changes[t_i];
            }

            last_point.bias -= last_point.slope * int128(uint128(t_i - last_point.ts));
            if (t_i == t) {
                break;
            }
            last_point.slope += d_slope;
            last_point.ts = t_i;
        }

        if (last_point.bias < 0) {
            // last_point.bias = 0;
            return 0;
        }
        uint256 unweighted_supply = safe_uint256(int256(last_point.bias));    // Original from veCRV
        uint256 weighted_supply = VOTE_WEIGHT_MULTIPLIER * unweighted_supply;
        return weighted_supply;
    }

    /**
     * Calculate total voting power
     * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     * @return total - Total voting power
     */
    function _totalSupply(uint256 t) internal view returns (uint256 total) {
        uint256 _epoch = epoch;
        Point memory last_point = point_history[_epoch];

        total = supply_at(last_point, t);
    }

    function totalSupply(uint256 t) external view returns(uint256) {
        return _totalSupply(t);
    }

    function totalSupply() external view returns(uint256) {
        return _totalSupply(block.timestamp);
    }

    /**
     * Calculate total voting power at some point in the past
     * @param _block Block to calculate the total voting power at
     * @return total - Total voting power at `_block`
     */
    function totalSupplyAt(uint256 _block) external view returns (uint256 total) {
        require(_block <= block.number);
        uint256 _epoch = epoch;
        uint256 target_epoch = find_block_epoch(_block, _epoch);

        Point memory point = point_history[target_epoch];
        uint256 dt = 0;
        if (target_epoch < _epoch) {
            Point memory point_next = point_history[target_epoch + 1];
            if (point.blk != point_next.blk) {
                dt = (_block - point.blk) * (point_next.ts - point.ts) / (point_next.blk - point.blk);
            }
        }
        else {
            if (point.blk != block.number) {
                dt = (_block - point.blk) * (block.timestamp - point.ts) / (block.number - point.blk);
            }
        }
        // Now dt contains info on how far are we beyond point
        total = supply_at(point, point.ts + dt);
    }

    // Dummy methods for compatibility with Aragon
    /**
     * Calculate KROME supply
     * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     * @return Total KROME supply
     */
    function totalKromeSupply() external view returns(uint256) {
        return ERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Calculate total KROME at some point in the past
     * @param _block Block to calculate the total voting power at
     * @return Total KROME supply at `_block`
     */
    function totalKromeSupplyAt(uint256 _block) external view returns(uint256) {
        require(_block <= block.number);
        uint256 _epoch = epoch;
        uint256 target_epoch = find_block_epoch(_block, _epoch);
        Point memory point = point_history[target_epoch];
        return point.krome_amt;
    }

    /**
     * @dev Dummy method required for Aragon compatibility
     */
    function changeController(address _newController) external {
        require(msg.sender == controller);
        controller = _newController;
    }

    function setVotingEscrowDelegation(address _delegation_address) external onlyOwner {
        require(_delegation_address != address(0), "Zero address detected");

        delegation_address = _delegation_address;
    }

    function addTracker(address _voting_escrow_tracker) external onlyOwner {
        voting_escrow_tracker_array.push(_voting_escrow_tracker);
    }

    function removeTracker(address _voting_escrow_tracker) external onlyOwner {
        for (uint i = 0; i < voting_escrow_tracker_array.length; i++) {
            if (voting_escrow_tracker_array[i] == _voting_escrow_tracker) {
                if (i != voting_escrow_tracker_array.length - 1) {
                    voting_escrow_tracker_array[i] = voting_escrow_tracker_array[voting_escrow_tracker_array.length - 1];
                }
                voting_escrow_tracker_array.pop();
                return;
            }
        }
    }

    function safe_uint256(int256 v) internal pure returns (uint256) {
        require (v >= 0);
        return uint256(v);
    }
}