// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";
import { euint256, inco } from "@inco/lightning/src/Lib.sol";

contract RevealTest is SpaceTest {
    function _rollPastMax() internal {
        vm.roll(vm.getBlockNumber() + space.maxVotingDuration() + 1);
    }

    function testRequestRevealBeforeVotingEndsReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        vm.expectRevert(VotingPeriodNotEnded.selector);
        space.requestReveal(proposalId);
    }

    function testFinalizeRevealBeforeVotingEndsReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        // The voting-end gate must fire before any attestation verification.
        vm.expectRevert(VotingPeriodNotEnded.selector);
        _finalizeRevealEmpty(proposalId);
    }

    function testRequestRevealCancelledProposalReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        space.cancel(proposalId);
        // A cancelled proposal can never be revealed, regardless of timing.
        vm.expectRevert(ProposalFinalized.selector);
        space.requestReveal(proposalId);
    }

    function testRunningTallyNotDecryptableByAuthorDuringVoting() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        (euint256 against, euint256 forH, euint256 abstain) = space.getVoteTallyHandles(proposalId);
        // No EOA (author, voter) may decrypt the running tallies — only the contract.
        assertFalse(inco.isAllowed(euint256.unwrap(forH), author));
        assertFalse(inco.isAllowed(euint256.unwrap(forH), voter));
        assertFalse(inco.isAllowed(euint256.unwrap(against), author));
        assertFalse(inco.isAllowed(euint256.unwrap(abstain), author));
        assertTrue(inco.isAllowed(euint256.unwrap(forH), address(space)));
    }

    function testRevealGrantsAccessAfterVotingEnds() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        space.requestReveal(proposalId); // msg.sender == address(this)
        (, euint256 forH, ) = space.getVoteTallyHandles(proposalId);
        assertTrue(inco.isAllowed(euint256.unwrap(forH), address(this)));
    }

    function testFinalizeRevealStoresExactCounts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI); // For, power 1
        _vote(voter, proposalId, 0, userVotingStrategies, voteMetadataURI); // Against, power 1
        _rollPastMax();

        // against=1, for=1, abstain=0, passed=false (1 > 1 is false)
        _revealExpectingResult(proposalId, 1, 1, 0, false);

        assertTrue(space.revealed(proposalId));
        (uint256 against, uint256 forV, uint256 abstain, bool passed) = space.result(proposalId);
        assertEq(against, 1);
        assertEq(forV, 1);
        assertEq(abstain, 0);
        assertFalse(passed);
    }

    function testFinalizeRevealIsOneTime() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        _finalizeRevealAgainExpectAlreadyRevealed(proposalId);
    }

    function testRequestRevealAfterFinalizeReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        vm.expectRevert(AlreadyRevealed.selector);
        space.requestReveal(proposalId);
    }

    function testFinalizeRevealHandleMismatchReverts() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        space.requestReveal(proposalId);
        // Swap For/Against attestations so the handle check fails.
        _finalizeRevealSwappedExpectMismatch(proposalId);
    }
}
