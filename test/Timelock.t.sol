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

interface TimelockUnderTest {
    function admin() external view returns (address);
    function governor() external view returns (address);
    function MIN_DELAY() external view returns (uint256);
    function getMinDelay() external view returns (uint256);
    function clock() external view returns (uint48);
    function CLOCK_MODE() external view returns (string memory);
    function bind(address governor) external;
    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 salt)
        external
        pure
        returns (bytes32);
    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt, uint256 delay) external;
    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external payable;
    function cancel(bytes32 id) external;
    function getTimestamp(bytes32 id) external view returns (uint256);
    function isOperation(bytes32 id) external view returns (bool);
    function isOperationPending(bytes32 id) external view returns (bool);
    function isOperationReady(bytes32 id) external view returns (bool);
    function isOperationDone(bytes32 id) external view returns (bool);
}

contract TimelockTarget {
    uint256 public calls;
    uint256 public stored;
    uint256 public received;
    address public caller;
    bool public shouldRevert;
    bool public doneDuringCall;
    bool public reentrySucceeded;
    bytes public reentryError;

    error TargetRejected(uint256 value);

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function store(uint256 value) external payable {
        if (shouldRevert) revert TargetRejected(value);
        ++calls;
        stored = value;
        caller = msg.sender;
        received += msg.value;
    }

    function revertEmpty() external pure {
        assembly ("memory-safe") {
            revert(0, 0)
        }
    }

    function reenter(address lock, bytes32 salt) external {
        ++calls;
        bytes memory data = abi.encodeCall(this.reenter, (lock, salt));
        bytes32 id = keccak256(abi.encode(address(this), uint256(0), data, salt));
        doneDuringCall = TimelockUnderTest(lock).isOperationDone(id);
        (reentrySucceeded, reentryError) =
            lock.call(abi.encodeCall(TimelockUnderTest.execute, (address(this), 0, data, salt)));
    }
}

