// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";
import { IndexedStrategy, Proposal, ProposalStatus, Strategy, UpdateSettingsCalldata } from "../src/types.sol";
import { EmergencyQuorumExecutionStrategy } from "../src/execution-strategies/EmergencyQuorumExecutionStrategy.sol";

contract EmergencyQuorumExec is EmergencyQuorumExecutionStrategy {
    uint256 internal numExecuted;

    constructor(address _owner, uint256 _quorum, uint256 _emergencyQuorum) {
        setUp(abi.encode(_owner, _quorum, _emergencyQuorum));
    }

    function setUp(bytes memory initParams) public initializer {
        (address _owner, uint256 _quorum, uint256 _emergencyQuorum) = abi.decode(
            initParams,
            (address, uint256, uint256)
        );
        __Ownable_init(_owner);
        __EmergencyQuorumExecutionStrategy_init(_quorum, _emergencyQuorum);
    }

    function execute(
        uint256 /* proposalId */,
        Proposal memory proposal,
        bool quorumReached,
        bool supportAchieved,
        bytes memory /* payload */
    ) external override {
        ProposalStatus proposalStatus = getProposalStatus(proposal, quorumReached, supportAchieved);
        if ((proposalStatus != ProposalStatus.Accepted) && (proposalStatus != ProposalStatus.VotingPeriodAccepted)) {
            revert InvalidProposalStatus(proposalStatus);
        }
        numExecuted++;
    }

    function getStrategyType() external pure returns (string memory) {
        return "EmergencyQuorumExecution";
    }
}

