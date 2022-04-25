// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IAddressLocator {
    function timelock() external view returns (address);
    function owner_address() external view returns (address);
    function usdk() external view returns (address);
    function krome() external view returns (address);
    function ekl() external view returns (address);
    function eklp_3moon() external view returns (address);
    function eklp_usdk() external view returns (address);
    function eklipse_3moon_swap() external view returns (address);
    function eklipse_usdk_swap() external view returns (address);
    function eklipse_usdk_gauge() external view returns (address);
    function eklipse_lock() external view returns (address);
    function eklipse_vote() external view returns (address);
    function ibkusdt() external view returns (address);
    function kleva_pool() external view returns (address);
}