// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function warp(uint256 timestamp) external;
    function roll(uint256 blockNumber) external;
    function prank(address caller) external;
    function expectRevert(bytes calldata reason) external;
    function expectEmit(bool, bool, bool, bool, address emitter) external;
    function getCode(string calldata artifact) external view returns (bytes memory);
}

interface TokenUnderTest {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function delegate(address) external;
    function delegates(address) external view returns (address);
    function getVotes(address) external view returns (uint256);
    function getPastVotes(address, uint256) external view returns (uint256);
    function getPastTotalSupply(uint256) external view returns (uint256);
    function clock() external view returns (uint48);
    function CLOCK_MODE() external view returns (string memory);
}

contract GovTokenTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant START = 1_000_000;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    TokenUnderTest internal token;

    event DelegateChanged(address indexed delegator, address indexed fromDelegate, address indexed toDelegate);
    event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.warp(START);
        // Deploy the accepted implementation's compiled artifact, without copying it or importing dependencies.
        bytes memory code = abi.encodePacked(vm.getCode("src/GovToken.sol:GovToken"), abi.encode(address(this)));
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(code, 32), mload(code))
        }
        require(deployed != address(0), "token deployment failed");
        token = TokenUnderTest(deployed);
    }

    function test_MetadataSupplyAndUndelegatedBalances() public view {
        require(keccak256(bytes(token.name())) == keccak256("Gov Token"), "name");
        require(keccak256(bytes(token.symbol())) == keccak256("GOV"), "symbol");
        require(token.decimals() == 18, "decimals");
        require(token.totalSupply() == SUPPLY && token.balanceOf(address(this)) == SUPPLY, "initial supply");
        require(token.delegates(address(this)) == address(0), "implicit delegation");
        require(token.getVotes(address(this)) == 0 && token.getVotes(address(0)) == 0, "undelegated votes");
    }

    function test_ClockUsesSecondsNotBlocks() public {
        require(keccak256(bytes(token.CLOCK_MODE())) == keccak256("mode=timestamp"), "clock mode");
        vm.roll(block.number + 100_000);
        require(token.clock() == START, "block-based clock");
        vm.warp(START + 7);
        require(token.clock() == START + 7, "timestamp clock");
    }

    function test_DelegationEventsAndAggregatedVotes() public {
        token.transfer(ALICE, 100 ether);
        vm.expectEmit(true, true, true, true, address(token));
        emit DelegateChanged(address(this), address(0), BOB);
        vm.expectEmit(true, false, false, true, address(token));
        emit DelegateVotesChanged(BOB, 0, SUPPLY - 100 ether);
        token.delegate(BOB);
        vm.prank(ALICE);
        token.delegate(BOB);
        require(token.getVotes(BOB) == SUPPLY, "delegated balances must aggregate");
        require(token.balanceOf(BOB) == 0 && token.getVotes(ALICE) == 0, "votes are not balances");
        require(token.delegates(ALICE) == BOB, "delegate getter");
    }

    function test_TransferMovesVotesAndEmitsBothVoteChanges() public {
        token.delegate(address(this));
        vm.prank(ALICE);
        token.delegate(ALICE);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 17 ether);
        vm.expectEmit(true, false, false, true, address(token));
        emit DelegateVotesChanged(address(this), SUPPLY, SUPPLY - 17 ether);
        vm.expectEmit(true, false, false, true, address(token));
        emit DelegateVotesChanged(ALICE, 0, 17 ether);
        require(token.transfer(ALICE, 17 ether), "transfer result");
        require(token.getVotes(address(this)) == SUPPLY - 17 ether, "sender votes");
        require(token.getVotes(ALICE) == 17 ether, "receiver votes");
    }

    function test_RedelegationSameDelegateAndUndelegationDoNotDuplicateVotes() public {
        token.delegate(ALICE);
        token.delegate(ALICE);
        require(token.getVotes(ALICE) == SUPPLY, "repeat delegation duplicates votes");
        token.delegate(BOB);
        require(token.getVotes(ALICE) == 0 && token.getVotes(BOB) == SUPPLY, "redelegation");
        token.delegate(address(0));
        require(token.getVotes(BOB) == 0 && token.getVotes(address(0)) == 0, "undelegation");
        token.delegate(address(this));
        require(token.getVotes(address(this)) == SUPPLY, "self delegation");
    }

    function test_SelfTransferSharedDelegateAndZeroTransferPreserveVotes() public {
        token.delegate(BOB);
        vm.prank(ALICE);
        token.delegate(BOB);
        token.transfer(address(this), SUPPLY);
        require(token.balanceOf(address(this)) == SUPPLY, "self transfer balance");
        token.transfer(ALICE, 42 ether);
        token.transfer(CAROL, 0);
        require(token.getVotes(BOB) == SUPPLY, "same delegate transfer votes");
        require(token.getVotes(CAROL) == 0, "zero transfer votes");
    }

    function test_TransferToAndFromUndelegatedHolder() public {
        token.delegate(ALICE);
        token.transfer(BOB, 123 ether);
        require(token.getVotes(ALICE) == SUPPLY - 123 ether, "remove delegated votes");
        require(token.getVotes(BOB) == 0, "recipient has not delegated");
        vm.prank(BOB);
        token.transfer(address(this), 123 ether);
        require(token.getVotes(ALICE) == SUPPLY, "restore delegated votes");
    }

    function test_CheckpointsBeforeAtAndAfterTransferAndBeforeFirstCheckpoint() public {
        token.delegate(address(this));
        vm.prank(ALICE);
        token.delegate(ALICE);
        vm.warp(START + 10);
        token.transfer(ALICE, 100 ether);
        vm.warp(START + 20);
        token.transfer(ALICE, 50 ether);
        vm.warp(START + 30);
        require(token.getPastVotes(address(this), START - 1) == 0, "before first checkpoint");
        require(token.getPastVotes(CAROL, START + 10) == 0, "empty checkpoints");
        require(token.getPastVotes(address(this), START) == SUPPLY, "first checkpoint");
        require(token.getPastVotes(address(this), START + 9) == SUPPLY, "before transfer");
        require(token.getPastVotes(address(this), START + 10) == SUPPLY - 100 ether, "at transfer");
        require(token.getPastVotes(address(this), START + 11) == SUPPLY - 100 ether, "after transfer");
        require(token.getPastVotes(ALICE, START + 9) == 0, "recipient before transfer");
        require(token.getPastVotes(ALICE, START + 10) == 100 ether, "recipient at transfer");
        require(token.getPastVotes(ALICE, START + 19) == 100 ether, "between checkpoints");
        require(token.getPastVotes(ALICE, START + 20) == 150 ether, "last checkpoint");
        require(token.getPastVotes(ALICE, START + 29) == 150 ether, "after last checkpoint");
    }

    function test_SameTimestampUsesFinalVotesForTransfersAndRedelegations() public {
        token.delegate(ALICE);
        vm.warp(START + 10);
        token.transfer(BOB, 100 ether);
        vm.prank(BOB);
        token.delegate(ALICE);
        token.delegate(CAROL);
        vm.prank(BOB);
        token.delegate(CAROL);
        vm.warp(START + 11);
        require(token.getPastVotes(ALICE, START + 9) == SUPPLY, "previous votes overwritten");
        require(token.getPastVotes(ALICE, START + 10) == 0, "stale same-second votes");
        require(token.getPastVotes(CAROL, START + 10) == SUPPLY, "last same-second votes");
    }

    function test_SupplyHistoryBeforeMintAtMintAndAfterTransfers() public {
        token.transfer(ALICE, 1);
        token.delegate(BOB);
        vm.warp(START + 100);
        require(token.getPastTotalSupply(START - 1) == 0, "supply before mint");
        require(token.getPastTotalSupply(START) == SUPPLY, "supply at mint");
        require(token.getPastTotalSupply(START + 99) == SUPPLY, "fixed historical supply");
    }

    function test_CurrentAndFutureLookupsRevertEvenForEmptyHistory() public {
        for (uint256 i; i < 3; ++i) {
            uint256 timepoint = i == 2 ? type(uint256).max : START + i;
            bytes memory reason =
                abi.encodeWithSignature("ERC5805FutureLookup(uint256,uint48)", timepoint, uint48(START));
            vm.expectRevert(reason);
            token.getPastVotes(ALICE, timepoint);
            vm.expectRevert(reason);
            token.getPastTotalSupply(timepoint);
        }
    }

    function test_TransferFromSpendsAllowanceAndMovesDelegatedVotes() public {
        token.delegate(ALICE);
        vm.prank(BOB);
        token.delegate(BOB);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), CAROL, 100 ether);
        require(token.approve(CAROL, 100 ether), "approve result");
        vm.prank(CAROL);
        require(token.transferFrom(address(this), BOB, 40 ether), "transferFrom result");
        require(token.allowance(address(this), CAROL) == 60 ether, "spent allowance");
        require(token.getVotes(ALICE) == SUPPLY - 40 ether && token.getVotes(BOB) == 40 ether, "transferFrom votes");
        token.approve(CAROL, type(uint256).max);
        vm.prank(CAROL);
        token.transferFrom(address(this), BOB, 1);
        require(token.allowance(address(this), CAROL) == type(uint256).max, "infinite allowance");
    }

    function test_InsufficientAllowanceAndBalanceRevertWithoutChangingState() public {
        token.delegate(ALICE);
        token.approve(CAROL, 10);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientAllowance(address,uint256,uint256)", CAROL, 10, 11));
        vm.prank(CAROL);
        token.transferFrom(address(this), BOB, 11);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", BOB, 0, 1));
        vm.prank(BOB);
        token.transfer(ALICE, 1);
        vm.prank(BOB);
        token.approve(CAROL, 5);
        vm.expectRevert(abi.encodeWithSignature("ERC20InsufficientBalance(address,uint256,uint256)", BOB, 0, 5));
        vm.prank(CAROL);
        token.transferFrom(BOB, ALICE, 5);
        require(token.allowance(BOB, CAROL) == 5, "failed transfer spent allowance");
        require(token.allowance(address(this), CAROL) == 10, "failed allowance changed state");
        require(
            token.getVotes(ALICE) == SUPPLY && token.balanceOf(address(this)) == SUPPLY, "failed transfer changed votes"
        );
    }

    function test_ZeroAddressTransferAndApprovalRevert() public {
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidSpender(address)", address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSignature("ERC20InvalidSender(address)", address(0)));
        token.transferFrom(address(0), ALICE, 0);
        require(token.totalSupply() == SUPPLY, "failed burn changed supply");
    }

    function testFuzz_TransfersAndRedelegationMatchIndependentLedger(uint256 seed) public {
        address[4] memory accounts = [address(this), ALICE, BOB, CAROL];
        uint256[4] memory balances = [SUPPLY, uint256(0), uint256(0), uint256(0)];
        address[4] memory delegatees;
        uint256[4][16] memory history;
        for (uint256 step; step < 16; ++step) {
            vm.warp(START + step * 10);
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 from = seed % 4;
            uint256 to = (seed >> 8) % 4;
            if ((seed >> 16) % 2 == 0) {
                uint256 amount = (seed >> 24) % (balances[from] + 1);
                vm.prank(accounts[from]);
                token.transfer(accounts[to], amount);
                balances[from] -= amount;
                balances[to] += amount;
            } else {
                address delegatee = (seed >> 24) % 5 == 0 ? address(0) : accounts[to];
                vm.prank(accounts[from]);
                token.delegate(delegatee);
                delegatees[from] = delegatee;
            }
            uint256 votesSum;
            for (uint256 i; i < 4; ++i) {
                uint256 expected;
                for (uint256 j; j < 4; ++j) {
                    if (delegatees[j] == accounts[i]) expected += balances[j];
                }
                require(token.balanceOf(accounts[i]) == balances[i], "ledger balance");
                require(token.getVotes(accounts[i]) == expected, "ledger delegated votes");
                require(token.delegates(accounts[i]) == delegatees[i], "ledger delegatee");
                history[step][i] = expected;
                votesSum += expected;
            }
            require(votesSum <= SUPPLY && token.getVotes(address(0)) == 0, "duplicated votes");
        }
        vm.warp(START + 160);
        for (uint256 step; step < 16; ++step) {
            for (uint256 i; i < 4; ++i) {
                require(
                    token.getPastVotes(accounts[i], START + step * 10) == history[step][i],
                    "historical ledger at checkpoint"
                );
                require(
                    token.getPastVotes(accounts[i], START + step * 10 + 9) == history[step][i],
                    "historical ledger between checkpoints"
                );
            }
        }
    }
}
