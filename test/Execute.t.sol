// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";
import { IndexedStrategy, ProposalStatus, Strategy } from "../src/types.sol";

contract ExecuteTest is SpaceTest {
    function _rollPastMax() internal {
        vm.roll(vm.getBlockNumber() + space.maxVotingDuration() + 1);
    }

    function testExecutePasses() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();

        _reveal(proposalId);
        (uint256 against, uint256 forV, uint256 abstain, bool passed) = space.result(proposalId);
        assertEq(against, 0);
        assertEq(forV, 1);
        assertEq(abstain, 0);
        assertTrue(passed);

        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(proposalId);
        space.execute(proposalId, executionStrategy.params);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Executed));
    }

    function testExecuteBeforeRevealReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        vm.expectRevert(NotRevealed.selector);
        space.execute(proposalId, executionStrategy.params);
    }

    function testExecuteAlreadyExecuted() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        space.execute(proposalId, executionStrategy.params);
        vm.expectRevert(ProposalFinalized.selector);
        space.execute(proposalId, executionStrategy.params);
    }

    function testExecuteWithAgainstVoteRejected() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 0, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        (uint256 against, , , bool passed) = space.result(proposalId);
        assertEq(against, 1);
        assertFalse(passed);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected));
        vm.expectRevert(ProposalNotPassed.selector);
        space.execute(proposalId, executionStrategy.params);
    }

    function testExecuteWithAbstainVoteRejected() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 2, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        (, , uint256 abstain, bool passed) = space.result(proposalId);
        assertEq(abstain, 1);
        assertFalse(passed); // quorum reached (abstain counts) but no support
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected));
    }

    function testExecuteZeroVotesRejected() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _rollPastMax();
        _reveal(proposalId);
        (uint256 against, uint256 forV, uint256 abstain, bool passed) = space.result(proposalId);
        assertEq(against + forV + abstain, 0);
        assertFalse(passed);
        assertEq(uint8(space.getProposalStatus(proposalId)), uint8(ProposalStatus.Rejected));
    }

    function testExecuteInvalidPayload() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        vm.expectRevert(InvalidPayload.selector);
        space.execute(proposalId, new bytes(4242));
    }

    function testGetStrategyType() external view {
        assertEq(vanillaExecutionStrategy.getStrategyType(), "SimpleQuorumVanilla");
    }
}