contract EmergencyQuorumTest is SpaceTest {
    event EmergencyQuorumUpdated(uint256 newEmergencyQuorum);
    event QuorumUpdated(uint256 newQuorum);

    Strategy internal emergencyStrategy;
    uint256 internal emergencyQuorum = 2;
    EmergencyQuorumExec internal emergency;

    function setUp() public override {
        super.setUp();

        emergency = new EmergencyQuorumExec(spaceOwner, quorum, emergencyQuorum);
        emergencyStrategy = Strategy(address(emergency), new bytes(0));

        minVotingDuration = 100;
        space.updateSettings(
            UpdateSettingsCalldata(
                minVotingDuration,
                NO_UPDATE_UINT32,
                NO_UPDATE_UINT32,
                NO_UPDATE_STRING,
                NO_UPDATE_STRING,
                NO_UPDATE_STRATEGY,
                NO_UPDATE_STRING,
                NO_UPDATE_ADDRESSES,
                NO_UPDATE_ADDRESSES,
                NO_UPDATE_STRATEGIES,
                NO_UPDATE_STRINGS,
                NO_UPDATE_UINT8S
            )
        );
    }

    function testEmergencyQuorum() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1
        _vote(address(42), proposalId, 1, userVotingStrategies, voteMetadataURI); // 2
        vm.roll(vm.getBlockNumber() + minVotingDuration);

        _reveal(proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, emergencyStrategy.params);

        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Executed));
    }

    function testEmergencyQuorumNotReached() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        // A single AGAINST vote fails quorum/support -> not executable.
        _vote(author, proposalId, 0, userVotingStrategies, voteMetadataURI);
        _reveal(proposalId);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected));
        vm.expectRevert(ProposalNotPassed.selector);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testEmergencyQuorumAfterMinDuration() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1

        vm.roll(vm.getBlockNumber() + minVotingDuration);

        _reveal(proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testEmergencyQuorumAfterMaxDuration() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1

        vm.roll(vm.getBlockNumber() + maxVotingDuration);

        _reveal(proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testEmergencyQuorumReachedButRejected() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        // Only AGAINST votes -> fails support, rejected once voting ends.
        _vote(author, proposalId, 0, userVotingStrategies, voteMetadataURI);
        _vote(address(42), proposalId, 0, userVotingStrategies, voteMetadataURI);
        _reveal(proposalId);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected));
        vm.expectRevert(ProposalNotPassed.selector);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testEmergencyQuorumLowerThanQuorum() public {
        EmergencyQuorumExec emergencyQuorumExec = new EmergencyQuorumExec(spaceOwner, quorum, quorum - 1);

        emergencyStrategy = Strategy(address(emergencyQuorumExec), new bytes(0));

        // Create proposal and vote
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // emergencyQuorum reached
        vm.roll(vm.getBlockNumber() + maxVotingDuration);

        _reveal(proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testEmergencyQuorumVotingPeriod() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );

        // Cast two votes AGAINST
        _vote(author, proposalId, 0, userVotingStrategies, voteMetadataURI); // 1
        _vote(address(42), proposalId, 0, userVotingStrategies, voteMetadataURI); // 2

        // EmergencyQuorum should've been reached but with only `AGAINST` votes, so proposal status should be
        // `VotingPeriod`. _tryExecute won't revert, just won't execute.
        _tryExecute(proposalId, emergencyStrategy.params);
        assertTrue(uint8(space.getProposalStatus(proposalId)) != uint8(ProposalStatus.Executed));
    }

    function testEmergencyQuorumCancelled() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1

        space.cancel(proposalId);

        // A cancelled proposal cannot be revealed (or executed).
        vm.expectRevert(ProposalFinalized.selector);
        space.requestReveal(proposalId);
    }

    function testEmergencyQuorumAlreadyExecuted() public {
        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1

        vm.roll(vm.getBlockNumber() + minVotingDuration);

        _tryExecute(proposalId, emergencyStrategy.params);

        vm.expectRevert(ProposalFinalized.selector);
        space.execute(proposalId, emergencyStrategy.params);
    }

    function testGetStrategyType() public view {
        assertEq(emergency.getStrategyType(), "EmergencyQuorumExecution");
    }

    function testEmergencyQuorumSetEmergencyQuorum() public {
        uint256 newEmergencyQuorum = 4; // emergencyQuorum * 2

        vm.expectEmit(true, true, true, true);
        emit EmergencyQuorumUpdated(newEmergencyQuorum);
        emergency.setEmergencyQuorum(newEmergencyQuorum);

        uint256 proposalId = _createProposal(
            author,
            proposalMetadataURI,
            emergencyStrategy,
            abi.encode(userVotingStrategies)
        );
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // 1
        _vote(address(42), proposalId, 1, userVotingStrategies, voteMetadataURI); // 2
        vm.roll(vm.getBlockNumber() + minVotingDuration);

        // Under the current flow, execution is driven by quorum/support + voting-period state.
        _reveal(proposalId);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, emergencyStrategy.params);

        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Executed));
    }

    function testEmergencyQuorumSetEmergencyQuorumUnauthorized() public {
        uint256 newEmergencyQuorum = 4; // emergencyQuorum * 2
        vm.prank(address(0xdeadbeef));
        _expectOnlyOwnerRevert(address(0xdeadbeef));
        emergency.setEmergencyQuorum(newEmergencyQuorum);
    }

    function testEmergencyQuorumSetQuorum() public {
        uint256 newQuorum = quorum * 2; // 2
        vm.expectEmit(true, true, true, true);
        emit QuorumUpdated(newQuorum);
        emergency.setQuorum(newQuorum);

        // One vote is below the new quorum of 2 -> rejected.
        uint256 p1 = _createProposal(author, proposalMetadataURI, emergencyStrategy, abi.encode(userVotingStrategies));
        _vote(author, p1, 1, userVotingStrategies, voteMetadataURI);
        _reveal(p1);
        assertEq(uint8(space.getProposalStatus(p1)), uint8(ProposalStatus.Rejected));

        // Two votes meet the new quorum -> executes.
        // Use voters distinct from p1's to keep each mock ciphertext handle unique.
        uint256 p2 = _createProposal(author, proposalMetadataURI, emergencyStrategy, abi.encode(userVotingStrategies));
        _vote(address(11), p2, 1, userVotingStrategies, voteMetadataURI);
        _vote(address(42), p2, 1, userVotingStrategies, voteMetadataURI);
        _reveal(p2);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(p2);
        space.execute(p2, emergencyStrategy.params);
        assertEq(uint8(space.getProposalStatus(p2)), uint8(ProposalStatus.Executed));
    }

    function testEmergencyQuorumSetQuorumUnauthorized() public {
        uint256 newQuorum = quorum * 2; // 2
        vm.prank(address(0xdeadbeef));
        _expectOnlyOwnerRevert(address(0xdeadbeef));
        emergency.setQuorum(newQuorum);
    }
}
