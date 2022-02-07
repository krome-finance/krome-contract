// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common/Context.sol";
import "../Common/Owned.sol";
import "../Common/ReentrancyGuard.sol";
import "../Libs/TransferHelper.sol";
import "./IPresale.sol";

contract PresaleVesting is Context, Owned {
    address public presale_address;
    address public token;
    uint256 internal total_amount;
    uint256 internal total_released;

    mapping(address => uint256) public account_released_amount;

    // Durations and timestamps are expressed in UNIX time, the same units as block.timestamp.
    uint256 public start;
    uint256 public cliffDuration;
    uint256 public duration;

    /* ---------------------- event ------------------------------ */
    event TokenReleased(address account, uint256 amount, uint256 user_released);

    constructor(
        address _presale_address,
        address _token,
        uint256 _start,
        uint256 _cliffDuration,
        uint256 _duration
    ) Owned(_msgSender()) {
        presale_address = _presale_address;
        token = _token;
        total_amount = IPresale(_presale_address).tokenAmount();

        require(_cliffDuration <= _duration, "PresaleVesting: cliff is longer than duration");
        require(_duration > 0, "PresaleVesting: duration is 0");
        // solhint-disable-next-line max-line-length
        require(_start + _duration > block.timestamp, "PresaleVesting: final time is before current time");

        start = _start;
        cliffDuration = _cliffDuration;
        duration = _duration;
    }

    function totalAmount() external view returns(uint256) {
        return total_amount;
    }

    function _vestedAmount() internal view returns(uint256) {
        if (block.timestamp <= start + cliffDuration) {
            return 0;
        } else if (block.timestamp >= start + duration) {
            return total_amount;
        } else {
            return total_amount * (block.timestamp - start) / duration;
        }
    }

    function totalVestedAmount() external view returns(uint256) {
        return _vestedAmount();
    }

    function totalReleasedAmount() external view returns(uint256) {
        return total_released;
    }

    function accountAmount(address _account) external view returns(uint256) {
        IPresale presale = IPresale(presale_address);
        return total_amount * presale.getPurchaseAmount(_account) / presale.getPurchaseLimit();
    }

    function _accountVestedAmount(address _account) internal view returns(uint256) {
        IPresale presale = IPresale(presale_address);
        return _vestedAmount() * presale.getPurchaseAmount(_account) / presale.getPurchaseLimit();
    }

    function accountVestedAmount(address _account) external view returns(uint256) {
        return _accountVestedAmount(_account);
    }

    function releasableAmount(address _account) external view returns(uint256) {
        uint256 _vested = _accountVestedAmount(_account);
        if (_vested <= account_released_amount[_account]) return 0;
        return _vested - account_released_amount[_account];
    }

    /* ----------------- Transaction -------------------- */

    function release() external {
        _release(_msgSender());
    }

    function _release(address _account) internal {
        uint256 _vested = _accountVestedAmount(_account);

        uint256 _released = account_released_amount[_account];
        require(_vested >= _released, "PresaleVesting: over released");
        uint256 _releasable = _vested - _released;

        require(_releasable > 0, "PresaleVesting: Nothing to release");

        account_released_amount[_account] = _vested;
        total_released = total_released + _releasable;

        TransferHelper.safeTransfer(token, _account, _releasable);

        emit TokenReleased(_account, _releasable, _vested);
    }

    /* ----------------- Owner -------------------- */

    function releaseFor(address account) external onlyOwner {
        _release(account);
    }

    function setStart(uint256 _timestamp) external onlyOwner {
        require(start > block.timestamp, "already started");
        start = _timestamp;
    }

    function setDuration(uint256 _duration) external onlyOwner {
        duration = _duration;
    }

    // Added to support recovering possible airdrops
    function recoverERC20(address _token, uint256 amount) external onlyOwner {
        // Cannot recover the staking token or the rewards token
        TransferHelper.safeTransfer(_token, _msgSender(), amount);
    }
}
