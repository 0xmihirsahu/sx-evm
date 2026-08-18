// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";
import { IndexedStrategy, ProposalStatus, Strategy } from "../src/types.sol";
import { VanillaExecutionStrategy } from "../src/execution-strategies/VanillaExecutionStrategy.sol";

contract SimpleQuorumTest is SpaceTest {
    event QuorumUpdated(uint256 newQuorum);

    function test_SimpleQuorumSetQuorum() public {
        uint256 newQuorum = quorum * 2; // 2
        vm.expectEmit(true, true, true, true);
        emit QuorumUpdated(newQuorum);
        vanillaExecutionStrategy.setQuorum(newQuorum);

        // A single vote no longer meets the new quorum of 2: rejected after voting ends.
        uint256 p1 = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, p1, 1, userVotingStrategies, voteMetadataURI);
        _reveal(p1);
        assertEq(uint8(space.getProposalStatus(p1)), uint8(ProposalStatus.Rejected));
        vm.expectRevert(ProposalNotPassed.selector);
        space.execute(p1, executionStrategy.params);

        // Two votes meet the new quorum: the proposal executes.
        // Use voters distinct from p1's to keep each mock ciphertext handle unique.
        uint256 p2 = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(address(11), p2, 1, userVotingStrategies, voteMetadataURI);
        _vote(address(12), p2, 1, userVotingStrategies, voteMetadataURI);
        _reveal(p2);
        vm.expectEmit(true, true, true, true);
        emit ProposalExecuted(p2);
        space.execute(p2, executionStrategy.params);
        assertEq(uint8(space.getProposalStatus(p2)), uint8(ProposalStatus.Executed));
    }

    function test_SimpleQuorumSetQuorumUnauthorized() public {
        uint256 newQuorum = quorum * 2;
        vm.prank(address(0xdeadbeef));
        _expectOnlyOwnerRevert(address(0xdeadbeef));
        vanillaExecutionStrategy.setQuorum(newQuorum);
    }
}
