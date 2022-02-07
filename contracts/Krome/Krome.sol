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

import "../ERC20/ERC20Custom.sol";
import "../ERC20/ERC20KIP7.sol";
import "../Usdk/IUsdk.sol";
import "../Common/TimelockOwned.sol";

contract KromeShares is ERC20Custom, ERC20KIP7, TimelockOwned {
    /* ========== STATE VARIABLES ========== */

    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public KromeStablecoinAdd;

    uint256 public constant genesis_supply = 500_000_000e18; // 500M is printed upon genesis

    address private usdk_address;

    bool public trackingVotes = true; // Tracking votes (only change if need to disable votes)

    // A checkpoint for marking number of votes from a given block
    struct Checkpoint {
        uint32 fromBlock;
        uint96 votes;
    }

    // A record of votes checkpoints for each account, by index
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;

    // The number of checkpoints for each account
    mapping(address => uint32) public numCheckpoints;

    /* ========== MODIFIERS ========== */

    modifier onlyPools() {
        require(
            IUsdk(usdk_address).usdk_pools(msg.sender) == true,
            "Only usdk pools can call this function"
        );
        _;
    }

    modifier onlyByOwnGov() {
        require(
            msg.sender == owner || msg.sender == timelock_address,
            "You are not an owner or the governance timelock"
        );
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator_address,
        address _timelock_address
    ) TimelockOwned(payable(msg.sender), _timelock_address) {
        require(
            (_timelock_address != address(0)),
            "Zero address detected"
        );
        name = _name;
        symbol = _symbol;
        _mint(_creator_address, genesis_supply);

        // Do a checkpoint for the owner
        _writeCheckpoint(_creator_address, 0, 0, uint96(genesis_supply));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setUsdkAddress(address usdk_contract_address)
        external
        onlyByOwnGov
    {
        require(usdk_contract_address != address(0), "Zero address detected");

        usdk_address = usdk_contract_address;

        emit UsdkAddressSet(usdk_contract_address);
    }

    // is it used? - by tate
    // function mint(address to, uint256 amount) public onlyPools {
    //     _mint(to, amount);
    // }

    // This function is what other usdk pools will call to mint new KROME (similar to the USDK mint)
    function pool_mint(address m_address, uint256 m_amount) external onlyPools {
        if (trackingVotes) {
            uint32 srcRepNum = numCheckpoints[address(this)];
            uint96 srcRepOld = srcRepNum > 0
                ? checkpoints[address(this)][srcRepNum - 1].votes
                : 0;
            uint96 srcRepNew = add96(
                srcRepOld,
                uint96(m_amount),
                "pool_mint new votes overflows"
            );
            _writeCheckpoint(address(this), srcRepNum, srcRepOld, srcRepNew); // mint new votes
            trackVotes(address(this), m_address, uint96(m_amount));
        }

        super._mint(m_address, m_amount);
        emit KromeMinted(address(this), m_address, m_amount);
    }

    // This function is what other usdk pools will call to burn KROME
    function pool_burn_from(address b_address, uint256 b_amount)
        external
        onlyPools
    {
        if (trackingVotes) {
            trackVotes(b_address, address(this), uint96(b_amount));
            uint32 srcRepNum = numCheckpoints[address(this)];
            uint96 srcRepOld = srcRepNum > 0
                ? checkpoints[address(this)][srcRepNum - 1].votes
                : 0;
            uint96 srcRepNew = sub96(
                srcRepOld,
                uint96(b_amount),
                "pool_burn_from new votes underflows"
            );
            _writeCheckpoint(address(this), srcRepNum, srcRepOld, srcRepNew); // burn votes
        }

        super._burnFrom(b_address, b_amount);
        emit KromeBurned(b_address, address(this), b_amount);
    }

    function toggleVotes() external onlyByOwnGov {
        trackingVotes = !trackingVotes;
    }

    /* ========== OVERRIDDEN PUBLIC FUNCTIONS ========== */

    function transfer(address recipient, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        if (trackingVotes) {
            // Transfer votes
            trackVotes(_msgSender(), recipient, uint96(amount));
        }

        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        if (trackingVotes) {
            // Transfer votes
            trackVotes(sender, recipient, uint96(amount));
        }

        _transfer(sender, recipient, amount);
        require(amount <= _allowances[sender][_msgSender()], "ERC20: transfer amount exceeds allowance");
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()] - amount
        );

        return true;
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    /**
     * @notice Gets the current votes balance for `account`
     * @param account The address to get votes balance
     * @return The number of current votes for `account`
     */
    function getCurrentVotes(address account) external view returns (uint96) {
        uint32 nCheckpoints = numCheckpoints[account];
        return
            nCheckpoints > 0 ? checkpoints[account][nCheckpoints - 1].votes : 0;
    }

    /**
     * @notice Determine the prior number of votes for an account as of a block number
     * @dev Block number must be a finalized block or else this function will revert to prevent misinformation.
     * @param account The address of the account to check
     * @param blockNumber The block number to get the vote balance at
     * @return The number of votes the account had as of the given block
     */
    function getPriorVotes(address account, uint256 blockNumber)
        public
        view
        returns (uint96)
    {
        require(
            blockNumber < block.number,
            "KROME::getPriorVotes: not yet determined"
        );

        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return 0;
        }

        // First check most recent balance
        if (checkpoints[account][nCheckpoints - 1].fromBlock <= blockNumber) {
            return checkpoints[account][nCheckpoints - 1].votes;
        }

        // Next check implicit zero balance
        if (checkpoints[account][0].fromBlock > blockNumber) {
            return 0;
        }

        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
            Checkpoint memory cp = checkpoints[account][center];
            if (cp.fromBlock == blockNumber) {
                return cp.votes;
            } else if (cp.fromBlock < blockNumber) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return checkpoints[account][lower].votes;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    // From compound's _moveDelegates
    // Keep track of votes. "Delegates" is a misnomer here
    function trackVotes(
        address srcRep,
        address dstRep,
        uint96 amount
    ) internal {
        if (srcRep != dstRep && amount > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint96 srcRepOld = srcRepNum > 0
                    ? checkpoints[srcRep][srcRepNum - 1].votes
                    : 0;
                uint96 srcRepNew = sub96(
                    srcRepOld,
                    amount,
                    "KROME::_moveVotes: vote amount underflows"
                );
                _writeCheckpoint(srcRep, srcRepNum, srcRepOld, srcRepNew);
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint96 dstRepOld = dstRepNum > 0
                    ? checkpoints[dstRep][dstRepNum - 1].votes
                    : 0;
                uint96 dstRepNew = add96(
                    dstRepOld,
                    amount,
                    "KROME::_moveVotes: vote amount overflows"
                );
                _writeCheckpoint(dstRep, dstRepNum, dstRepOld, dstRepNew);
            }
        }
    }

    function _writeCheckpoint(
        address voter,
        uint32 nCheckpoints,
        uint96 oldVotes,
        uint96 newVotes
    ) internal {
        uint32 blockNumber = safe32(
            block.number,
            "KROME::_writeCheckpoint: block number exceeds 32 bits"
        );

        if (
            nCheckpoints > 0 &&
            checkpoints[voter][nCheckpoints - 1].fromBlock == blockNumber
        ) {
            checkpoints[voter][nCheckpoints - 1].votes = newVotes;
        } else {
            checkpoints[voter][nCheckpoints] = Checkpoint(
                blockNumber,
                newVotes
            );
            numCheckpoints[voter] = nCheckpoints + 1;
        }

        emit VoterVotesChanged(voter, oldVotes, newVotes);
    }

    function safe32(uint256 n, string memory errorMessage)
        internal
        pure
        returns (uint32)
    {
        require(n < 2**32, errorMessage);
        return uint32(n);
    }

    function safe96(uint256 n, string memory errorMessage)
        internal
        pure
        returns (uint96)
    {
        require(n < 2**96, errorMessage);
        return uint96(n);
    }

    function add96(
        uint96 a,
        uint96 b,
        string memory errorMessage
    ) internal pure returns (uint96) {
        uint96 c = a + b;
        require(c >= a, errorMessage);
        return c;
    }

    function sub96(
        uint96 a,
        uint96 b,
        string memory errorMessage
    ) internal pure returns (uint96) {
        require(b <= a, errorMessage);
        return a - b;
    }

    /* ========== EVENTS ========== */

    /// @notice An event thats emitted when a voters account's vote balance changes
    event VoterVotesChanged(
        address indexed voter,
        uint256 previousBalance,
        uint256 newBalance
    );

    // Track KROME burned
    event KromeBurned(address indexed from, address indexed to, uint256 amount);

    // Track KROME minted
    event KromeMinted(address indexed from, address indexed to, uint256 amount);

    event UsdkAddressSet(address addr);
}
