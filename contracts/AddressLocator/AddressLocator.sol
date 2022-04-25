// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../Common/TimelockOwnedProxy.sol";
import "./IAddressLocator.sol";

contract AddressLocator is TimelockOwnedProxy, IAddressLocator {
    address public override usdk;
    address public override krome;
    address public override ekl;
    address public override eklp_3moon;
    address public override eklp_usdk;
    address public override eklipse_3moon_swap;
    address public override eklipse_usdk_swap;
    address public override eklipse_usdk_gauge;
    address public override eklipse_lock;
    address public override eklipse_vote;
    address public override ibkusdt;
    address public override kleva_pool;

    /* ===================== MODIFIERS ======================= */

    modifier onlyByOwnGov {
        require(msg.sender == timelock_address || msg.sender == owner, "Not owner or timelock");
        _;
    }

    function initialize(
        address _timelock_address,
        address _usdk_address,
        address _krome_address
    ) public initializer {
        TimelockOwnedProxy.initializeTimelockOwned(msg.sender, _timelock_address);

        usdk = _usdk_address;
        krome = _krome_address;
    }

    function timelock() external view override returns (address) {
        return timelock_address;
    }

    function owner_address() external view override returns (address) {
        return owner;
    }

    /* ===================== SETTERS ======================= */
    function setUsdk(address _v) external onlyByOwnGov {
        usdk = _v;
    }
    function setKrome(address _v) external onlyByOwnGov {
        krome = _v;
    }
    function setEKL(address _v) external onlyByOwnGov {
        ekl = _v;
    }
    function setEklp3Moon(address _v) external onlyByOwnGov {
        eklp_3moon = _v;
    }
    function setEklpUsdk(address _v) external onlyByOwnGov {
        eklp_usdk = _v;
    }
    function setEklipse3MoonSwap(address _v) external onlyByOwnGov {
        eklipse_3moon_swap = _v;
    }
    function setEklipseUsdkSwap(address _v) external onlyByOwnGov {
        eklipse_usdk_swap = _v;
    }
    function setEklipseUsdkGauge(address _v) external onlyByOwnGov {
        eklipse_usdk_gauge = _v;
    }
    function setEklipseLock(address _v) external onlyByOwnGov {
        eklipse_lock = _v;
    }
    function setEklipseVote(address _v) external onlyByOwnGov {
        eklipse_vote = _v;
    }
    function setIbKUSDT(address _v) external onlyByOwnGov {
        ibkusdt = _v;
    }
    function setKlevaPool(address _v) external onlyByOwnGov {
        kleva_pool = _v;
    }
}
