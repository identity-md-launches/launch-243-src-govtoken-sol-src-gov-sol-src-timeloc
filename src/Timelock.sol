// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice A single-action timelock with a fixed delay and one-time governor binding.
contract Timelock {
    uint256 public constant MIN_DELAY = 2 days;
    uint256 private constant DONE_TIMESTAMP = 1;

    address public admin;
    address public governor;

    // Zero means unset, one means executed, and all other values are ready timestamps.
    mapping(bytes32 => uint256) private _timestamps;

    error Unauthorized();
    error InvalidAddress();
    error AlreadyBound();
    error InsufficientDelay(uint256 delay, uint256 minimum);
    error OperationAlreadyScheduled(bytes32 id);
    error OperationNotReady(bytes32 id);
    error OperationNotPending(bytes32 id);

    event GovernorBound(address indexed governor);
    event CallScheduled(
        bytes32 indexed id, address indexed target, uint256 value, bytes data, bytes32 salt, uint256 delay
    );
    event CallExecuted(bytes32 indexed id, address indexed target, uint256 value, bytes data);
    event Cancelled(bytes32 indexed id);

    constructor(address admin_) {
        if (admin_ == address(0)) revert InvalidAddress();
        admin = admin_;
    }

    modifier onlyGovernor() {
        if (governor == address(0) || msg.sender != governor) revert Unauthorized();
        _;
    }

    function bind(address governor_) external {
        if (governor != address(0)) revert AlreadyBound();
        if (msg.sender != admin) revert Unauthorized();
        if (governor_ == address(0)) revert InvalidAddress();
        governor = governor_;
        delete admin;
        emit GovernorBound(governor_);
    }

    function clock() public view returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure returns (string memory) {
        return "mode=timestamp";
    }

    function getMinDelay() public pure returns (uint256) {
        return MIN_DELAY;
    }

    function hashOperation(address target, uint256 value, bytes calldata data, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data, salt));
    }

    /// @notice Returns zero for unset operations, one for done operations, otherwise the ready time.
    function getTimestamp(bytes32 id) public view returns (uint256) {
        return _timestamps[id];
    }

    function isOperation(bytes32 id) public view returns (bool) {
        return _timestamps[id] != 0;
    }

    /// @notice Pending includes operations that are ready but have not been executed.
    function isOperationPending(bytes32 id) public view returns (bool) {
        return _timestamps[id] > DONE_TIMESTAMP;
    }

    function isOperationReady(bytes32 id) public view returns (bool) {
        uint256 timestamp = _timestamps[id];
        return timestamp > DONE_TIMESTAMP && timestamp <= block.timestamp;
    }

    function isOperationDone(bytes32 id) public view returns (bool) {
        return _timestamps[id] == DONE_TIMESTAMP;
    }

    function schedule(address target, uint256 value, bytes calldata data, bytes32 salt, uint256 delay)
        external
        onlyGovernor
    {
        bytes32 id = hashOperation(target, value, data, salt);
        if (isOperation(id)) revert OperationAlreadyScheduled(id);
        if (delay < MIN_DELAY) revert InsufficientDelay(delay, MIN_DELAY);
        _timestamps[id] = block.timestamp + delay;
        emit CallScheduled(id, target, value, data, salt, delay);
    }

    function execute(address target, uint256 value, bytes calldata data, bytes32 salt) external payable {
        bytes32 id = hashOperation(target, value, data, salt);
        if (!isOperationReady(id)) revert OperationNotReady(id);

        // Prevent replay during the target call. A failed call rolls this write back.
        _timestamps[id] = DONE_TIMESTAMP;
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returndata, 0x20), mload(returndata))
            }
        }
        emit CallExecuted(id, target, value, data);
    }

    function cancel(bytes32 id) external onlyGovernor {
        if (!isOperationPending(id)) revert OperationNotPending(id);
        // As with OpenZeppelin, cancellation makes an id available for scheduling again.
        delete _timestamps[id];
        emit Cancelled(id);
    }

    receive() external payable {}
}