contract TimelockTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant START = 1_000_000;
    uint256 internal constant DELAY = 2 days;
    address internal constant ADMIN = address(0xAD01);
    // Impersonation is limited to this unit suite; Gov.t.sol exercises the real governor.
    address internal constant GOVERNOR = address(0x600D);
    address internal constant STRANGER = address(0xBAD);
    bytes32 internal constant SALT = keccak256("timelock test");
    TimelockUnderTest internal timelock;
    TimelockTarget internal target;

    event GovernorBound(address indexed governor);
    event CallScheduled(
        bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes32 salt, uint256 delay
    );
    event CallExecuted(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id);

    function setUp() public {
        vm.warp(START);
        timelock = _deploy(ADMIN);
        vm.prank(ADMIN);
        timelock.bind(GOVERNOR);
        target = new TimelockTarget();
    }

    function _deploy(address admin) internal returns (TimelockUnderTest) {
        bytes memory code = abi.encodePacked(vm.getCode("src/Timelock.sol:Timelock"), abi.encode(admin));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "timelock deployment failed");
        return TimelockUnderTest(deployed);
    }

    function _data() internal view returns (bytes memory) {
        return abi.encodeCall(target.store, (42));
    }

    function _id(uint256 value, bytes memory data, bytes32 salt) internal view returns (bytes32) {
        return keccak256(abi.encode(address(target), value, data, salt));
    }

    function _schedule(uint256 value, bytes memory data, bytes32 salt) internal returns (bytes32 id) {
        id = _id(value, data, salt);
        vm.prank(GOVERNOR);
        timelock.schedule(address(target), value, data, salt, DELAY);
    }

    function _expectNotReady(address destination, uint256 value, bytes memory data, bytes32 salt) internal {
        bytes32 id = keccak256(abi.encode(destination, value, data, salt));
        vm.expectRevert(abi.encodeWithSignature("OperationNotReady(bytes32)", id));
        timelock.execute(destination, value, data, salt);
    }

    function test_FixedDelayAndTimestampClock() public {
        require(timelock.MIN_DELAY() == DELAY && timelock.getMinDelay() == DELAY, "fixed delay");
        require(keccak256(bytes(timelock.CLOCK_MODE())) == keccak256("mode=timestamp"), "clock mode");
        vm.roll(block.number + 1_000_000);
        require(timelock.clock() == START, "block-based clock");
        vm.warp(START + 1);
        require(timelock.clock() == START + 1, "timestamp clock");
    }

    function test_BindOnlyAdminOnceAndRejectZeroWithoutConsumingBind() public {
        TimelockUnderTest fresh = _deploy(ADMIN);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        vm.prank(STRANGER);
        fresh.bind(STRANGER);
        vm.expectRevert(abi.encodeWithSignature("InvalidAddress()"));
        vm.prank(ADMIN);
        fresh.bind(address(0));
        require(fresh.admin() == ADMIN && fresh.governor() == address(0), "failed bind mutated roles");
        vm.expectEmit(true, false, false, true, address(fresh));
        emit GovernorBound(GOVERNOR);
        vm.prank(ADMIN);
        fresh.bind(GOVERNOR);
        require(fresh.admin() == address(0) && fresh.governor() == GOVERNOR, "admin retained authority");
        address[3] memory callers = [ADMIN, GOVERNOR, STRANGER];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("AlreadyBound()"));
            vm.prank(callers[i]);
            fresh.bind(STRANGER);
        }
        require(fresh.governor() == GOVERNOR, "governor changed");
    }

    function test_UnboundTimelockHasNoProposerOrCanceller() public {
        TimelockUnderTest fresh = _deploy(ADMIN);
        bytes memory data = _data();
        address[3] memory callers = [ADMIN, STRANGER, address(0)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            fresh.schedule(address(target), 0, data, SALT, DELAY);
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            fresh.cancel(_id(0, data, SALT));
        }
    }

    function test_OnlyGovernorCanScheduleAndCancelAfterBinding() public {
        bytes memory data = _data();
        bytes32 id = _schedule(0, data, SALT);
        address[3] memory callers = [ADMIN, STRANGER, address(this)];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            timelock.schedule(address(target), 0, data, bytes32(i), DELAY);
            vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
            vm.prank(callers[i]);
            timelock.cancel(id);
        }
        require(timelock.isOperationPending(id), "unauthorized cancellation");
    }

    function testFuzz_ShortDelayReverts(uint256 delay) public {
        delay %= DELAY;
        bytes memory data = _data();
        vm.expectRevert(abi.encodeWithSignature("InsufficientDelay(uint256,uint256)", delay, DELAY));
        vm.prank(GOVERNOR);
        timelock.schedule(address(target), 0, data, SALT, delay);
        require(!timelock.isOperation(_id(0, data, SALT)), "failed scheduling reserved id");
    }

    function test_ScheduleHashEventAndDuplicateRejection() public {
        bytes memory data = _data();
        bytes32 id = _id(1 ether, data, SALT);
        require(timelock.hashOperation(address(target), 1 ether, data, SALT) == id, "operation hash");
        vm.expectEmit(true, true, false, true, address(timelock));
        emit CallScheduled(id, address(target), 1 ether, data, SALT, DELAY);
        _schedule(1 ether, data, SALT);
        require(timelock.getTimestamp(id) == START + DELAY, "ready time");
        require(timelock.isOperation(id) && timelock.isOperationPending(id), "pending operation");
        require(!timelock.isOperationReady(id) && !timelock.isOperationDone(id), "premature readiness");
        vm.expectRevert(abi.encodeWithSignature("OperationAlreadyScheduled(bytes32)", id));
        vm.prank(GOVERNOR);
        timelock.schedule(address(target), 1 ether, data, SALT, DELAY);
    }

    function test_LongDelayIsHonored() public {
        bytes memory data = _data();
        vm.prank(GOVERNOR);
        timelock.schedule(address(target), 0, data, SALT, DELAY + 99);
        vm.warp(START + DELAY);
        _expectNotReady(address(target), 0, data, SALT);
        vm.warp(START + DELAY + 99);
        timelock.execute(address(target), 0, data, SALT);
        require(target.calls() == 1, "long delay execution");
    }

    function test_AnyoneExecutesAtExactReadyTimeWithETHAndCannotReplay() public {
        bytes memory data = _data();
        bytes32 id = _schedule(1 ether, data, SALT);
        vm.deal(address(this), 1 ether);
        (bool funded,) = address(timelock).call{value: 1 ether}("");
        require(funded && address(timelock).balance == 1 ether, "receive ETH");
        vm.warp(START + DELAY - 1);
        _expectNotReady(address(target), 1 ether, data, SALT);
        require(timelock.isOperationPending(id) && target.calls() == 0, "early execute changed state");
        vm.warp(START + DELAY);
        require(timelock.isOperationReady(id), "exact ready boundary");
        vm.expectEmit(true, true, false, true, address(timelock));
        emit CallExecuted(id, address(target), 1 ether, data);
        vm.prank(STRANGER);
        timelock.execute(address(target), 1 ether, data, SALT);
        require(target.stored() == 42 && target.calls() == 1, "target call");
        require(target.caller() == address(timelock) && target.received() == 1 ether, "target sender and value");
        require(address(target).balance == 1 ether && address(timelock).balance == 0, "ETH balances");
        require(timelock.isOperationDone(id) && !timelock.isOperationPending(id), "done state");
        _expectNotReady(address(target), 1 ether, data, SALT);
        vm.expectRevert(abi.encodeWithSignature("OperationAlreadyScheduled(bytes32)", id));
        vm.prank(GOVERNOR);
        timelock.schedule(address(target), 1 ether, data, SALT, DELAY);
        vm.expectRevert(abi.encodeWithSignature("OperationNotPending(bytes32)", id));
        vm.prank(GOVERNOR);
        timelock.cancel(id);
    }

    function test_ExecuteAcceptsETHFromExecutor() public {
        bytes memory data = _data();
        _schedule(1 ether, data, SALT);
        vm.warp(START + DELAY);
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        timelock.execute{value: 1 ether}(address(target), 1 ether, data, SALT);
        require(target.received() == 1 ether && STRANGER.balance == 0, "payable execution");
    }

    function test_UnscheduledAndAlteredOperationsCannotExecute() public {
        bytes memory data = _data();
        _expectNotReady(address(target), 0, data, SALT);
        bytes32 id = _schedule(0, data, SALT);
        vm.warp(START + DELAY);
        _expectNotReady(STRANGER, 0, data, SALT);
        _expectNotReady(address(target), 1, data, SALT);
        _expectNotReady(address(target), 0, abi.encodeCall(target.store, (43)), SALT);
        _expectNotReady(address(target), 0, data, bytes32(uint256(SALT) ^ 1));
        require(timelock.isOperationReady(id) && target.calls() == 0, "altered operation affected original");
        timelock.execute(address(target), 0, data, SALT);
        require(target.stored() == 42, "original data");
    }

    function test_CancelPendingOrReadyOperationsPreventsExecution() public {
        bytes memory data = _data();
        bytes32 first = _schedule(0, data, SALT);
        bytes32 secondSalt = keccak256("ready cancellation");
        bytes32 second = _schedule(0, data, secondSalt);
        vm.expectEmit(true, false, false, true, address(timelock));
        emit Cancelled(first);
        vm.prank(GOVERNOR);
        timelock.cancel(first);
        require(!timelock.isOperation(first) && timelock.getTimestamp(first) == 0, "cancel clears pending");
        vm.warp(START + DELAY);
        vm.prank(GOVERNOR);
        timelock.cancel(second);
        _expectNotReady(address(target), 0, data, SALT);
        _expectNotReady(address(target), 0, data, secondSalt);
        vm.expectRevert(abi.encodeWithSignature("OperationNotPending(bytes32)", first));
        vm.prank(GOVERNOR);
        timelock.cancel(first);
        bytes32 unknown = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSignature("OperationNotPending(bytes32)", unknown));
        vm.prank(GOVERNOR);
        timelock.cancel(unknown);
        // Reusing a canceled id requires a fresh full delay, as in OZ v5.
        _schedule(0, data, SALT);
        require(timelock.getTimestamp(first) == START + 2 * DELAY, "reschedule bypassed delay");
        _expectNotReady(address(target), 0, data, SALT);
    }

    function test_TargetRevertBubblesAndOperationCanBeRetried() public {
        bytes memory data = _data();
        bytes32 id = _schedule(1 ether, data, SALT);
        vm.deal(address(timelock), 1 ether);
        vm.warp(START + DELAY);
        target.setShouldRevert(true);
        vm.expectRevert(abi.encodeWithSelector(TimelockTarget.TargetRejected.selector, 42));
        timelock.execute(address(target), 1 ether, data, SALT);
        require(timelock.isOperationReady(id) && !timelock.isOperationDone(id), "revert consumed operation");
        require(address(timelock).balance == 1 ether && target.calls() == 0, "revert lost ETH or changed target");
        target.setShouldRevert(false);
        timelock.execute(address(target), 1 ether, data, SALT);
        require(timelock.isOperationDone(id) && target.received() == 1 ether, "retry");
    }

    function test_EmptyRevertDataAndInsufficientETHDoNotConsumeOperation() public {
        bytes memory data = abi.encodeCall(target.revertEmpty, ());
        bytes32 id = _schedule(0, data, SALT);
        bytes memory payableData = _data();
        bytes32 payableId = _schedule(1 ether, payableData, SALT);
        vm.warp(START + DELAY);
        vm.expectRevert(bytes(""));
        timelock.execute(address(target), 0, data, SALT);
        vm.expectRevert(bytes(""));
        timelock.execute(address(target), 1 ether, payableData, SALT);
        require(timelock.isOperationReady(id) && timelock.isOperationReady(payableId), "failed call consumed operation");
        vm.deal(address(timelock), 1 ether);
        timelock.execute(address(target), 1 ether, payableData, SALT);
        require(target.received() == 1 ether, "funded retry");
    }

    function test_DoneIsRecordedBeforeCallAndReentrantReplayFails() public {
        bytes memory data = abi.encodeCall(target.reenter, (address(timelock), SALT));
        bytes32 id = _schedule(0, data, SALT);
        vm.warp(START + DELAY);
        timelock.execute(address(target), 0, data, SALT);
        require(target.doneDuringCall(), "done must precede target call");
        require(!target.reentrySucceeded() && target.calls() == 1, "reentrant replay succeeded");
        require(
            keccak256(target.reentryError()) == keccak256(abi.encodeWithSignature("OperationNotReady(bytes32)", id)),
            "reentry failure reason"
        );
        require(timelock.isOperationDone(id), "outer execution not done");
    }
}
