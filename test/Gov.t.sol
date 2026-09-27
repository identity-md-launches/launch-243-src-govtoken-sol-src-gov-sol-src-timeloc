// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function warp(uint256 timestamp) external;
    function roll(uint256 blockNumber) external;
    function prank(address caller) external;
    function deal(address account, uint256 balance) external;
    function expectRevert(bytes calldata reason) external;
    function expectEmit(bool, bool, bool, bool, address emitter) external;
    function getCode(string calldata artifact) external view returns (bytes memory);
}

interface GovTokenInterface {
    function transfer(address, uint256) external returns (bool);
    function delegate(address) external;
    function getVotes(address) external view returns (uint256);
    function getPastVotes(address, uint256) external view returns (uint256);
    function getPastTotalSupply(uint256) external view returns (uint256);
}

interface GovTimelockInterface {
    function bind(address) external;
    function admin() external view returns (address);
    function governor() external view returns (address);
    function MIN_DELAY() external view returns (uint256);
    function schedule(address, uint256, bytes calldata, bytes32, uint256) external;
    function cancel(bytes32) external;
    function execute(address, uint256, bytes calldata, bytes32) external payable;
    function getTimestamp(bytes32) external view returns (uint256);
    function isOperationPending(bytes32) external view returns (bool);
    function isOperationDone(bytes32) external view returns (bool);
}

interface GovernorInterface {
    function token() external view returns (address);
    function timelock() external view returns (address);
    function clock() external view returns (uint48);
    function CLOCK_MODE() external view returns (string memory);
    function votingDelay() external view returns (uint256);
    function votingPeriod() external view returns (uint256);
    function proposalThreshold() external view returns (uint256);
    function hashProposal(address, uint256, bytes calldata, bytes32) external pure returns (uint256);
    function propose(address, uint256, bytes calldata, string calldata) external returns (uint256);
    function castVote(uint256, uint8) external returns (uint256);
    function queue(uint256) external returns (uint256);
    function execute(uint256) external payable returns (uint256);
    function cancel(uint256) external returns (uint256);
    function state(uint256) external view returns (uint8);
    function quorum(uint256) external view returns (uint256);
    function proposalSnapshot(uint256) external view returns (uint256);
    function proposalDeadline(uint256) external view returns (uint256);
    function proposalProposer(uint256) external view returns (address);
    function proposalEta(uint256) external view returns (uint256);
    function proposalVotes(uint256) external view returns (uint256, uint256, uint256);
    function hasVoted(uint256, address) external view returns (bool);
}

contract GovernorTarget {
    uint256 public stored;
    uint256 public calls;
    uint256 public received;
    address public caller;
    bool public shouldRevert;
    bool public sawExecuted;
    bool public reentrySucceeded;
    bytes public reentryError;
    GovernorInterface public reentryGovernor;
    uint256 public reentryProposal;

    error TargetRejected(uint256 value);

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function setReentry(GovernorInterface governor, uint256 id) external {
        reentryGovernor = governor;
        reentryProposal = id;
    }

    function store(uint256 value) external payable {
        if (shouldRevert) revert TargetRejected(value);
        ++calls;
        stored = value;
        received += msg.value;
        caller = msg.sender;
        if (address(reentryGovernor) != address(0)) {
            sawExecuted = reentryGovernor.state(reentryProposal) == 7;
            (reentrySucceeded, reentryError) =
                address(reentryGovernor).call(abi.encodeCall(GovernorInterface.execute, (reentryProposal)));
        }
    }
}

// The real token's fixed supply is divisible by 25. This view-only fixture makes
// fractional quorum and uint256 overflow boundaries observable independently.
contract QuorumSupplyFixture {
    uint256 internal immutable supply;

    constructor(uint256 supply_) {
        supply = supply_;
    }

    function getPastTotalSupply(uint256) external view returns (uint256) {
        return supply;
    }
}

