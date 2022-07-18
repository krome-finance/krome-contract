// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ERC20/IERC20.sol";
import "../Libs/TransferHelper.sol";

/**
 * @title TokenVesting
 * @dev A token holder contract that can release its token balance gradually like a
 * typical vesting scheme, with a cliff and vesting period. Optionally revocable by the
 * owner.
 * 
 * Modified from OpenZeppelin's TokenVesting.sol draft
 */
contract TokenVesting {
    // The vesting schedule is time-based (i.e. using block timestamps as opposed to e.g. block numbers), and is
    // therefore sensitive to timestamp manipulation (which is something miners can do, to a certain degree). Therefore,
    // it is recommended to avoid using short time durations (less than a minute). Typical vesting schemes, with a
    // cliff period of a year and a duration of four years, are safe to use.
    // solhint-disable not-rely-on-time

    // using SafeMath for uint256;

    event TokensReleased(uint256 amount);
    event TokenVestingRevoked();

    // beneficiary of tokens after they are released
    address private _beneficiary;

    // owner (grantor) of the tokens
    address private _owner;

    // Durations and timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 private _cliff;
    uint256 private _start;
    uint256 private _duration;

    address public _token_contract_address;
    bool public _revocable;

    uint256 private _released;
    bool public _revoked;

    /**
     * @dev Creates a vesting contract that vests its balance of any ERC20 token to the
     * beneficiary, gradually in a linear fashion until start + duration. By then all
     * of the balance will have vested.
     * @param beneficiary address of the beneficiary to whom vested tokens are transferred
     * @param cliffDuration duration in seconds of the cliff in which tokens will begin to vest
     * @param start the time (as Unix time) at which point vesting starts
     * @param duration duration in seconds of the period in which the tokens will vest
     * @param revocable whether the vesting is revocable or not
     */
    constructor (
        address token_address,
        address beneficiary,
        uint256 start,
        uint256 cliffDuration,
        uint256 duration,
        bool revocable,
        address owner_address
    ) {
        require(beneficiary != address(0), "TokenVesting: beneficiary is the zero address");
        // solhint-disable-next-line max-line-length
        require(cliffDuration <= duration, "TokenVesting: cliff is longer than duration");
        require(duration > 0, "TokenVesting: duration is 0");
        // solhint-disable-next-line max-line-length
        require(start + duration > block.timestamp, "TokenVesting: final time is before current time");

        _token_contract_address = token_address;
        _beneficiary = beneficiary;
        _revocable = revocable;
        _duration = duration;
        _cliff = start + (cliffDuration);
        _start = start;
        _owner = owner_address;
        // _timelock_address = timelock_address;
    }

    /**
     * @return the beneficiary of the tokens.
     */
    function getBeneficiary() public view returns (address) {
        return _beneficiary;
    }

    /**
     * @return the owner of the contract.
     */
    function getOwner() public view returns (address) {
        return _owner;
    }

    // /**
    //  * @return the timelock address of the contract.
    //  */
    // function getTimelock() public view returns (address) {
    //     return _timelock_address;
    // }

    /**
     * @return the cliff time of the token vesting.
     */
    function getCliff() public view returns (uint256) {
        return _cliff;
    }

    /**
     * @return the start time of the token vesting.
     */
    function getStart() public view returns (uint256) {
        return _start;
    }

    /**
     * @return the duration of the token vesting.
     */
    function getDuration() public view returns (uint256) {
        return _duration;
    }

    /**
     * @return true if the vesting is revocable.
     */
    function getRevocable() public view returns (bool) {
        return _revocable;
    }

    /**
     * @return the amount of the token released.
     */
    function getReleased() public view returns (uint256) {
        return _released;
    }

    /**
     * @return true if the token is revoked.
     */
    function getRevoked() public view returns (bool) {
        return _revoked;
    }

    struct Info {
        address token;
        address beneficiary;
        bool revocable;
        bool revoked;

        uint256 start;
        uint256 cliff;
        uint256 duration;

        uint256 total;
        uint256 released;
        uint256 releasable;
    }

    function getInfo() external view returns (Info memory info) {
        info.token = _token_contract_address;
        info.beneficiary = _beneficiary;
        info.revocable = _revocable;
        info.revoked = _revoked;
        info.start = _start;
        info.cliff = _cliff;
        info.duration = _duration;
        info.total = getTotalAmount();
        info.released = _released;
        info.releasable = _releasableAmount();
    }

    /**
     * @return total amount that released and to be released
     */
    function getTotalAmount() public view returns (uint256) {
        uint256 currentBalance = IERC20(_token_contract_address).balanceOf(address(this));
        return currentBalance + _released;
    }

    /**
     * @notice Transfers vested tokens to beneficiary.
     */
    function release() public {
        require(msg.sender == _beneficiary || msg.sender == _owner, "must be the beneficiary or owner to release tokens");
        uint256 unreleased = _releasableAmount();

        require(unreleased > 0, "TokenVesting: no tokens are due");

        _released = _released + (unreleased);

        TransferHelper.safeTransfer(_token_contract_address, _beneficiary, unreleased);

        emit TokensReleased(unreleased);
    }

    /**
     * @notice Allows the owner to revoke the vesting. Tokens already vested
     * remain in the contract, the rest are returned to the owner.
     */
    function revoke() public {
        require(msg.sender == _owner, "Must be called by the owner");
        require(_revocable, "TokenVesting: cannot revoke");
        require(!_revoked, "TokenVesting: token already revoked");

        uint256 balance = IERC20(_token_contract_address).balanceOf(address(this));

        uint256 unreleased = _releasableAmount();
        uint256 refund = balance - (unreleased);

        _revoked = true;

        TransferHelper.safeTransfer(_token_contract_address, _owner, refund);

        emit TokenVestingRevoked();
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external {
        require(msg.sender == _beneficiary || msg.sender == _owner, "Must be called by the beneficiary or owner");

        // Cannot recover the staking token or the rewards token
        require(tokenAddress != _token_contract_address, "Cannot withdraw the token through this function");
        TransferHelper.safeTransfer(tokenAddress, _beneficiary, tokenAmount);
    }


    /**
     * @dev Calculates the amount that has already vested but hasn't been released yet.
     */
    function _releasableAmount() private view returns (uint256) {
        uint256 vested = _vestedAmount();
        if (vested <= _released) {
            return 0;
        } else {
            return _vestedAmount() - _released;
        }
    }

    /**
     * @dev Calculates the amount that has already vested.
     */
    function _vestedAmount() private view returns (uint256) {
        uint256 currentBalance = IERC20(_token_contract_address).balanceOf(address(this));
        uint256 totalBalance = currentBalance + _released;
        if (block.timestamp < _cliff) {
            return 0;
        } else if (block.timestamp >= _start + _duration || _revoked) {
            return totalBalance;
        } else {
            return totalBalance * (block.timestamp - _start) / _duration;
        }
    }

    function deposit(uint256 amount) external {
        TransferHelper.safeTransferFrom(_token_contract_address, msg.sender, address(this), amount);
    }

    function setDuration(uint256 start, uint256 cliffDuration, uint256 duration) external {
        require(msg.sender == _owner, "Must be called by the owner");
        require(cliffDuration <= duration, "TokenVesting: cliff is longer than duration");
        require(duration > 0, "TokenVesting: duration is 0");

        _duration = duration;
        _cliff = start + (cliffDuration);
        _start = start;
    }

    function transferToken(uint256 amount) external {
        require(msg.sender == _owner, "Must be called by the owner");
        TransferHelper.safeTransfer(_token_contract_address, _beneficiary, amount);
    }

    uint256[44] private __gap;
}
