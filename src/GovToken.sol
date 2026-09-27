// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Fixed-supply ERC-20 with explicitly delegated, timestamp-based voting power.
contract GovToken {
    string public constant name = "Gov Token";
    string public constant symbol = "GOV";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000 ether;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => address) public delegates;

    struct Checkpoint {
        uint48 timepoint;
        uint208 votes;
    }

    mapping(address => Checkpoint[]) private _voteCheckpoints;
    Checkpoint[] private _supplyCheckpoints;

    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);
    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

    constructor(address holder) {
        if (holder == address(0)) revert ERC20InvalidReceiver(holder);
        balanceOf[holder] = totalSupply;
        _writeCheckpoint(_supplyCheckpoints, totalSupply);
        emit Transfer(address(0), holder, totalSupply);
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure returns (string memory) {
        return "mode=timestamp";
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        if (msg.sender == address(0)) revert ERC20InvalidApprover(msg.sender);
        if (spender == address(0)) revert ERC20InvalidSpender(spender);
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(msg.sender, currentAllowance, value);
            }
            // Like ERC-20 in OpenZeppelin v5, spending allowance does not emit Approval.
            allowance[from][msg.sender] = currentAllowance - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function delegate(address delegatee) public {
        address previousDelegate = delegates[msg.sender];
        delegates[msg.sender] = delegatee;
        emit DelegateChanged(msg.sender, previousDelegate, delegatee);
        _moveDelegateVotes(previousDelegate, delegatee, balanceOf[msg.sender]);
    }

    function getVotes(address account) public view returns (uint256) {
        return _latest(_voteCheckpoints[account]);
    }

    function getPastVotes(address account, uint256 timepoint) public view returns (uint256) {
        return _pastLookup(_voteCheckpoints[account], timepoint);
    }

    function getPastTotalSupply(uint256 timepoint) public view returns (uint256) {
        return _pastLookup(_supplyCheckpoints, timepoint);
    }

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(from);
        if (to == address(0)) revert ERC20InvalidReceiver(to);
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        balanceOf[from] = fromBalance - value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        _moveDelegateVotes(delegates[from], delegates[to], value);
    }

    function _moveDelegateVotes(address from, address to, uint256 value) private {
        if (from == to || value == 0) return;
        if (from != address(0)) {
            uint256 previousVotes = getVotes(from);
            uint256 newVotes = previousVotes - value;
            _writeCheckpoint(_voteCheckpoints[from], newVotes);
            emit DelegateVotesChanged(from, previousVotes, newVotes);
        }
        if (to != address(0)) {
            uint256 previousVotes = getVotes(to);
            uint256 newVotes = previousVotes + value;
            _writeCheckpoint(_voteCheckpoints[to], newVotes);
            emit DelegateVotesChanged(to, previousVotes, newVotes);
        }
    }

    function _latest(Checkpoint[] storage checkpoints) private view returns (uint256) {
        uint256 length = checkpoints.length;
        return length == 0 ? 0 : checkpoints[length - 1].votes;
    }

    function _writeCheckpoint(Checkpoint[] storage checkpoints, uint256 votes) private {
        uint48 timepoint = clock();
        uint256 length = checkpoints.length;
        // Every vote count is bounded by the fixed supply, which fits in uint208.
        if (length != 0 && checkpoints[length - 1].timepoint == timepoint) {
            checkpoints[length - 1].votes = uint208(votes);
        } else {
            checkpoints.push(Checkpoint(timepoint, uint208(votes)));
        }
    }

    function _pastLookup(Checkpoint[] storage checkpoints, uint256 timepoint) private view returns (uint256) {
        uint48 currentTimepoint = clock();
        if (timepoint >= currentTimepoint) revert ERC5805FutureLookup(timepoint, currentTimepoint);

        // Find the first checkpoint strictly after the requested timepoint.
        uint256 low;
        uint256 high = checkpoints.length;
        while (low < high) {
            uint256 mid = low + (high - low) / 2;
            if (checkpoints[mid].timepoint > timepoint) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }
        return low == 0 ? 0 : checkpoints[low - 1].votes;
    }
}