contract GovTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant START = 1_000_000;
    uint256 internal constant QUORUM = 40_000 ether;
    address internal constant ADMIN = address(0xAD01);
    address internal constant PROPOSER = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint8 internal constant PENDING = 0;
    uint8 internal constant ACTIVE = 1;
    uint8 internal constant CANCELED = 2;
    uint8 internal constant DEFEATED = 3;
    uint8 internal constant SUCCEEDED = 4;
    uint8 internal constant QUEUED = 5;
    uint8 internal constant EXECUTED = 7;

    GovTokenInterface internal token;
    GovTimelockInterface internal timelock;
    GovernorInterface internal gov;
    GovernorTarget internal target;

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

    function setUp() public {
        vm.warp(START);
        token = GovTokenInterface(_deploy("src/GovToken.sol:GovToken", abi.encode(address(this))));
        timelock = GovTimelockInterface(_deploy("src/Timelock.sol:Timelock", abi.encode(ADMIN)));
        gov = GovernorInterface(_deploy("src/Gov.sol:Gov", abi.encode(address(token), address(timelock))));
        vm.prank(ADMIN);
        timelock.bind(address(gov));
        target = new GovernorTarget();
        _giveVotes(PROPOSER, 1_000 ether);
        vm.warp(START + 1);
    }

    function _deploy(string memory artifact, bytes memory args) internal returns (address deployed) {
        bytes memory code = abi.encodePacked(vm.getCode(artifact), args);
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "deployment failed");
    }

    function _giveVotes(address account, uint256 amount) internal {
        token.transfer(account, amount);
        vm.prank(account);
        token.delegate(account);
    }

    function _data() internal view returns (bytes memory) {
        return abi.encodeCall(target.store, (42));
    }

    function _propose(uint256 value, string memory description) internal returns (uint256 id) {
        bytes memory data = _data();
        vm.prank(PROPOSER);
        id = gov.propose(address(target), value, data, description);
    }

    function _open(uint256 id) internal {
        vm.warp(gov.proposalSnapshot(id) + 1);
    }

    function _finish(uint256 id) internal {
        vm.warp(gov.proposalDeadline(id) + 1);
    }

    function _vote(uint256 id, address voter, uint8 support, uint256 expectedWeight) internal {
        vm.prank(voter);
        require(gov.castVote(id, support) == expectedWeight, "snapshot voting weight");
    }

    function _passed(uint256 value) internal returns (uint256 id) {
        _giveVotes(ALICE, QUORUM);
        id = _propose(value, "set value");
        _open(id);
        _vote(id, ALICE, 1, QUORUM);
        _finish(id);
        require(gov.state(id) == SUCCEEDED, "proposal must pass before queue");
    }

    function _operation(uint256 id, uint256 value) internal view returns (bytes32) {
        return keccak256(abi.encode(address(target), value, _data(), bytes32(id)));
    }

    function _expectState(uint256 id, uint8 current, uint8 expected) internal {
        vm.expectRevert(abi.encodeWithSignature("UnexpectedProposalState(uint256,uint8,uint8)", id, current, expected));
    }

    function _assertVotes(uint256 id, uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) internal view {
        (uint256 actualAgainst, uint256 actualFor, uint256 actualAbstain) = gov.proposalVotes(id);
        require(actualAgainst == againstVotes && actualFor == forVotes && actualAbstain == abstainVotes, "vote totals");
    }

    function test_ParametersAndTimestampClock() public {
        require(gov.token() == address(token) && gov.timelock() == address(timelock), "stack references");
        require(gov.votingDelay() == 1 days && gov.votingPeriod() == 3 days, "durations in seconds");
        require(gov.proposalThreshold() == 1_000 ether, "threshold");
        require(keccak256(bytes(gov.CLOCK_MODE())) == keccak256("mode=timestamp"), "clock mode");
        vm.roll(block.number + 500_000);
        require(gov.clock() == START + 1, "block-based clock");
        vm.warp(START + 9);
        require(gov.clock() == START + 9, "timestamp clock");
    }

    function test_ProposalHashCreationEventTimingAndDuplicate() public {
        bytes memory data = _data();
        uint256 expectedId =
            uint256(keccak256(abi.encode(address(target), uint256(1 ether), data, keccak256("description"))));
        require(
            gov.hashProposal(address(target), 1 ether, data, keccak256("description")) == expectedId, "proposal hash"
        );
        vm.expectEmit(true, true, false, true, address(gov));
        emit ProposalCreated(
            expectedId, PROPOSER, address(target), 1 ether, data, START + 1 + 1 days, START + 1 + 4 days, "description"
        );
        uint256 id = _propose(1 ether, "description");
        require(id == expectedId && gov.state(id) == PENDING, "new proposal");
        require(gov.proposalProposer(id) == PROPOSER, "proposer");
        require(gov.proposalSnapshot(id) == START + 1 + 1 days, "snapshot");
        require(gov.proposalDeadline(id) == START + 1 + 4 days && gov.proposalEta(id) == 0, "deadline and eta");
        vm.expectRevert(abi.encodeWithSignature("DuplicateProposal(uint256)", id));
        vm.prank(PROPOSER);
        gov.propose(address(target), 1 ether, data, "description");
        require(_propose(1 ether, "different description") != id, "description not part of id");
        require(_propose(0, "description") != id, "value not part of id");
    }

    function test_ThresholdUsesPreviousSecondAndAcceptsExactlyOneThousand() public {
        _giveVotes(ALICE, 1_000 ether - 1);
        vm.warp(START + 2);
        bytes memory data = _data();
        vm.expectRevert(
            abi.encodeWithSignature("InsufficientProposerVotes(uint256,uint256)", 1_000 ether - 1, 1_000 ether)
        );
        vm.prank(ALICE);
        gov.propose(address(target), 0, data, "below threshold");
        token.transfer(ALICE, 1);
        require(token.getVotes(ALICE) == 1_000 ether, "current threshold");
        vm.expectRevert(
            abi.encodeWithSignature("InsufficientProposerVotes(uint256,uint256)", 1_000 ether - 1, 1_000 ether)
        );
        vm.prank(ALICE);
        gov.propose(address(target), 0, data, "same second");
        vm.warp(START + 3);
        vm.prank(ALICE);
        uint256 id = gov.propose(address(target), 0, data, "exact threshold");
        require(gov.state(id) == PENDING && gov.proposalProposer(id) == ALICE, "exact threshold rejected");
    }

    function test_UndelegatedBalanceCannotProposeButDelegatedVotesCan() public {
        bytes memory data = _data();
        vm.expectRevert(abi.encodeWithSignature("InsufficientProposerVotes(uint256,uint256)", 0, 1_000 ether));
        gov.propose(address(target), 0, data, "undelegated holder");
        token.delegate(ALICE);
        vm.warp(START + 2);
        vm.prank(ALICE);
        uint256 id = gov.propose(address(target), 0, data, "delegate with no balance");
        require(gov.state(id) == PENDING, "delegated threshold ignored");
    }

    function test_ThresholdUsesHistoricalVotesEvenAfterCurrentBalanceLeaves() public {
        vm.prank(PROPOSER);
        token.transfer(BOB, 1_000 ether);
        require(token.getVotes(PROPOSER) == 0, "current proposer votes");
        uint256 id = _propose(0, "historical threshold");
        require(gov.state(id) == PENDING, "threshold did not use previous second");
    }

    function test_UnknownProposalReadsAndActionsRevert() public {
        uint256 id = 123;
        bytes memory reason = abi.encodeWithSignature("UnknownProposal(uint256)", id);
        vm.expectRevert(reason);
        gov.state(id);
        vm.expectRevert(reason);
        gov.proposalSnapshot(id);
        vm.expectRevert(reason);
        gov.proposalDeadline(id);
        vm.expectRevert(reason);
        gov.proposalVotes(id);
        vm.expectRevert(reason);
        gov.castVote(id, 1);
        vm.expectRevert(reason);
        gov.queue(id);
        vm.expectRevert(reason);
        gov.execute(id);
        vm.expectRevert(reason);
        gov.cancel(id);
    }

    function test_VotingIncludesDeadlineButStartsAfterSnapshot() public {
        _giveVotes(ALICE, QUORUM);
        _giveVotes(BOB, 1 ether);
        uint256 id = _propose(0, "boundaries");
        _expectState(id, PENDING, ACTIVE);
        vm.prank(ALICE);
        gov.castVote(id, 1);
        vm.warp(gov.proposalSnapshot(id));
        require(gov.state(id) == PENDING, "snapshot second must be pending");
        _expectState(id, PENDING, ACTIVE);
        vm.prank(ALICE);
        gov.castVote(id, 1);
        _open(id);
        require(gov.state(id) == ACTIVE, "first active second");
        vm.expectEmit(true, false, false, true, address(gov));
        emit VoteCast(ALICE, id, 1, QUORUM, "");
        _vote(id, ALICE, 1, QUORUM);
        vm.warp(gov.proposalDeadline(id));
        require(gov.state(id) == ACTIVE, "deadline second must be active");
        _vote(id, BOB, 2, 1 ether);
        _expectState(id, ACTIVE, SUCCEEDED);
        gov.queue(id);
        _finish(id);
        require(gov.state(id) == SUCCEEDED, "first final second");
        _expectState(id, SUCCEEDED, ACTIVE);
        gov.castVote(id, 1);
        _assertVotes(id, 0, QUORUM, 1 ether);
    }

    function test_ProposeVoteQueueAndExecuteOneETHAsUnrelatedCallers() public {
        uint256 id = _passed(1 ether);
        vm.deal(address(this), 1 ether);
        (bool funded,) = address(timelock).call{value: 1 ether}("");
        require(funded, "fund timelock");
        uint256 eta = block.timestamp + 2 days;
        vm.expectEmit(false, false, false, true, address(gov));
        emit ProposalQueued(id, eta);
        vm.prank(BOB);
        require(gov.queue(id) == id, "queue return id");
        bytes32 operation = _operation(id, 1 ether);
        require(gov.state(id) == QUEUED && gov.proposalEta(id) == eta, "queued state and eta");
        require(timelock.getTimestamp(operation) == eta, "operation salt or delay");
        vm.warp(eta);
        vm.expectEmit(false, false, false, true, address(gov));
        emit ProposalExecuted(id);
        vm.prank(CAROL);
        require(gov.execute(id) == id, "execute return id");
        require(gov.state(id) == EXECUTED && timelock.isOperationDone(operation), "executed state");
        require(target.stored() == 42 && target.calls() == 1, "target call");
        require(target.caller() == address(timelock) && target.received() == 1 ether, "timelock sender and ETH");
        require(address(timelock).balance == 0 && address(target).balance == 1 ether, "ETH balances");
        _expectState(id, EXECUTED, QUEUED);
        gov.execute(id);
        _expectState(id, EXECUTED, SUCCEEDED);
        gov.queue(id);
    }

    function test_ExecuteBeforeTwoDaysRevertsAndCanRetryAtBoundary() public {
        uint256 id = _passed(0);
        gov.queue(id);
        bytes32 operation = _operation(id, 0);
        vm.expectRevert(abi.encodeWithSignature("OperationNotReady(bytes32)", operation));
        gov.execute(id);
        vm.warp(gov.proposalEta(id) - 1);
        vm.expectRevert(abi.encodeWithSignature("OperationNotReady(bytes32)", operation));
        vm.prank(CAROL);
        gov.execute(id);
        require(gov.state(id) == QUEUED && !timelock.isOperationDone(operation), "early execute consumed proposal");
        require(target.calls() == 0, "early target call");
        vm.warp(gov.proposalEta(id));
        gov.execute(id);
        require(gov.state(id) == EXECUTED && target.calls() == 1, "retry at ready boundary");
    }

    function test_ExecuteCanForwardExecutorETH() public {
        uint256 id = _passed(1 ether);
        gov.queue(id);
        vm.warp(gov.proposalEta(id));
        vm.deal(CAROL, 1 ether);
        vm.prank(CAROL);
        gov.execute{value: 1 ether}(id);
        require(target.received() == 1 ether && address(gov).balance == 0, "execution ETH forwarding");
    }

    function test_MoreAgainstThanForDefeatsAndCannotQueueOrExecute() public {
        _giveVotes(ALICE, QUORUM);
        _giveVotes(BOB, QUORUM + 1);
        uint256 id = _propose(0, "against wins");
        _open(id);
        _vote(id, ALICE, 1, QUORUM);
        _vote(id, BOB, 0, QUORUM + 1);
        _finish(id);
        require(gov.state(id) == DEFEATED, "against majority");
        _assertVotes(id, QUORUM + 1, QUORUM, 0);
        _expectState(id, DEFEATED, SUCCEEDED);
        gov.queue(id);
        _expectState(id, DEFEATED, QUEUED);
        gov.execute(id);
        vm.warp(block.timestamp + 2 days);
        _directExecutionMustFail(id, 0);
    }

    function test_TiedVotesAreDefeatedDespiteQuorum() public {
        _giveVotes(ALICE, QUORUM);
        _giveVotes(BOB, QUORUM);
        uint256 id = _propose(0, "tie");
        _open(id);
        _vote(id, ALICE, 1, QUORUM);
        _vote(id, BOB, 0, QUORUM);
        _finish(id);
        require(gov.state(id) == DEFEATED, "ties must fail");
    }

    function test_QuorumFailsAtThreePointNineNinePercent() public {
        _quorumElection(39_900 ether, DEFEATED);
    }

    function test_QuorumFailsOneWeiBelowFourPercent() public {
        _quorumElection(QUORUM - 1, DEFEATED);
    }

    function test_QuorumPassesAtExactlyFourPercent() public {
        _quorumElection(QUORUM, SUCCEEDED);
    }

    function _quorumElection(uint256 votes, uint8 expected) internal {
        _giveVotes(ALICE, votes);
        uint256 id = _propose(0, "quorum boundary");
        _open(id);
        require(gov.quorum(gov.proposalSnapshot(id)) == QUORUM, "quorum must use full supply");
        _vote(id, ALICE, 1, votes);
        _finish(id);
        require(gov.state(id) == expected, "quorum boundary result");
        if (expected == DEFEATED) {
            _expectState(id, DEFEATED, SUCCEEDED);
            gov.queue(id);
        }
    }

    function test_AbstainCountsTowardQuorumAndAgainstDoesNot() public {
        _giveVotes(ALICE, 30_000 ether);
        _giveVotes(BOB, 20_000 ether);
        uint256 abstainId = _propose(0, "abstain quorum");
        uint256 againstId = _propose(0, "against turnout");
        _open(abstainId);
        _vote(abstainId, ALICE, 1, 30_000 ether);
        _vote(abstainId, BOB, 2, 20_000 ether);
        _vote(againstId, ALICE, 1, 30_000 ether);
        _vote(againstId, BOB, 0, 20_000 ether);
        _finish(abstainId);
        require(gov.state(abstainId) == SUCCEEDED, "abstain excluded from quorum");
        require(gov.state(againstId) == DEFEATED, "against included in quorum");
        _assertVotes(abstainId, 0, 30_000 ether, 20_000 ether);
        _assertVotes(againstId, 20_000 ether, 30_000 ether, 0);
    }

    function test_OnlyAbstainOrNoVotesIsDefeated() public {
        _giveVotes(ALICE, QUORUM);
        uint256 abstainId = _propose(0, "all abstain");
        uint256 emptyId = _propose(0, "no votes");
        _open(abstainId);
        _vote(abstainId, ALICE, 2, QUORUM);
        _finish(abstainId);
        require(gov.state(abstainId) == DEFEATED, "abstain is not approval");
        require(gov.state(emptyId) == DEFEATED, "no votes is not approval");
    }

    function testFuzz_QuorumRoundsDownWithoutOverflow(uint256 supply) public {
        QuorumSupplyFixture fixture = new QuorumSupplyFixture(supply);
        GovernorInterface roundingGov =
            GovernorInterface(_deploy("src/Gov.sol:Gov", abi.encode(address(fixture), address(timelock))));
        uint256 expected = (supply / 100) * 4 + ((supply % 100) * 4) / 100;
        require(roundingGov.quorum(START) == expected, "floor four percent");
    }

    function test_UndelegatedHolderVotesZeroAndCannotVoteTwice() public {
        uint256 id = _propose(0, "undelegated weight");
        _open(id);
        _vote(id, address(this), 1, 0);
        require(gov.hasVoted(id, address(this)), "zero-weight ballot must count as cast");
        vm.expectRevert(abi.encodeWithSignature("AlreadyVoted(uint256,address)", id, address(this)));
        gov.castVote(id, 2);
        _assertVotes(id, 0, 0, 0);
        _finish(id);
        require(gov.state(id) == DEFEATED, "undelegated supply voted");
    }

    function test_ReceivedOrDelegatedAfterSnapshotDoesNotCount() public {
        _giveVotes(ALICE, 20_000 ether);
        token.transfer(BOB, 20_000 ether);
        uint256 id = _propose(0, "late votes");
        _open(id);
        token.transfer(ALICE, 20_000 ether);
        vm.prank(BOB);
        token.delegate(BOB);
        require(token.getVotes(ALICE) == QUORUM && token.getVotes(BOB) == 20_000 ether, "current votes");
        _vote(id, ALICE, 1, 20_000 ether);
        _vote(id, BOB, 1, 0);
        _assertVotes(id, 0, 20_000 ether, 0);
        _finish(id);
        require(gov.state(id) == DEFEATED, "late votes counted toward quorum");
    }

    function test_TransferAfterVotingCannotReuseVotesAtRecipient() public {
        _giveVotes(ALICE, QUORUM);
        vm.prank(BOB);
        token.delegate(BOB);
        uint256 id = _propose(0, "transfer vote reuse");
        _open(id);
        _vote(id, ALICE, 1, QUORUM);
        vm.prank(ALICE);
        token.transfer(BOB, QUORUM);
        _vote(id, BOB, 1, 0);
        _assertVotes(id, 0, QUORUM, 0);
        vm.expectRevert(abi.encodeWithSignature("AlreadyVoted(uint256,address)", id, ALICE));
        vm.prank(ALICE);
        gov.castVote(id, 0);
        _assertVotes(id, 0, QUORUM, 0);
    }

    function test_RedelegationAfterSnapshotCannotDuplicateVotesOrRemoveHistoricalVotes() public {
        _giveVotes(ALICE, QUORUM);
        uint256 id = _propose(0, "redelegation vote reuse");
        _open(id);
        vm.prank(ALICE);
        token.delegate(BOB);
        _vote(id, ALICE, 1, QUORUM);
        _vote(id, BOB, 1, 0);
        vm.prank(ALICE);
        token.delegate(CAROL);
        _vote(id, CAROL, 1, 0);
        _assertVotes(id, 0, QUORUM, 0);
    }

    function test_ChangesExactlyAtSnapshotUseFinalCheckpointOfThatSecond() public {
        _giveVotes(ALICE, 20_000 ether);
        uint256 id = _propose(0, "snapshot checkpoint");
        vm.warp(gov.proposalSnapshot(id));
        token.transfer(ALICE, 20_000 ether);
        vm.prank(ALICE);
        token.delegate(BOB);
        vm.prank(ALICE);
        token.delegate(CAROL);
        _open(id);
        _vote(id, ALICE, 1, 0);
        _vote(id, BOB, 1, 0);
        _vote(id, CAROL, 1, QUORUM);
        _assertVotes(id, 0, QUORUM, 0);
    }

    function testFuzz_InvalidSupportDoesNotConsumeBallot(uint8 seed) public {
        uint8 support = uint8(3 + uint256(seed) % 253);
        _giveVotes(ALICE, QUORUM);
        uint256 id = _propose(0, "invalid support");
        _open(id);
        vm.expectRevert(abi.encodeWithSignature("InvalidSupport(uint8)", support));
        vm.prank(ALICE);
        gov.castVote(id, support);
        require(!gov.hasVoted(id, ALICE), "invalid vote consumed ballot");
        _assertVotes(id, 0, 0, 0);
        _vote(id, ALICE, 1, QUORUM);
    }

    function test_OnlyProposerCancelsPendingAndCanceledProposalCannotProgress() public {
        uint256 id = _propose(0, "cancel");
        vm.expectRevert(abi.encodeWithSignature("OnlyProposer(address)", ADMIN));
        vm.prank(ADMIN);
        gov.cancel(id);
        require(gov.state(id) == PENDING, "unauthorized cancellation");
        vm.warp(gov.proposalSnapshot(id));
        vm.expectEmit(false, false, false, true, address(gov));
        emit ProposalCanceled(id);
        vm.prank(PROPOSER);
        require(gov.cancel(id) == id, "cancel return id");
        require(gov.state(id) == CANCELED, "canceled state");
        _open(id);
        _expectState(id, CANCELED, ACTIVE);
        gov.castVote(id, 1);
        _finish(id);
        _expectState(id, CANCELED, SUCCEEDED);
        gov.queue(id);
        _expectState(id, CANCELED, QUEUED);
        gov.execute(id);
        _expectState(id, CANCELED, PENDING);
        vm.prank(PROPOSER);
        gov.cancel(id);
        bytes memory data = _data();
        vm.expectRevert(abi.encodeWithSignature("DuplicateProposal(uint256)", id));
        vm.prank(PROPOSER);
        gov.propose(address(target), 0, data, "cancel");
        _directExecutionMustFail(id, 0);
    }

    function test_ProposerCannotCancelActiveSucceededQueuedOrExecutedProposal() public {
        _giveVotes(ALICE, QUORUM);
        uint256 id = _propose(0, "late cancellation");
        _open(id);
        _expectState(id, ACTIVE, PENDING);
        vm.prank(PROPOSER);
        gov.cancel(id);
        _vote(id, ALICE, 1, QUORUM);
        _finish(id);
        _expectState(id, SUCCEEDED, PENDING);
        vm.prank(PROPOSER);
        gov.cancel(id);
        gov.queue(id);
        _expectState(id, QUEUED, PENDING);
        vm.prank(PROPOSER);
        gov.cancel(id);
        vm.warp(gov.proposalEta(id));
        gov.execute(id);
        _expectState(id, EXECUTED, PENDING);
        vm.prank(PROPOSER);
        gov.cancel(id);
    }

    function test_OnlyRealGovernorSchedulesAndAdminCannotRegainPower() public {
        uint256 id = _passed(0);
        gov.queue(id);
        bytes memory data = _data();
        bytes32 operation = _operation(id, 0);
        require(timelock.admin() == address(0) && timelock.governor() == address(gov), "bound roles");
        address[4] memory callers = [ADMIN, PROPOSER, ALICE, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            timelock.schedule(address(target), 0, data, bytes32(i), 2 days);
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            timelock.cancel(operation);
            vm.expectRevert(abi.encodeWithSignature("AlreadyBound()"));
            vm.prank(callers[i]);
            timelock.bind(callers[i]);
        }
        require(timelock.isOperationPending(operation), "unauthorized cancellation");
    }

    function test_PendingActiveAndUnqueuedPassedProposalCannotExecuteOnEitherContract() public {
        _giveVotes(ALICE, QUORUM);
        uint256 id = _propose(0, "no execution bypass");
        _expectState(id, PENDING, SUCCEEDED);
        gov.queue(id);
        _expectState(id, PENDING, QUEUED);
        gov.execute(id);
        _directExecutionMustFail(id, 0);
        _open(id);
        _expectState(id, ACTIVE, SUCCEEDED);
        gov.queue(id);
        _expectState(id, ACTIVE, QUEUED);
        gov.execute(id);
        _directExecutionMustFail(id, 0);
        _vote(id, ALICE, 1, QUORUM);
        _finish(id);
        _expectState(id, SUCCEEDED, QUEUED);
        gov.execute(id);
        _directExecutionMustFail(id, 0);
        gov.queue(id);
        _expectState(id, QUEUED, SUCCEEDED);
        gov.queue(id);
        _directExecutionMustFail(id, 0);
        require(target.calls() == 0, "proposal executed without a passed and mature operation");
    }

    function _directExecutionMustFail(uint256 id, uint256 value) internal {
        bytes memory data = _data();
        bytes32 operation = _operation(id, value);
        vm.expectRevert(abi.encodeWithSignature("OperationNotReady(bytes32)", operation));
        vm.prank(CAROL);
        timelock.execute(address(target), value, data, bytes32(id));
    }

    function test_DirectTimelockExecutionOfPassedMatureProposalCallsTargetOnce() public {
        uint256 id = _passed(1 ether);
        gov.queue(id);
        vm.warp(gov.proposalEta(id));
        vm.deal(address(timelock), 1 ether);
        bytes memory data = _data();
        vm.prank(CAROL);
        timelock.execute(address(target), 1 ether, data, bytes32(id));
        require(timelock.isOperationDone(_operation(id, 1 ether)), "direct execution done");
        require(target.calls() == 1 && target.received() == 1 ether, "direct execution target");
        _directExecutionMustFail(id, 1 ether);
        // The governor's failure to reflect this execution is reported in .imd-findings.json.
        // Do not assert its stale Queued state as correct behavior.
    }

    function test_TargetFailureRollsBackBothContractsAndAllowsRetry() public {
        uint256 id = _passed(1 ether);
        gov.queue(id);
        vm.warp(gov.proposalEta(id));
        vm.deal(address(timelock), 1 ether);
        target.setShouldRevert(true);
        vm.expectRevert(abi.encodeWithSelector(GovernorTarget.TargetRejected.selector, 42));
        gov.execute(id);
        require(gov.state(id) == QUEUED, "failed call consumed governor proposal");
        require(!timelock.isOperationDone(_operation(id, 1 ether)), "failed call consumed operation");
        require(target.calls() == 0 && address(timelock).balance == 1 ether, "failed call effects");
        target.setShouldRevert(false);
        gov.execute(id);
        require(gov.state(id) == EXECUTED && target.received() == 1 ether, "retry after target failure");
    }

    function test_ExecutionMarksGovernorBeforeCallAndRejectsReentrantReplay() public {
        uint256 id = _passed(0);
        target.setReentry(gov, id);
        gov.queue(id);
        vm.warp(gov.proposalEta(id));
        gov.execute(id);
        require(target.sawExecuted(), "governor execution flag set too late");
        require(!target.reentrySucceeded() && target.calls() == 1, "governor reentrant replay");
        bytes memory expected =
            abi.encodeWithSignature("UnexpectedProposalState(uint256,uint8,uint8)", id, EXECUTED, QUEUED);
        require(keccak256(target.reentryError()) == keccak256(expected), "reentry rejection");
        require(gov.state(id) == EXECUTED, "execution lost");
    }
}
