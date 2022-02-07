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
// ==================== VotingEscrowDelegation (USDK) ======================
// =========================================================================
// Original idea and credit:
// Curve Finance's veCRV
// https://resources.curve.fi/guides/boosting-your-crv-rewards
// https://github.com/curvefi/curve-veBoost/blob/master/contracts/VotingEscrowDelegation.vy
// this is a solidity clone
// the key difference is that boost decrease like veKROME (to 1 not to 0)
// it remains 1 for 1 veKROME after expiration until cancelation
//

import "../../Common/Owned.sol";
import "../../Math/Math.sol";
import "../../Libs/Address.sol";

interface ERC721Receiver {
    function onERC721Received(address _operator, address _from, uint256 _token_id, bytes memory _data) external returns(bytes32);
}

interface VotingEscrow {
    function balanceOf(address _account) external view returns (uint256);
    function lockedKromeOf(address _account) external view returns (uint256);
    function locked__end(address _addr) external view returns (uint256);
}

contract VotingEscrowDelegation is Owned {
    event Approval(address indexed _owner, address indexed _approved, uint256 indexed _token_id);
    event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);
    event Transfer(address indexed _from, address indexed _to, uint256 indexed _token_id);
    event BurnBoost(address indexed _delegator, address indexed _receiver, uint256 indexed _token_id);
    event DelegateBoost(
        address indexed _delegator,
        address indexed _receiver,
        uint256 indexed _token_id,
        uint256 _amount,
        uint256 _cancel_time,
        uint256 _expire_time
    );
    event ExtendBoost(
        address indexed _delegator,
        address indexed _receiver,
        uint256 indexed _token_id,
        uint256 _amount,
        uint256 _expire_time,
        uint256 _cancel_time
    );
    event TransferBoost(
        address indexed _from,
        address indexed _to,
        uint256 indexed _token_id,
        uint256 _amount,
        uint256 _expire_time
    );
    event GreyListUpdated(address indexed _receiver, address indexed _delegator, bool _status);

    struct Boost {
        // [bias uint128][slope int128]
        uint256 delegated;
        uint256 received;
        // [total active delegations 128][next expiry 128]
        uint256 expiry_data;
    }

    struct Token {
        // [bias uint128][slope int128]
        uint256 data;
        // [delegator pos 128][cancel time 128]
        uint256 dinfo;
        // [global 128][local 128]
        uint256 position;
        uint256 expire_time;
    }

    struct Point {
        int256 bias;
        int256 slope;
    }

    struct MintParam {
        address delegator;
        address receiver;
        int256 percentage;
        uint256 token_id;
        uint256 expire_time;
        uint256 cancel_time;
        int256 org_tvalue;
    }

    address constant IDENTITY_PRECOMPILE = 0x0000000000000000000000000000000000000004;
    uint256 constant MAX_PCT = 10_000;
    uint256 constant WEEK = 86400 * 7;
    address immutable VOTING_ESCROW;
    // bool immutable TEST_ENABLED;

    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public ownerOf;

    string public name;
    string public symbol;
    string public base_uri;

    uint256 public totalSupply;
    // use totalSupply to determine the length
    mapping(uint256 => uint256) public tokenByIndex;
    // use balanceOf to determine the length
    mapping(address => mapping(uint256 => uint256)) public tokenOfOwnerByIndex;

    mapping(address => Boost) public boost;
    mapping(uint256 => Token) public boost_tokens;

    mapping(address => mapping(uint256 => uint256)) public token_of_delegator_by_index;
    mapping(address => uint256) public total_minted;
    // address => timestamp => # of delegations expiring
    mapping(address => mapping(uint256 => uint256)) public account_expiries;

    // The grey list - per-user black and white lists
    // users can make this a blacklist or a whitelist - defaults to blacklist
    // gray_list[_receiver][_delegator]
    // by default is blacklist, with no delegators blacklisted
    // if [_receiver][ZERO_ADDRESS] is False = Blacklist, True = Whitelist
    // if this is a blacklist, receivers disallow any delegations from _delegator if it is True
    // if this is a whitelist, receivers only allow delegations from _delegator if it is True
    // Delegation will go through if: not (grey_list[_receiver][ZERO_ADDRESS] ^ grey_list[_receiver][_delegator])
    mapping(address => mapping(address => bool)) public grey_list;

    constructor(address _voting_escrow, string memory _name, string memory _symbol, string memory _base_uri) Owned(msg.sender) {
        VOTING_ESCROW = _voting_escrow;
        name = _name;
        symbol = _symbol;
        base_uri = _base_uri;
        // TEST_ENABLED = for_test;
    }

    function _approve(address _owner, address _approved, uint256 _token_id) internal {
        getApproved[_token_id] = _approved;
        emit Approval(_owner, _approved, _token_id);
    }

    function _is_approved_or_owner(address _spender, uint256 _token_id) internal view returns(bool) {
        address _owner = ownerOf[_token_id];
        return (
            _spender == _owner
            || _spender == getApproved[_token_id]
            || isApprovedForAll[_owner][_spender]
        );
    }

    function _update_enumeration_data(address _from, address _to, uint256 _token_id) internal {
        address delegator = address(uint160(_token_id >> 96));
        uint256 position_data = boost_tokens[_token_id].position;
        uint256 local_pos = position_data % 2 ** 128;
        uint256 global_pos = position_data >> 128;
        // position in the delegator array of minted tokens
        uint256 delegator_pos = boost_tokens[_token_id].dinfo >> 128;

        if (_from == address(0)) {
            // minting - This is called before updates to balance and totalSupply
            local_pos = balanceOf[_to];
            global_pos = totalSupply;
            position_data = (global_pos << 128) + local_pos;
            // this is a new token so we get the index of a new spot
            delegator_pos = total_minted[delegator];

            tokenByIndex[global_pos] = _token_id;
            tokenOfOwnerByIndex[_to][local_pos] = _token_id;
            boost_tokens[_token_id].position = position_data;

            // we only mint tokens in the create_boost fn, and this is called
            // before we update the cancel_time so we can just set the value
            // of dinfo to the shifted position
            boost_tokens[_token_id].dinfo = delegator_pos << 128;
            token_of_delegator_by_index[delegator][delegator_pos] = _token_id;
            total_minted[delegator] = delegator_pos + 1;
        } else if (_to == address(0)) {
            // burning - This is called after updates to balance and totalSupply
            // we operate on both the global array and local array
            uint256 last_global_index = totalSupply;
            uint256 last_local_index = balanceOf[_from];
            uint256 last_delegator_pos = total_minted[delegator] - 1;

            if (global_pos != last_global_index) {
            // swap - set the token we're burnings position to the token in the last index
            uint256 last_global_token = tokenByIndex[last_global_index];
            uint256 last_global_token_pos = boost_tokens[last_global_token].position;
            // update the global position of the last global token
            boost_tokens[last_global_token].position = (global_pos << 128) + (last_global_token_pos % 2 ** 128);
            tokenByIndex[global_pos] = last_global_token;
            }
            tokenByIndex[last_global_index] = 0;

            if (local_pos != last_local_index) {
            // swap - set the token we're burnings position to the token in the last index
            uint256 last_local_token = tokenOfOwnerByIndex[_from][last_local_index];
            uint256 last_local_token_pos = boost_tokens[last_local_token].position;
            // update the local position of the last local token
            boost_tokens[last_local_token].position = (last_local_token_pos / 2 ** 128 << 128) + local_pos;
            tokenOfOwnerByIndex[_from][local_pos] = last_local_token;
            }
            tokenOfOwnerByIndex[_from][last_local_index] = 0;
            boost_tokens[_token_id].position = 0;

            if (delegator_pos != last_delegator_pos) {
            uint256 last_delegator_token = token_of_delegator_by_index[delegator][last_delegator_pos];
            uint256 last_delegator_token_dinfo = boost_tokens[last_delegator_token].dinfo;
            // update the last tokens position data and maintain the correct cancel time
            boost_tokens[last_delegator_token].dinfo = (delegator_pos << 128) + (last_delegator_token_dinfo % 2 ** 128);
            token_of_delegator_by_index[delegator][delegator_pos] = last_delegator_token;
            }
            token_of_delegator_by_index[delegator][last_delegator_pos] = 0;
            boost_tokens[_token_id].dinfo = 0;  // we are burning the token so we can just set to 0
            total_minted[delegator] = last_delegator_pos;
        } else {
            // transfering - called between balance updates
            uint256 from_last_index = balanceOf[_from];

            if (local_pos != from_last_index) {
            // swap - set the token we're burnings position to the token in the last index
            uint256 last_local_token = tokenOfOwnerByIndex[_from][from_last_index];
            uint256 last_local_token_pos = boost_tokens[last_local_token].position;
            // update the local position of the last local token
            boost_tokens[last_local_token].position = (last_local_token_pos / 2 ** 128 << 128) + local_pos;
            tokenOfOwnerByIndex[_from][local_pos] = last_local_token;
            }
            tokenOfOwnerByIndex[_from][from_last_index] = 0;

            // to is simple we just add to the end of the list
            local_pos = balanceOf[_to];
            tokenOfOwnerByIndex[_to][local_pos] = _token_id;
            boost_tokens[_token_id].position = (global_pos << 128) + local_pos;
        }
    }

    function _burn(uint256 _token_id) internal {
        address _owner = ownerOf[_token_id];

        _approve(_owner, address(0), _token_id);

        balanceOf[_owner] -= 1;
        ownerOf[_token_id] = address(0);
        totalSupply -= 1;

        _update_enumeration_data(_owner, address(0), _token_id);

        emit Transfer(_owner, address(0), _token_id);
    }

    function _mint(address _to, uint256 _token_id) internal {
        require(_to != address(0), "dev: minting to ZERO_ADDRESS disallowed");
        require(ownerOf[_token_id] == address(0), "dev: token exists");

        _update_enumeration_data(address(0), _to, _token_id);

        balanceOf[_to] += 1;
        ownerOf[_token_id] = _to;
        totalSupply += 1;

        emit Transfer(address(0), _to, _token_id);
    }

    function abs(int x) private pure returns (int) {
        return x >= 0 ? x : -x;
    }

    function _mint_boost(uint256 _token_id, address _delegator, address _receiver, int256 _bias, int256 _slope, uint256 _cancel_time, uint256 _expire_time) internal {
        uint256 is_whitelist = grey_list[_receiver][address(0)] ? 1 : 0;
        uint256 delegator_status = grey_list[_receiver][_delegator] ? 1 : 0;
        require(is_whitelist ^ delegator_status == 0, "dev: mint boost not allowed");

        uint256 data = (safe_uint256(_bias) << 128) + safe_uint256(abs(_slope));
        boost[_delegator].delegated += data;
        boost[_receiver].received += data;

        Token memory token = boost_tokens[_token_id];
        token.data = data;
        token.dinfo = token.dinfo + _cancel_time;
        token.expire_time = _expire_time;
        boost_tokens[_token_id] = token;
    }

    function _burn_boost(uint256 _token_id, address _delegator, address _receiver /*, int256 _bias, int256 _slope, int256 _base */) internal {
        Token memory token = boost_tokens[_token_id];
        uint256 expire_time = token.expire_time;

        if (expire_time == 0) {
            return;
        }

        boost[_delegator].delegated -= token.data;
        boost[_receiver].received -= token.data;

        token.data = 0;
        // maintain the same position in the delegator array, but remove the cancel time
        token.dinfo = token.dinfo / 2 ** 128 << 128;
        token.expire_time = 0;
        boost_tokens[_token_id] = token;

        // update the next expiry data
        uint256 expiry_data = boost[_delegator].expiry_data;
        uint256 next_expiry = expiry_data % 2 ** 128;
        uint256 active_delegations = (expiry_data >> 128) - 1;

        uint256 expiries = account_expiries[_delegator][expire_time];

        if (active_delegations != 0 && expire_time == next_expiry && expiries == 0) {
            // Will be passed if
            // active_delegations == 0, no more active boost tokens
            // or
            // expire_time != next_expiry, the cancelled boost token isn't the next expiring boost token
            // or
            // expiries != 0, the cancelled boost token isn't the only one expiring at expire_time
            for (uint256 i = 1; i < 513; i++) {  // ~10 years
                // we essentially allow for a boost token be expired for up to 6 years
                // 10 yrs - 4 yrs (max vecRV lock time) = ~ 6 yrs
                if (i == 512) {
                    revert("Failed to find next expiry");
                }
                uint256 week_ts = expire_time + WEEK * (i + 1);
                if (account_expiries[_delegator][week_ts] > 0) {
                    next_expiry = week_ts;
                    break;
                }
            }
        } else if (active_delegations == 0) {
            next_expiry = 0;
        }

        boost[_delegator].expiry_data = (active_delegations << 128) + next_expiry;
        account_expiries[_delegator][expire_time] = expiries - 1;
    }

    function _transfer_boost(address _from, address _to, int256 _bias, int256 _slope) internal {
        uint256 data = (safe_uint256(_bias) << 128) + safe_uint256(abs(_slope));
        boost[_from].received -= data;
        boost[_to].received += data;
    }

    function _deconstruct_bias_slope(uint256 _data) internal pure returns(Point memory) {
        return Point({bias: int256(_data >> 128), slope: -int256(_data % 2 ** 128)});
    }

    function _calc_bias_slope(int256 _x, int256 _y, int256 _expire_time) internal pure returns(Point memory) {
        // SLOPE: (y2 - y1) / (x2 - x1)
        // BIAS: y = mx + b -> y - mx = b
        int256 slope = -_y / (_expire_time - _x);
        return Point({bias: _y - slope * _x, slope: slope});
    }

    function _transfer(address _from, address _to, uint256 _token_id) internal {
        require(ownerOf[_token_id] == _from, "dev: _from is not owner");
        require(_to != address(0), "dev: transfers to ZERO_ADDRESS are disallowed");

        address delegator = address(uint160(_token_id >> 96));
        uint256 is_whitelist = grey_list[_to][address(0)] ? 1 : 0;
        uint256 delegator_status = grey_list[_to][delegator] ? 1 : 0;
        require((is_whitelist ^ delegator_status) == 0, "dev: transfer boost not allowed");

        // clear previous token approval
        _approve(_from, address(0), _token_id);

        balanceOf[_from] -= 1;
        _update_enumeration_data(_from, _to, _token_id);
        balanceOf[_to] += 1;
        ownerOf[_token_id] = _to;

        Point memory tpoint = _deconstruct_bias_slope(boost_tokens[_token_id].data);
        int256 tvalue = tpoint.slope * int256(block.timestamp) + tpoint.bias;

        // if the boost value is negative, reset the slope and bias
        if (tvalue > 0) {
            _transfer_boost(_from, _to, tpoint.bias, tpoint.slope);
            // y = mx + b -> y - b = mx -> (y - b)/m = x -> -b / m = x (x-intercept)
            uint256 expiry = safe_uint256(-tpoint.bias / tpoint.slope);
            emit TransferBoost(_from, _to, _token_id, safe_uint256(tvalue), expiry);
        } else {
            _burn_boost(_token_id, delegator, _from/*, tpoint.bias, tpoint.slope, base */);
            emit BurnBoost(delegator, _from, _token_id);
        }

        emit Transfer(_from, _to, _token_id);
    }

    function _cancel_boost(uint256 _token_id, address _caller) internal {
        address receiver = ownerOf[_token_id];
        require(receiver != address(0), "dev: token does not exist");
        address delegator = address(uint160(_token_id >> 96));

        Token memory token = boost_tokens[_token_id];
        Point memory tpoint = _deconstruct_bias_slope(token.data);
        int256 tvalue = tpoint.slope * int256(block.timestamp) + tpoint.bias;

        // if not (the owner or operator or the boost value is negative)
        if (!(_caller == receiver || isApprovedForAll[receiver][_caller] || tvalue <= 0)) {
            if (_caller == delegator || isApprovedForAll[delegator][_caller]) {
                // if delegator or operator, wait till after cancel time
                require((token.dinfo % 2 ** 128) <= block.timestamp, "dev: must wait for cancel time");
            } else {
                // All others are disallowed
                revert("Not allowed!");
            }
        }
        _burn_boost(_token_id, delegator, receiver/*, tpoint.bias, tpoint.slope, token.base */);

        emit BurnBoost(delegator, receiver, _token_id);
    }

    function _set_delegation_status(address _receiver, address _delegator, bool _status) internal {
        grey_list[_receiver][_delegator] = _status;
        emit GreyListUpdated(_receiver, _delegator, _status);
    }

    function _uint_to_string(uint256 _value) internal pure returns(string memory) {
        // Inspired by OraclizeAPI's implementation - MIT licence
        // https://github.com/oraclize/ethereum-api/blob/b42146b063c7d6ee1358846c198246239e9360e8/oraclizeAPI_0.4.25.sol

        if (_value == 0) {
            return "0";
        }
        uint256 temp = _value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (_value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(_value % 10)));
            _value /= 10;
        }
        return string(buffer);
    }

    /**
    * Change or reaffirm the approved address for an NFT.
    * @dev The zero address indicates there is no approved address.
    *     Throws unless `msg.sender` is the current NFT owner, or an authorized
    *     operator of the current owner.
    * @param _approved The new approved NFT controller.
    * @param _token_id The NFT to approve.
    */
    function approve(address _approved, uint256 _token_id) external {
        address _owner = ownerOf[_token_id];
        require(
            msg.sender == _owner || isApprovedForAll[_owner][msg.sender],
            "dev: must be owner or operator");
        _approve(_owner, _approved, _token_id);
    }

    function _safeTransferFrom(address _from, address _to, uint256 _token_id, bytes memory _data) internal {
        _transfer(_from, _to, _token_id);

        if (Address.isContract(_to)) {
            bytes32 response = ERC721Receiver(_to).onERC721Received(
            msg.sender, _from, _token_id, _data
            );
            require(bytes4(response) == bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")), "dev: invalid response");
        }
    }

    /**
    * Transfers the ownership of an NFT from one address to another address
    * @dev Throws unless `msg.sender` is the current owner, an authorized
    *     operator, or the approved address for this NFT. Throws if `_from` is
    *     not the current owner. Throws if `_to` is the zero address. Throws if
    *     `_tokenId` is not a valid NFT. When transfer is complete, this function
    *     checks if `_to` is a smart contract (code size > 0). If so, it calls
    *     `onERC721Received` on `_to` and throws if the return value is not
    *     `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`.
    * @param _from The current owner of the NFT
    * @param _to The new owner
    * @param _token_id The NFT to transfer
    * @param _data Additional data with no specified format, sent in call to `_to`, max length 4096
    */
    function safeTransferFrom(address _from, address _to, uint256 _token_id, bytes memory _data) external {
        _safeTransferFrom(_from, _to, _token_id, _data);
    }

    function safeTransferFrom(address _from, address _to, uint256 _token_id) external {
        _safeTransferFrom(_from, _to, _token_id, hex"");
    }

    /**
    * Enable or disable approval for a third party ("operator") to manage
    *     all of `msg.sender`'s assets.
    * @dev Emits the ApprovalForAll event. Multiple operators per account are allowed.
    * @param _operator Address to add to the set of authorized operators.
    * @param _approved True if the operator is approved, false to revoke approval.
    */
    function setApprovalForAll(address _operator, bool _approved) external {
        isApprovedForAll[msg.sender][_operator] = _approved;
        emit ApprovalForAll(msg.sender, _operator, _approved);
    }

    /**
    * Transfer ownership of an NFT -- THE CALLER IS RESPONSIBLE
    *     TO CONFIRM THAT `_to` IS CAPABLE OF RECEIVING NFTS OR ELSE
    *     THEY MAY BE PERMANENTLY LOST
    * @dev Throws unless `msg.sender` is the current owner, an authorized
    *     operator, or the approved address for this NFT. Throws if `_from` is
    *     not the current owner. Throws if `_to` is the ZERO_ADDRESS.
    * @param _from The current owner of the NFT
    * @param _to The new owner
    * @param _token_id The NFT to transfer
    */
    function transferFrom(address _from, address _to, uint256 _token_id) external {
        require(_is_approved_or_owner(msg.sender, _token_id), "dev: neither owner nor approved");
        _transfer(_from, _to, _token_id);
    }

    function tokenURI(uint256 _token_id) external view returns(string memory) {
        return string(abi.encodePacked(base_uri, _uint_to_string(_token_id)));
    }

    /**
    * Destroy a token
    * @dev Only callable by the token owner, their operator, or an approved account.
    *     Burning a token with a currently active boost, burns the boost.
    * @param _token_id The token to burn
    */
    function burn(uint256 _token_id) external {
        require(_is_approved_or_owner(msg.sender, _token_id), "dev: neither owner nor approved");

        uint256 tdata = boost_tokens[_token_id].data;
        if (tdata != 0) {
            // Point memory tpoint = _deconstruct_bias_slope(tdata);

            address delegator = address(uint160(_token_id >> 96));
            address _owner = ownerOf[_token_id];

            _burn_boost(_token_id, delegator, _owner/*, tpoint.bias, tpoint.slope, boost_tokens[_token_id].base */);

            emit BurnBoost(delegator, _owner, _token_id);
        }

        _burn(_token_id);
    }

    // function _mint_for_testing(address _to, uint256 _token_id) external {
    //   require(TEST_ENABLED);
    //   _mint(_to, _token_id);
    // }

    // function _burn_for_testing(uint256 _token_id) external {
    //   require(TEST_ENABLED);
    //   _burn(_token_id);
    // }

    // function uint_to_string(uint256 _value) external pure returns(string memory) {
    //   // require(TEST_ENABLED);
    //   return _uint_to_string(_value);
    // }

    function _mint_boost_wrapper(
        MintParam memory param
    ) internal returns (int256 y, Point memory point) {
        Point memory _point = _deconstruct_bias_slope(boost[param.delegator].delegated);

        // int256 time = int256(block.timestamp);

        int256 _delegated_boost = _point.slope * int256(block.timestamp) + _point.bias;

        // delegated boost will be positive, if any of circulating boosts are negative
        // we have already reverted
        // int256 _delegated_boost = point.slope * time + point.bias;
        // y = _percentage * (VotingEscrow(VOTING_ESCROW).balanceOf(_delegator) - _delegated_boost) / int256(MAX_PCT);
        y = param.percentage * (int256(VotingEscrow(VOTING_ESCROW).balanceOf(param.delegator)) - _delegated_boost) / int256(MAX_PCT);
        require(y > 0, "dev: no boost");
        require(y >= param.org_tvalue, "dev: cannot reduce value of boost");

        point = _calc_bias_slope(int256(block.timestamp), y, int256(param.expire_time));
        // console.log(VotingEscrow(VOTING_ESCROW).balanceOf(param.delegator), uint256(y), uint256(_base), uint256(_delegated_boost));
        // console.logInt(point.slope);
        // console.logInt(point.bias);
    
        require(point.slope < 0, "dev: invalid slope");

        _mint_boost(param.token_id, param.delegator, param.receiver, point.bias, point.slope, param.cancel_time, param.expire_time);
    }

    /**
    * Create a boost and delegate it to another account.
    * @dev Delegated boost can become negative, and requires active management, else
    *     the adjusted veCRV balance of the delegator's account will decrease until reaching 0
    * @param _delegator The account to delegate boost from
    * @param _receiver The account to receive the delegated boost
    * @param _percentage Since veCRV is a constantly decreasing asset, we use percentage to determine
    *     the amount of delegator's boost to delegate
    * @param _cancel_time A point in time before _expire_time in which the delegator or their operator
    *     can cancel the delegated boost
    * @param _expire_time The point in time, atleast a day in the future, at which the value of the boost
    *     will reach 0. After which the negative value is deducted from the delegator's account (and the
    *     receiver's received boost only) until it is cancelled. This value is rounded down to the nearest
    *     WEEK.
    * @param _id The token id, within the range of [0, 2 ** 96). Useful for contracts given operator status
    *     to have specific ranges.
    */
    function create_boost(
        address _delegator,
        address _receiver,
        int256 _percentage,
        uint256 _cancel_time,
        uint256 _expire_time,
        uint256 _id
    ) external {
        require(msg.sender == _delegator || isApprovedForAll[_delegator][msg.sender], "dev: only delegator or operator");

        // Stack too deep
        MintParam memory param;
        param.delegator = _delegator;
        param.receiver = _receiver;
        param.percentage = _percentage;
        param.token_id = (uint256(uint160(_delegator)) << 96) + _id;
        param.expire_time = (_expire_time / WEEK) * WEEK;
        param.cancel_time = _cancel_time;

        uint256 expiry_data = boost[_delegator].expiry_data;
        uint256 next_expiry = expiry_data % 2 ** 128;

        if (next_expiry == 0) {
            next_expiry = type(uint256).max;
        }

        require(block.timestamp < next_expiry, "dev: negative boost token is in circulation");
        require(_percentage > 0, "dev: percentage must be greater than 0 bps");
        require(_percentage <= int256(MAX_PCT), "dev: percentage must be less than 10,000 bps");
        require(_cancel_time <= param.expire_time, "dev: cancel time is after expiry");

        require(param.expire_time >= block.timestamp + WEEK, "dev: boost duration must be atleast WEEK");
        require(param.expire_time <= VotingEscrow(VOTING_ESCROW).locked__end(_delegator),
            "dev: boost expiration is past voting escrow lock expiry");
        require(_id < 2 ** 96, "dev: id out of bounds");

        // [delegator address 160][cancel_time uint40][id uint56]
        uint256 token_id = (uint256(uint160(_delegator)) << 96) + _id;
        // check if the token exists here before we expend more gas by minting it
        _mint(_receiver, token_id);

        // delegated slope and bias
        Point memory point;

        int256 y;
        (y, point) = _mint_boost_wrapper(param);
        // {
        //   // delegated slope and bias
        //   Point memory point = _deconstruct_bias_slope(boost[_delegator].delegated);

        //   // int256 time = int256(block.timestamp);

        //   // delegated boost will be positive, if any of circulating boosts are negative
        //   // we have already reverted
        //   // int256 _delegated_boost = point.slope * time + point.bias;
        //   // y = _percentage * (VotingEscrow(VOTING_ESCROW).balanceOf(_delegator) - _delegated_boost) / int256(MAX_PCT);
        //   y = _percentage * (VotingEscrow(VOTING_ESCROW).balanceOf(_delegator) - (point.slope * int256(block.timestamp) + point.bias)) / int256(MAX_PCT);
        //   require(y > 0, "dev: no boost");

        //   point = _calc_bias_slope(int256(block.timestamp), y, int256(expire_time), int256(VotingEscrow(VOTING_ESCROW).balaceBaseOf(_delegator)));
        //   require(point.slope < 0, "dev: invalid slope");

        //   _mint_boost(token_id, _delegator, _receiver, point.bias, point.slope, _cancel_time, expire_time);
        // }

        // increase the number of expiries for the user
        if (param.expire_time < next_expiry) {
            next_expiry = param.expire_time;
        }

        uint256 active_delegations = (expiry_data >> 128);
        account_expiries[_delegator][param.expire_time] += 1;
        boost[_delegator].expiry_data = (active_delegations + 1 << 128) + next_expiry;

      emit DelegateBoost(_delegator, _receiver, token_id, safe_uint256(y), _cancel_time, _expire_time);
    }

    /**
    * Extend the boost of an existing boost or expired boost
    * @dev The extension can not decrease the value of the boost. If there are
    *     any expired outstanding negative value boosts which cause the delegable boost
    *     of an account to be negative this call will revert
    * @param _token_id The token to extend the boost of
    * @param _percentage The percentage of delegable boost to delegate
    *     AFTER burning the token's current boost
    * @param _expire_time The new time at which the boost value will become
    *     0, and eventually negative. Must be greater than the previous expiry time,
    *     and atleast a WEEK from now, and less than the veCRV lock expiry of the
    *     delegator's account. This value is rounded down to the nearest WEEK.
    */
    function extend_boost(uint256 _token_id, int256 _percentage, uint256 _expire_time, uint256 _cancel_time) external {
        // avoid Stack too deep
        MintParam memory param;
        param.delegator = address(uint160(_token_id >> 96));
        param.receiver = ownerOf[_token_id];
        param.percentage = _percentage;
        param.token_id = _token_id;
        param.expire_time = (_expire_time / WEEK) * WEEK;
        param.cancel_time = _cancel_time;

        require(msg.sender == param.delegator || isApprovedForAll[param.delegator][msg.sender], "dev: only delegator or operator");
        require(param.receiver != address(0), "dev: boost token does not exist");
        require(_percentage > 0, "dev: percentage must be greater than 0 bps");
        require(_percentage <= int256(MAX_PCT), "dev: percentage must be less than 10,000 bps");

        // timestamp when delegating account's voting escrow ends - also our second point (lock_expiry, 0)
        Token memory token = boost_tokens[_token_id];

        require(_cancel_time <= param.expire_time, "dev: cancel time is after expiry");
        require(param.expire_time >= block.timestamp + WEEK, "dev: boost duration must be atleast one day");
        require(param.expire_time <= VotingEscrow(VOTING_ESCROW).locked__end(param.delegator), "dev: boost expiration is past voting escrow lock expiry");

        Point memory point = _deconstruct_bias_slope(token.data);

        // int256 time = int256(block.timestamp);
        // int256 tvalue = point.slope * time + point.bias;
        param.org_tvalue = point.slope * int256(block.timestamp) + point.bias;

        // Can extend a token by increasing it's amount but not it's expiry time
        require(param.expire_time >= token.expire_time, "dev: new expiration must be greater than old token expiry");

        // if we are extending an unexpired boost, the cancel time must the same or greater
        // else we can adjust the cancel time to our preference
        if (_cancel_time < (token.dinfo % 2 ** 128)) {
            require(block.timestamp >= token.expire_time, "dev: cancel time reduction disallowed");
        }

        // storage variables have been updated: next_expiry + active_delegations
        _burn_boost(_token_id, param.delegator, param.receiver/*, point.bias, point.slope */);

        uint256 expiry_data = boost[param.delegator].expiry_data;
        uint256 next_expiry = expiry_data % 2 ** 128;

        if (next_expiry == 0) {
            next_expiry = type(uint256).max;
        }

        require(block.timestamp < next_expiry, "dev: negative outstanding boosts");

        // delegated slope and bias
        // point = _deconstruct_bias_slope(boost[param.delegator].delegated);

        int256 y;
        (y, point) = _mint_boost_wrapper(param);
        // {
        //   // int256 time = int256(block.timestamp);
        //   // verify delegated boost isn't negative, else it'll inflate out vecrv balance
        //   int256 _delegated_boost = point.slope * int256(block.timestamp) + point.bias;
        //   y = _percentage * (VotingEscrow(VOTING_ESCROW).balanceOf(delegator) - _delegated_boost) / int256(MAX_PCT);
        //   // a delegator can snipe the exact moment a token expires and create a boost
        //   // with 10_000 or some percentage of their boost, which is perfectly fine.
        //   // this check is here so the user can't extend a boost unless they actually
        //   // have any to give
        //   require(y > 0, "dev: no boost");
        //   require(y >= tvalue, "dev: cannot reduce value of boost");
        //   // require(y >= point.slope * int256(block.timestamp) + point.bias, "dev: cannot reduce value of boost");

        //   int256 l = _percentage * int256(VotingEscrow(VOTING_ESCROW).balaceBaseOf(delegator)) / int256(MAX_PCT);
        //   point = _calc_bias_slope(int256(block.timestamp), y, int256(expire_time), l);
        //   require(point.slope < 0, "dev: invalid slope");

        //   _mint_boost(_token_id, delegator, receiver, point.bias, point.slope, _cancel_time, expire_time);
        // }

        // increase the number of expiries for the user
        if (param.expire_time < next_expiry) {
            next_expiry = param.expire_time;
        }

        uint256 active_delegations = (expiry_data >> 128);
        account_expiries[param.delegator][param.expire_time] += 1;
        boost[param.delegator].expiry_data = (active_delegations + 1 << 128) + next_expiry;

        emit ExtendBoost(param.delegator, param.receiver, _token_id, safe_uint256(y), param.expire_time, _cancel_time);
    }

    /**
    * Cancel an outstanding boost
    * @dev This does not burn the token, only the boost it represents. The owner
    *     of the token or their operator can cancel a boost at any time. The
    *     delegator or their operator can only cancel a token after the cancel
    *     time. Anyone can cancel the boost if the value of it is negative.
    * @param _token_id The token to cancel
    */
    function cancel_boost(uint256 _token_id) external {
        _cancel_boost(_token_id, msg.sender);
    }

    /**
    * Cancel many outstanding boosts
    * @dev This does not burn the token, only the boost it represents. The owner
    *     of the token or their operator can cancel a boost at any time. The
    *     delegator or their operator can only cancel a token after the cancel
    *     time. Anyone can cancel the boost if the value of it is negative.
    * @param _token_ids A list of 256 token ids to nullify. The list must
    *     be padded with 0 values if less than 256 token ids are provided.
    */
    function batch_cancel_boosts(uint256[] memory _token_ids) external {
        for (uint i = 0; i < _token_ids.length; i++) {
            if (_token_ids[i] == 0) {
                break;
            }
            _cancel_boost(_token_ids[i], msg.sender);
        }
    }

    function cancel_all_boosts_of(address _delegator) external {
        while (total_minted[_delegator] > 0) {
            if (token_of_delegator_by_index[_delegator][0] == 0) {
            break;
            }
            _cancel_boost(token_of_delegator_by_index[_delegator][0], msg.sender);
        }
    }

    /**
    * Set or reaffirm the blacklist/whitelist status of a delegator for a receiver.
    * @dev Setting delegator as the ZERO_ADDRESS enables users to deactive delegations globally
    *     and enable the white list. The ability of a delegator to delegate to a receiver
    *     is determined by ~(grey_list[_receiver][ZERO_ADDRESS] ^ grey_list[_receiver][_delegator]).
    * @param _receiver The account which we will be updating it's list
    * @param _delegator The account to disallow/allow delegations from
    * @param _status Boolean of the status to set the _delegator account to
    */
    function set_delegation_status(address _receiver, address _delegator, bool _status) external {
        require(msg.sender == _receiver || isApprovedForAll[_receiver][msg.sender]);
        _set_delegation_status(_receiver, _delegator, _status);
    }

    /**
    * Set or reaffirm the blacklist/whitelist status of multiple delegators for a receiver.
    * @dev Setting delegator as the ZERO_ADDRESS enables users to deactive delegations globally
    *     and enable the white list. The ability of a delegator to delegate to a receiver
    *     is determined by ~(grey_list[_receiver][ZERO_ADDRESS] ^ grey_list[_receiver][_delegator]).
    * @param _receiver The account which we will be updating it's list
    * @param _delegators List of 256 accounts to disallow/allow delegations from
    * @param _status List of 256 0s and 1s (booleans) of the status to set the _delegator_i account to.
    *     if the value is not 0 or 1, execution will break, effectively stopping at the index.
    */
    function batch_set_delegation_status(address _receiver, address[] memory _delegators, uint256[] memory _status) external {
        require(msg.sender == _receiver || isApprovedForAll[_receiver][msg.sender], "dev: only receiver or operator");

        for (uint i = 0; i < _status.length; i++) {
            if (_status[i] > 1) {
            break;
            }
            _set_delegation_status(_receiver, _delegators[i], _status[i] != 0);
        }
    }

    /**
    * Adjusted veCRV balance after accounting for delegations and boosts
    * @dev If boosts/delegations have a negative value, they're effective value is 0
    * @param _account The account to query the adjusted balance of
    */
    function adjusted_balance_of(address _account) external view returns(uint256) {
        uint256 next_expiry = boost[_account].expiry_data % 2 ** 128;
        if (next_expiry != 0 && next_expiry < block.timestamp) {
            // if the account has a negative boost in circulation
            // we over penalize by setting their adjusted balance to 0
            // this is because we don't want to iterate to find the real
            // value
            return 0;
        }

        int256 adjusted_balance = int256(VotingEscrow(VOTING_ESCROW).balanceOf(_account));

        Boost memory _boost = boost[_account];
        int256 time = int256(block.timestamp);

        if (_boost.delegated != 0) {
            Point memory dpoint = _deconstruct_bias_slope(_boost.delegated);

            // we take the absolute value, since delegated boost can be negative
            // if any outstanding negative boosts are in circulation
            // this can inflate the vecrv balance of a user
            // taking the absolute value has the effect that it costs
            // a user to negatively impact another's vecrv balance
            adjusted_balance -= abs(dpoint.slope * time + dpoint.bias);
        }

        if (_boost.received != 0) {
            Point memory rpoint = _deconstruct_bias_slope(_boost.received);

            // similar to delegated boost, our received boost can be negative
            // if any outstanding negative boosts are in our possession
            // However, unlike delegated boost, we do not negatively impact
            // our adjusted balance due to negative boosts. Instead we take
            // whichever is greater between 0 and the value of our received
            // boosts.
            adjusted_balance += Math.max(rpoint.slope * time + rpoint.bias, 0);
        }

        // since we took the absolute value of our delegated boost, it now instead of
        // becoming negative is positive, and will continue to increase ...
        // meaning if we keep a negative outstanding delegated balance for long
        // enought it will not only decrease our vecrv_balance but also our received
        // boost, however we return the maximum between our adjusted balance and 0
        // when delegating boost, received boost isn't used for determining how
        // much we can delegate.
        return safe_uint256(Math.max(adjusted_balance, 0));
    }

    /**
    * Query the total effective delegated boost value of an account.
    * @dev This value can be greater than the veCRV balance of
    *     an account if the account has outstanding negative
    *     value boosts.
    * @param _account The account to query
    */
    function delegated_boost(address _account) external view returns(uint256) {
        Point memory dpoint = _deconstruct_bias_slope(boost[_account].delegated);
        int256 time = int256(block.timestamp);
        return safe_uint256(abs(dpoint.slope * time + dpoint.bias));
    }


    /**
    * Query the total effective received boost value of an account
    * @dev This value can be 0, even with delegations which have a large value,
    *     if the account has any outstanding negative value boosts.
    * @param _account The account to query
    */
    function received_boost(address _account) external view returns(uint256) {
        Point memory rpoint = _deconstruct_bias_slope(boost[_account].received);
        int256 time = int256(block.timestamp);
        return safe_uint256(Math.max(rpoint.slope * time + rpoint.bias, 0));
    }


    /**
    * @notice Query the effective value of a boost
    * @dev The effective value of a boost is under base after it's expiration
    *     date.
    * @param _token_id The token id to query
    */
    function token_boost(uint256 _token_id) external view returns(int256) {
        Point memory tpoint = _deconstruct_bias_slope(boost_tokens[_token_id].data);
        int256 time = int256(block.timestamp);
        return tpoint.slope * time + tpoint.bias;
    }

    /**
    * Query the timestamp of a boost token's expiry
    * @dev The effective value of a boost is negative after it's expiration
    *     date.
    * @param _token_id The token id to query
    */
    function token_expiry(uint256 _token_id) external view returns(uint256) {
        return boost_tokens[_token_id].expire_time;
    }


    /**
    * Query the timestamp of a boost token's cancel time. This is
    *     the point at which the delegator can nullify the boost. A receiver
    *     can cancel a token at any point. Anyone can nullify a token's boost
    *     after it's expiration.
    * @param _token_id The token id to query
    */
    function token_cancel_time(uint256 _token_id) external view returns(uint256) {
        return boost_tokens[_token_id].dinfo % 2 ** 128;
    }

    function _calc_boost_bias_slope(
        address _delegator,
        int256 _percentage,
        int256 _expire_time,
        uint256 _extend_token_id
    ) internal view returns(int256, int256) {
        int256 time = int256(block.timestamp);
        require(_percentage > 0, "dev: percentage must be greater than 0");
        require(_percentage <= int256(MAX_PCT), "dev: percentage must be less than or equal to 100%");
        require(_expire_time > time + int256(WEEK), "dev: Invalid min expiry time");

        Point memory dpoint ;
        {
            int256 lock_expiry = int256(VotingEscrow(VOTING_ESCROW).locked__end(_delegator));
            require(_expire_time <= lock_expiry);

            uint256 ddata = boost[_delegator].delegated;

            if (_extend_token_id != 0 && address(uint160(_extend_token_id >> 96)) == _delegator) {
            // decrease the delegated bias and slope by the token's bias and slope
            // only if it is the delegator's and it is within the bounds of existence
            ddata -= boost_tokens[_extend_token_id].data;
            }

            dpoint = _deconstruct_bias_slope(ddata);
        }

        int256 _delegated_boost = dpoint.slope * time + dpoint.bias;
        require(_delegated_boost >= 0, "dev: outstanding negative boosts");

        int256 y = _percentage * (int256(VotingEscrow(VOTING_ESCROW).balanceOf(_delegator)) - _delegated_boost) / int256(MAX_PCT);
        require(y > 0, "dev: no boost");

        int256 slope = -y / (_expire_time - time);
        require(slope < 0, "dev: invalid slope");

        int256 bias = y - slope * time;

        return (bias, slope);
    }

    /**
    * Calculate the bias and slope for a boost.
    * @param _delegator The account to delegate boost from
    * @param _percentage The percentage of the _delegator's delegable
    *     veCRV to delegate.
    * @param _expire_time The time at which the boost value of the token
    *     will reach 0, and subsequently become negative
    * @param _extend_token_id OPTIONAL token id, which if set will first nullify
    *     the boost of the token, before calculating the bias and slope. Useful
    *     for calculating the new bias and slope when extending a token, or
    *     determining the bias and slope of a subsequent token after cancelling
    *     an existing one. Will have no effect if _delegator is not the delegator
    *     of the token.
    */
    function calc_boost_bias_slope(
        address _delegator,
        int256 _percentage,
        int256 _expire_time,
        uint256 _extend_token_id
    ) external view returns(int256, int256) {
        return _calc_boost_bias_slope(_delegator, _percentage, _expire_time, _extend_token_id);
    }
  
    function calc_boost_bias_slope(
        address _delegator,
        int256 _percentage,
        int256 _expire_time
    ) external view returns(int256, int256) {
        return _calc_boost_bias_slope(_delegator, _percentage, _expire_time, 0);
    }
  
    /**
    * Simple method to get the token id's mintable by a delegator
    * @param _delegator The address of the delegator
    * @param _id The id value, must be less than 2 ** 96
    */
    function get_token_id(address _delegator, uint256 _id) external pure returns(uint256) {
        require(_id < 2 ** 96, "dev: invalid _id");
        return (uint256(uint160(_delegator)) << 96) + _id;
    }

    function set_base_uri(string memory _base_uri) external onlyOwner {
        base_uri = _base_uri;
    }

    function safe_uint256(int256 v) internal pure returns (uint256) {
        require (v >= 0, "negative value");
        return uint256(v);
    }
    /*

    @external
    def commit_transfer_ownership(_addr: address):
        """
        @notice Transfer ownership of contract to `addr`
        @param _addr Address to have ownership transferred to
        """
        assert msg.sender == self.admin  # dev: admin only
        self.future_admin = _addr


    @external
    def accept_transfer_ownership():
        """
        @notice Accept admin role, only callable by future admin
        """
        future_admin: address = self.future_admin
        assert msg.sender == future_admin
        self.admin = future_admin


    @external
    def set_base_uri(_base_uri: String[128]):
        assert msg.sender == self.admin
        self.base_uri = _base_uri
    */
}
