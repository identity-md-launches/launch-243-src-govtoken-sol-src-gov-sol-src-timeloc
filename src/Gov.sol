// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IGovVotes {
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}

interface IGovTimelock {
    function MIN_DELAY() external view returns (uint256);
    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt, uint256 delay) external;
    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external payable;
}

/// @notice A timestamp-based, single-action governor with delegated token voting.
contract Gov {
    // Keep the OpenZeppelin Governor state numbering, including the unused Expired state.
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    struct Proposal {
        address proposer;
        uint48 snapshot;
        uint48 deadline;
        address target;
        bool canceled;
        bool executed;
        uint256 value;
        bytes data;
        uint256 eta;
        uint256 againstVotes;
        uint256 forVotes;
        uint256 abstainVotes;
    }

    IGovVotes public immutable token;
    IGovTimelock public immutable timelock;

    uint256 public constant votingDelay = 1 days;
    uint256 public constant votingPeriod = 3 days;
    uint256 public constant proposalThreshold = 1_000 ether;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    error InvalidAddress();
    error UnknownProposal(uint256 proposalId);
    error DuplicateProposal(uint256 proposalId);
    error InsufficientProposerVotes(uint256 votes, uint256 threshold);
    error UnexpectedProposalState(uint256 proposalId, ProposalState current, ProposalState expected);
    error InvalidSupport(uint8 support);
    error AlreadyVoted(uint256 proposalId, address voter);
    error OnlyProposer(address caller);

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address target,
        uint256 value,
        bytes data,
        uint256 snapshot,
        uint256 deadline,
        string description
    );
    event VoteCast(address indexed voter, uint256 proposalId, uint8 support, uint256 weight, string reason);
    event ProposalQueued(uint256 proposalId, uint256 etaSeconds);
    event ProposalExecuted(uint256 proposalId);
    event ProposalCanceled(uint256 proposalId);

    constructor(address token_, address timelock_) {
        if (token_ == address(0) || timelock_ == address(0)) revert InvalidAddress();
        token = IGovVotes(token_);
        timelock = IGovTimelock(timelock_);
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure returns (string memory) {
        return "mode=timestamp";
    }

    function hashProposal(address target, uint256 value, bytes memory data, bytes32 descriptionHash)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(target, value, data, descriptionHash)));
    }

    function propose(address target, uint256 value, bytes calldata data, string calldata description)
        external
        returns (uint256 proposalId)
    {
        uint48 now_ = clock();
        uint256 votes = token.getPastVotes(msg.sender, now_ - 1);
        if (votes < proposalThreshold) revert InsufficientProposerVotes(votes, proposalThreshold);

        proposalId = hashProposal(target, value, data, keccak256(bytes(description)));
        Proposal storage proposal = _proposals[proposalId];
        if (proposal.snapshot != 0) revert DuplicateProposal(proposalId);

        proposal.proposer = msg.sender;
        proposal.snapshot = now_ + uint48(votingDelay);
        proposal.deadline = proposal.snapshot + uint48(votingPeriod);
        proposal.target = target;
        proposal.value = value;
        proposal.data = data;

        emit ProposalCreated(
            proposalId, msg.sender, target, value, data, proposal.snapshot, proposal.deadline, description
        );
    }

    /// @dev Execution is tracked through Gov.execute. The specified timelock API
    /// exposes no status query for operations executed directly on the timelock.
    function state(uint256 proposalId) public view returns (ProposalState) {
        Proposal storage proposal = _proposal(proposalId);
        if (proposal.canceled) return ProposalState.Canceled;
        if (proposal.executed) return ProposalState.Executed;
        if (proposal.eta != 0) return ProposalState.Queued;

        uint48 now_ = clock();
        if (now_ <= proposal.snapshot) return ProposalState.Pending;
        if (now_ <= proposal.deadline) return ProposalState.Active;
        if (
            proposal.forVotes > proposal.againstVotes
                && proposal.forVotes + proposal.abstainVotes >= quorum(proposal.snapshot)
        ) return ProposalState.Succeeded;
        return ProposalState.Defeated;
    }

    function castVote(uint256 proposalId, uint8 support) external returns (uint256 weight) {
        _requireState(proposalId, ProposalState.Active);
        if (support > 2) revert InvalidSupport(support);
        if (_hasVoted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        Proposal storage proposal = _proposals[proposalId];
        weight = token.getPastVotes(msg.sender, proposal.snapshot);
        _hasVoted[proposalId][msg.sender] = true;
        if (support == 0) proposal.againstVotes += weight;
        else if (support == 1) proposal.forVotes += weight;
        else proposal.abstainVotes += weight;
        emit VoteCast(msg.sender, proposalId, support, weight, "");
    }

    function queue(uint256 proposalId) external returns (uint256) {
        _requireState(proposalId, ProposalState.Succeeded);
        Proposal storage proposal = _proposals[proposalId];
        uint256 delay = timelock.MIN_DELAY();
        proposal.eta = uint256(clock()) + delay;
        emit ProposalQueued(proposalId, proposal.eta);
        timelock.schedule(proposal.target, proposal.value, proposal.data, bytes32(proposalId), delay);
        return proposalId;
    }

    function execute(uint256 proposalId) external payable returns (uint256) {
        _requireState(proposalId, ProposalState.Queued);
        Proposal storage proposal = _proposals[proposalId];
        // A failed timelock call rolls this back; a reentrant call sees Executed.
        proposal.executed = true;
        emit ProposalExecuted(proposalId);
        timelock.execute{value: msg.value}(proposal.target, proposal.value, proposal.data, bytes32(proposalId));
        return proposalId;
    }

    function cancel(uint256 proposalId) external returns (uint256) {
        _requireState(proposalId, ProposalState.Pending);
        Proposal storage proposal = _proposals[proposalId];
        if (msg.sender != proposal.proposer) revert OnlyProposer(msg.sender);
        // Pending proposals have no scheduled timelock operation to cancel.
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
        return proposalId;
    }

    function quorum(uint256 timepoint) public view returns (uint256) {
        uint256 supply = token.getPastTotalSupply(timepoint);
        // 4 / 100 = 1 / 25: preserve floor rounding without an overflowing product.
        return supply / 25;
    }

    function proposalSnapshot(uint256 proposalId) external view returns (uint256) {
        return _proposal(proposalId).snapshot;
    }

    function proposalDeadline(uint256 proposalId) external view returns (uint256) {
        return _proposal(proposalId).deadline;
    }

    function proposalProposer(uint256 proposalId) external view returns (address) {
        return _proposal(proposalId).proposer;
    }

    function proposalEta(uint256 proposalId) external view returns (uint256) {
        return _proposal(proposalId).eta;
    }

    function proposalVotes(uint256 proposalId)
        external
        view
        returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes)
    {
        Proposal storage proposal = _proposal(proposalId);
        return (proposal.againstVotes, proposal.forVotes, proposal.abstainVotes);
    }

    function hasVoted(uint256 proposalId, address account) external view returns (bool) {
        return _hasVoted[proposalId][account];
    }

    function _proposal(uint256 proposalId) private view returns (Proposal storage proposal) {
        proposal = _proposals[proposalId];
        if (proposal.snapshot == 0) revert UnknownProposal(proposalId);
    }

    function _requireState(uint256 proposalId, ProposalState expected) private view {
        ProposalState current = state(proposalId);
        if (current != expected) revert UnexpectedProposalState(proposalId, current, expected);
    }
}
