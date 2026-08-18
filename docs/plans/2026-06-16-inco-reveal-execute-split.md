# Inco Reveal/Execute Split + Public Vote Counts — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Split the fused `tryExecute` into a gated, public, count-revealing reveal step and a separate execute step,
closing the two privacy bugs in the current Inco confidential-voting integration.

**Architecture:** The Space accumulates only encrypted per-choice tallies (`votePower[id][0..2]`) during voting,
granting decrypt access to _nobody_ (`allowThis()` only). After `maxEndBlockNumber`, anyone may call `requestReveal`
(grants the caller off-chain decrypt access to the now-frozen tallies), fetch attested decryptions off-chain, then
`finalizeReveal` (verifies attestations, stores cleartext against/for/abstain counts, computes quorum/support/passed
on-chain, locks the result). `execute` is a separate call gated on `revealed && passed`. The proposal author/voters can
no longer read a running result, and reveal can no longer happen before voting ends.

**Tech Stack:** Solidity 0.8.27 (compiled), Foundry (`forge test`), `@inco/lightning@0.7.12` (TEE attestation model),
OpenZeppelin upgradeable.

---

## Background: current state vs. target

**Current (`src/Space.sol`):**

- `vote()` ([Space.sol:287-379](../../src/Space.sol)) recomputes encrypted quorum/support flags every vote and calls
  `.allow(proposal.author)` / `.allow(msg.sender)` on them and on the running tallies — **the author can decrypt the
  running result off-chain mid-vote**.
- `tryExecute()` ([Space.sol:382-426](../../src/Space.sol)) verifies attested decryptions of those flags and executes —
  **with no check that voting has ended**, and reveal+execute are one atomic call.
- Only two booleans are ever revealed; exact counts stay encrypted forever.
- `propose()` ([Space.sol:267-279](../../src/Space.sol)) initializes the encrypted flag handles.
- Space is pre-funded via `receive()`/`fund()` ([Space.sol:94-98](../../src/Space.sol)) — this sponsors the per-vote
  `newEuint256` Inco fee (the real cost; reveal has no on-chain Inco fee). There is **no way to withdraw** the float.

**Target:**

- `vote()` accumulates only `votePower[id][0..2]` with `allowThis()` only. One Inco-fee op per vote (`newEuint256`). No
  flags, no EOA allows.
- `propose()` initializes the three tally buckets to encrypted-zero (trivial-encrypt, free) so handles always exist
  (revealable even with zero votes).
- New `requestReveal(id)` → gated `block.number >= maxEndBlockNumber`; grants `msg.sender` decrypt access to the three
  tallies; emits `RevealRequested`.
- New `finalizeReveal(id, 3×attestation)` → gated to `maxEnd`, one-time (`revealed` lock); verifies each tally
  attestation; stores cleartext counts; computes `quorumReached`/`supportAchieved`/`passed` on-chain; emits
  `ProposalResultRevealed`.
- New `execute(id, payload)` → requires `revealed && passed`; calls existing `_execute`.
- `tryExecute` and the encrypted flag state/getters are removed.
- New `withdraw(to, amount)` owner-only to reclaim the fee float.

## Key design decisions (do not second-guess during execution)

1. **Reveal mechanism = gated `allow(msg.sender)`, NOT `e.reveal()`.** `e.reveal()` exists in 0.7.12
   ([Lib.sol:439](../../node_modules/.pnpm/@inco+lightning@0.7.12/node_modules/@inco/lightning/src/Lib.sol)) but the
   test harness `MockOpHandler.handleIncoLog` has **no branch for the Reveal op**, so a `reveal()`'d handle is not
   attestable by an arbitrary requester in tests (`getDecryptionAttestation` requires `isAllowed(handle, requester)` —
   `FakeDecryptionAttester.sol:76-78`). Granting `allow(msg.sender)` after voting ends achieves the identical product
   outcome (final counts posted publicly on-chain) and the identical privacy property (no EOA allowed _during_ voting),
   and is guaranteed to work with the harness. The raw handle isn't world-decryptable, but the revealer posts cleartext
   on-chain, so the result is public regardless.
2. **Two transactions for reveal are inherent and intended.** The off-chain attested decryption must happen _between_
   `requestReveal` (on-chain allow) and `finalizeReveal` (on-chain submit). This naturally separates reveal from
   execute.
3. **Reveal is permissionless.** Anyone can `requestReveal`/`finalizeReveal` after `maxEnd`. The result is meant to be
   public; no lock-out risk because anyone can re-trigger until finalized.
4. **Pass/fail computed on-chain from cleartext** — no trust in an attested boolean.
   `quorumReached = (forVotes + abstainVotes) >= getQuorum()`, `supportAchieved = forVotes > againstVotes`. This
   reproduces the exact current semantics
   ([SimpleQuorumExecutionStrategy.sol:50](../../src/execution-strategies/SimpleQuorumExecutionStrategy.sol)).
5. **Keep voting sponsored (pre-funded Space); add owner `withdraw`.** Do not make `vote()` payable — the
   authenticator/relayer indirection makes per-voter fee plumbing hostile, and sponsored voting is better UX. The fee
   concern from Snapshot is addressed by `withdraw` (reclaim float) + the fact that reveal already costs the Space
   nothing.
6. **Choice indices stay `0=Against, 1=For, 2=Abstain`** (matches `src/types.sol:75-77` and current `votePower` layout).

---

## Task 0: Branch

**Step 1:** Create a working branch (we are on `main` with untracked `lib/` and `src/CLAUDE.md`).

```bash
git checkout -b feat/inco-reveal-execute-split
```

---

## Task 1: Types, interfaces, errors, events (scaffolding)

**Files:**

- Modify: `src/types.sol` (add `ProposalResult` struct)
- Modify: `src/interfaces/space/ISpaceErrors.sol`
- Modify: `src/interfaces/space/ISpaceEvents.sol`
- Modify: `src/interfaces/space/ISpaceActions.sol`
- Modify: `src/interfaces/space/ISpaceState.sol`

**Step 1: Add `ProposalResult` to `src/types.sol`** (after the `Strategy` struct, before `IndexedStrategy`):

```solidity
/// @notice The revealed, cleartext result of a proposal after voting ends.
struct ProposalResult {
    uint256 againstVotes;
    uint256 forVotes;
    uint256 abstainVotes;
    bool passed;
}
```

**Step 2: Add errors to `src/interfaces/space/ISpaceErrors.sol`** (append inside the interface):

```solidity
    /// @notice Thrown when reveal/finalize is attempted before the voting period has ended.
    error VotingPeriodNotEnded();

    /// @notice Thrown when a proposal result has already been revealed.
    error AlreadyRevealed();

    /// @notice Thrown when execute is attempted before the result has been revealed.
    error NotRevealed();

    /// @notice Thrown when execute is attempted on a proposal that did not pass.
    error ProposalNotPassed();

    /// @notice Thrown when an owner withdrawal of the fee float fails.
    error WithdrawFailed();
```

**Step 3: Add events to `src/interfaces/space/ISpaceEvents.sol`** (append inside the interface):

```solidity
    /// @notice Emitted when an account requests decryption access to a proposal's final tallies.
    /// @param proposalId The proposal id.
    /// @param revealer The account granted decrypt access to the tallies.
    event RevealRequested(uint256 proposalId, address revealer);

    /// @notice Emitted when a proposal's cleartext result is finalized on-chain.
    /// @param proposalId The proposal id.
    /// @param againstVotes The total Against voting power.
    /// @param forVotes The total For voting power.
    /// @param abstainVotes The total Abstain voting power.
    /// @param passed Whether the proposal reached quorum and achieved support.
    event ProposalResultRevealed(
        uint256 proposalId,
        uint256 againstVotes,
        uint256 forVotes,
        uint256 abstainVotes,
        bool passed
    );
```

**Step 4: Update `src/interfaces/space/ISpaceActions.sol`** — replace the `tryExecute` declaration (lines 57-71) with:

```solidity
    /// @notice  Grants the caller off-chain decryption access to a proposal's final vote tallies.
    /// @dev     Only callable after the voting period has ended. The tallies are frozen at this point.
    /// @param   proposalId  The proposal id.
    function requestReveal(uint256 proposalId) external;

    /// @notice  Finalizes a proposal's result from attested decryptions of its vote tallies.
    /// @dev     Verifies each attestation, stores cleartext counts, computes pass/fail, and locks the result.
    /// @param   proposalId  The proposal id.
    /// @param   againstAttestation  Attested decryption of the Against tally.
    /// @param   againstSignatures  Covalidator signatures for the Against attestation.
    /// @param   forAttestation  Attested decryption of the For tally.
    /// @param   forSignatures  Covalidator signatures for the For attestation.
    /// @param   abstainAttestation  Attested decryption of the Abstain tally.
    /// @param   abstainSignatures  Covalidator signatures for the Abstain attestation.
    function finalizeReveal(
        uint256 proposalId,
        DecryptionAttestation memory againstAttestation,
        bytes[] memory againstSignatures,
        DecryptionAttestation memory forAttestation,
        bytes[] memory forSignatures,
        DecryptionAttestation memory abstainAttestation,
        bytes[] memory abstainSignatures
    ) external;

    /// @notice  Executes a proposal whose result has been revealed and passed.
    /// @param   proposalId  The proposal id.
    /// @param   executionPayload  The execution payload (must match the hash stored at proposal creation).
    function execute(uint256 proposalId, bytes calldata executionPayload) external;
```

**Step 5: Update `src/interfaces/space/ISpaceState.sol`:**

- Add import of `ProposalResult`: change line 5 to
  ```solidity
  import { Proposal, ProposalStatus, FinalizationStatus, Strategy, ProposalResult } from "src/types.sol";
  ```
- Replace the encrypted-handle getters (lines 45-51, `encryptedIsQuorumReached` / `encryptedIsSupportAchieved`) and the
  `getQuorumAndSupportHandles` getter (lines 61-66) with:

  ```solidity
      /// @notice Whether a proposal's result has been revealed and locked.
      /// @param proposalId The ID of the proposal.
      function revealed(uint256 proposalId) external view returns (bool);

      /// @notice The revealed cleartext result of a proposal (zeros until finalized).
      /// @param proposalId The ID of the proposal.
      function result(uint256 proposalId)
          external
          view
          returns (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes, bool passed);

      /// @notice Returns the encrypted vote tally handles for off-chain decryption after voting ends.
      /// @param proposalId The ID of the proposal.
      function getVoteTallyHandles(uint256 proposalId)
          external
          view
          returns (euint256 againstHandle, euint256 forHandle, euint256 abstainHandle);
  ```

  Keep `isQuorumReached` / `isSupportAchieved` (lines 53-59) — update their NatSpec to say "set after finalizeReveal()".

**Step 6: Compile.**

Run: `forge build` Expected: **FAIL** — `src/Space.sol` still defines `tryExecute`, the removed state vars, and
`getQuorumAndSupportHandles`, which no longer match the interfaces. This is expected; Task 2 fixes Space.sol. (If you
prefer a green checkpoint, do Task 1 + Task 2 before the first `forge build`.)

---

## Task 2: Space.sol core refactor

**File:** Modify `src/Space.sol`

**Step 1: State (lines 84-92).** Replace the encrypted flag/decrypted state block with:

```solidity
    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override revealed;

    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => ProposalResult) public override result;

    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override isQuorumReached;
    /// @inheritdoc ISpaceState
    mapping(uint256 proposalId => bool) public override isSupportAchieved;
```

Keep `votePower` (line 82). Update the import on line 11 to include `ProposalResult`:

```solidity
import {
    FinalizationStatus, IndexedStrategy, Proposal, ProposalStatus, ProposalResult,
    Strategy, UpdateSettingsCalldata, InitializeCalldata, TRUE, FALSE
} from "src/types.sol";
```

**Step 2: `fund()`/`receive()` + add `withdraw` (lines 94-98).** Keep `receive`/`fund`; add after them:

```solidity
    /// @dev Allows the owner to reclaim the space's Inco fee float.
    function withdraw(address payable to, uint256 amount) external onlyOwner {
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert WithdrawFailed();
    }
```

**Step 3: `propose()` (lines 267-279).** Replace the encrypted flag initialization with tally-bucket initialization:

```solidity
        // Initialize the three encrypted vote tallies to encrypted-zero so the handles always
        // exist and are revealable even if the proposal receives zero votes.
        // Trivial-encrypt (asEuint256) does not incur an Inco fee.
        for (uint8 choice = 0; choice < 3; choice++) {
            euint256 zero = e.asEuint256(0);
            zero.allowThis();
            votePower[nextProposalId][choice] = zero;
        }
```

**Step 4: `vote()` confidential section (lines 311-372).** Replace the entire confidential section with tally-only
accumulation (no flags, no EOA allows):

```solidity
        // --- CONFIDENTIAL SECTION: accumulate encrypted tallies only ---

        // The only Inco-fee-charging op per vote: ingest the encrypted choice.
        bytes memory ciphertextMem = ciphertext;
        euint256 userChoice = ciphertextMem.newEuint256(voter);

        ebool isAgainst = userChoice.eq(uint256(0));
        ebool isFor = userChoice.eq(uint256(1));
        ebool isAbstain = userChoice.eq(uint256(2));

        euint256 encryptedPower = e.asEuint256(votingPower);

        // Against (0)
        euint256 newAgainst = isAgainst.select(votePower[proposalId][0].add(encryptedPower), votePower[proposalId][0]);
        newAgainst.allowThis();
        votePower[proposalId][0] = newAgainst;

        // For (1)
        euint256 newFor = isFor.select(votePower[proposalId][1].add(encryptedPower), votePower[proposalId][1]);
        newFor.allowThis();
        votePower[proposalId][1] = newFor;

        // Abstain (2)
        euint256 newAbstain = isAbstain.select(votePower[proposalId][2].add(encryptedPower), votePower[proposalId][2]);
        newAbstain.allowThis();
        votePower[proposalId][2] = newAbstain;

        // --- END CONFIDENTIAL SECTION ---
```

> Note: tallies are read directly (buckets are initialized in `propose`). The `_getOrZero` helper (lines 556-564)
> becomes unused — remove it in Step 8.

**Step 5: Replace `tryExecute()` (lines 382-426)** with `requestReveal`, `finalizeReveal`, `execute`, and the
`_verifyTally` helper:

```solidity
    /// @inheritdoc ISpaceActions
    function requestReveal(uint256 proposalId) external override {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (block.number < proposal.maxEndBlockNumber) revert VotingPeriodNotEnded();
        if (revealed[proposalId]) revert AlreadyRevealed();

        // Grant the caller off-chain decryption access to the final (frozen) tallies.
        // Safe: voting has ended, so this cannot leak a running result.
        votePower[proposalId][0].allow(msg.sender);
        votePower[proposalId][1].allow(msg.sender);
        votePower[proposalId][2].allow(msg.sender);

        emit RevealRequested(proposalId, msg.sender);
    }

    /// @inheritdoc ISpaceActions
    function finalizeReveal(
        uint256 proposalId,
        DecryptionAttestation memory againstAttestation,
        bytes[] memory againstSignatures,
        DecryptionAttestation memory forAttestation,
        bytes[] memory forSignatures,
        DecryptionAttestation memory abstainAttestation,
        bytes[] memory abstainSignatures
    ) external override {
        Proposal storage proposal = proposals[proposalId];
        _assertProposalExists(proposal);
        if (block.number < proposal.maxEndBlockNumber) revert VotingPeriodNotEnded();
        if (revealed[proposalId]) revert AlreadyRevealed();

        uint256 againstVotes = _verifyTally(proposalId, 0, againstAttestation, againstSignatures);
        uint256 forVotes = _verifyTally(proposalId, 1, forAttestation, forSignatures);
        uint256 abstainVotes = _verifyTally(proposalId, 2, abstainAttestation, abstainSignatures);

        uint256 quorumValue = proposal.executionStrategy.getQuorum();
        bool quorumReached = (forVotes + abstainVotes) >= quorumValue;
        bool supportAchieved = forVotes > againstVotes;
        bool passed = quorumReached && supportAchieved;

        isQuorumReached[proposalId] = quorumReached;
        isSupportAchieved[proposalId] = supportAchieved;
        result[proposalId] = ProposalResult(againstVotes, forVotes, abstainVotes, passed);
        revealed[proposalId] = true;

        emit ProposalResultRevealed(proposalId, againstVotes, forVotes, abstainVotes, passed);
    }

    /// @inheritdoc ISpaceActions
    function execute(uint256 proposalId, bytes calldata executionPayload) external override {
        if (!revealed[proposalId]) revert NotRevealed();
        if (!result[proposalId].passed) revert ProposalNotPassed();
        _execute(proposalId, executionPayload);
    }

    /// @dev Verifies an attested decryption of a vote tally handle and returns the cleartext count.
    function _verifyTally(
        uint256 proposalId,
        uint8 choice,
        DecryptionAttestation memory attestation,
        bytes[] memory signatures
    ) internal returns (uint256) {
        require(
            inco.incoVerifier().isValidDecryptionAttestation(attestation, signatures),
            "Invalid tally attestation"
        );
        require(
            euint256.unwrap(votePower[proposalId][choice]) == attestation.handle,
            "Tally handle mismatch"
        );
        return uint256(attestation.value);
    }
```

> If `forge build` reports `_verifyTally` can be `view`, leave it non-view anyway (matches the existing non-view
> `tryExecute` pattern; harmless).

**Step 6: `getProposalStatus` (lines 206-215).** No change — it already reads `isQuorumReached`/`isSupportAchieved`,
which are now set by `finalizeReveal`.

**Step 7: Replace `getQuorumAndSupportHandles` (lines 217-225)** with:

```solidity
    /// @inheritdoc ISpaceState
    function getVoteTallyHandles(uint256 proposalId)
        external
        view
        override
        returns (euint256 againstHandle, euint256 forHandle, euint256 abstainHandle)
    {
        return (votePower[proposalId][0], votePower[proposalId][1], votePower[proposalId][2]);
    }
```

**Step 8: Remove the now-unused `_getOrZero` helper** (lines 556-564).

**Step 9: Compile.**

Run: `forge build` Expected: PASS (Space.sol now matches the interfaces). Test files won't compile yet — that's Task 3+.

**Step 10: Commit.**

```bash
git add src/Space.sol src/types.sol src/interfaces/space/
git commit -m "feat: split reveal/execute, reveal public vote counts, gate to voting end

- vote() accumulates encrypted tallies only (allowThis), removing the
  author/voter decrypt grants that leaked the running result
- propose() initializes tally buckets to encrypted-zero (free trivial encrypt)
- requestReveal/finalizeReveal/execute replace the fused tryExecute; reveal is
  gated to maxEndBlockNumber and one-time; counts are revealed and pass/fail is
  computed on-chain
- add owner withdraw() for the fee float; remove encrypted flag state/getters

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Update the shared test harness (`test/utils/Space.t.sol`)

**File:** Modify `test/utils/Space.t.sol`

**Step 1:** Add the `HandleWithProof` import is already available via `IncoTest` inheritance (`FakeDecryptionAttester`
defines it). Ensure `euint256` and `DecryptionAttestation` imports exist (they do, lines 22-23).

**Step 2:** Replace `_prepareTryExecuteAttestations` / `_tryExecute` / `_tryExecuteExpectRevert` /
`_tryExecuteExpectAnyRevert` / `_tryExecuteInvalidProposalExpectRevert` (lines 193-256) with the new reveal/execute
helpers:

```solidity
    /// @dev Requests reveal and submits attested decryptions of all three tallies.
    ///      Assumes the caller has already rolled past maxEndBlockNumber.
    function _reveal(uint256 _proposalId) internal {
        _processAllOperations(); // ensure tallies are computed in the mock KV
        space.requestReveal(_proposalId);

        (
            DecryptionAttestation memory aAtt,
            bytes[] memory aSigs,
            DecryptionAttestation memory fAtt,
            bytes[] memory fSigs,
            DecryptionAttestation memory abAtt,
            bytes[] memory abSigs
        ) = _prepareTallyAttestations(_proposalId);

        space.finalizeReveal(_proposalId, aAtt, aSigs, fAtt, fSigs, abAtt, abSigs);
    }

    /// @dev Builds attested decryptions for a proposal's three tally handles (requester = address(this)).
    function _prepareTallyAttestations(uint256 _proposalId)
        internal
        returns (
            DecryptionAttestation memory aAtt,
            bytes[] memory aSigs,
            DecryptionAttestation memory fAtt,
            bytes[] memory fSigs,
            DecryptionAttestation memory abAtt,
            bytes[] memory abSigs
        )
    {
        (euint256 againstH, euint256 forH, euint256 abstainH) = space.getVoteTallyHandles(_proposalId);
        (aAtt, aSigs) = getDecryptionAttestation(
            address(this), HandleWithProof({ handle: euint256.unwrap(againstH), proof: emptyProof })
        );
        (fAtt, fSigs) = getDecryptionAttestation(
            address(this), HandleWithProof({ handle: euint256.unwrap(forH), proof: emptyProof })
        );
        (abAtt, abSigs) = getDecryptionAttestation(
            address(this), HandleWithProof({ handle: euint256.unwrap(abstainH), proof: emptyProof })
        );
    }

    /// @dev Convenience: reveal then execute (most existing tests want the full finalize+execute path).
    function _revealAndExecute(uint256 _proposalId, bytes memory _payload) internal {
        _reveal(_proposalId);
        space.execute(_proposalId, _payload);
    }
```

> `getDecryptionAttestation` and `HandleWithProof` come from `FakeDecryptionAttester` (inherited via `IncoTest`). After
> `requestReveal` grants `allow(address(this))`, `getDecryptionAttestation(address(this), …)` passes
> `checkAccessControl`.

**Step 3:** Leave the gas-snapshot helpers and everything else intact. Do **not** delete `emptyProof` (still used).

---

## Task 4: Rewrite `test/Execute.t.sol` to the new flow

**File:** Modify `test/Execute.t.sol`

The execution semantics are preserved; only the call shape changes. Reveal is now gated to `maxEnd` and there is no
early-execution path. Replace the file body with:

```solidity
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
        _revealAndExecute(proposalId, executionStrategy.params);
        vm.expectRevert(ProposalFinalized.selector);
        space.execute(proposalId, executionStrategy.params);
    }

    function testExecuteWithAgainstVoteRejected() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 0, userVotingStrategies, voteMetadataURI);
        _rollPastMax();
        _reveal(proposalId);
        (, , , bool passed) = space.result(proposalId);
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
```

**Step (run):** `forge test --match-path test/Execute.t.sol -vv` → PASS once Task 2+3 are in.

---

## Task 5: New reveal-specific tests (`test/Reveal.t.sol`)

**File:** Create `test/Reveal.t.sol`

These lock in the privacy gate, the one-time lock, exact counts, and the no-leak-during-voting property.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import { SpaceTest } from "./utils/Space.t.sol";
import { DecryptionAttestation } from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
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
        // Build (bogus) empty attestations; the gate must fire before any verification.
        DecryptionAttestation memory empty = DecryptionAttestation({ handle: bytes32(0), value: bytes32(0) });
        bytes[] memory noSigs = new bytes[](0);
        vm.expectRevert(VotingPeriodNotEnded.selector);
        space.finalizeReveal(proposalId, empty, noSigs, empty, noSigs, empty, noSigs);
    }

    function testRunningTallyNotDecryptableByAuthorDuringVoting() public {
        uint256 proposalId = _createProposal(author, proposalMetadataURI, executionStrategy, new bytes(0));
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);
        (euint256 against, euint256 forH, euint256 abstain) = space.getVoteTallyHandles(proposalId);
        // No EOA (author, voter, relayer) may decrypt the running tallies — only the contract.
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
        _vote(author, proposalId, 1, userVotingStrategies, voteMetadataURI);  // For, power 1
        _vote(voter, proposalId, 0, userVotingStrategies, voteMetadataURI);   // Against, power 1
        _rollPastMax();

        vm.expectEmit(true, true, true, true);
        emit ProposalResultRevealed(proposalId, 1, 1, 0, false); // against=1, for=1, abstain=0, passed=false (1>1 is false)
        _reveal(proposalId);

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

        (
            DecryptionAttestation memory aAtt, bytes[] memory aSigs,
            DecryptionAttestation memory fAtt, bytes[] memory fSigs,
            DecryptionAttestation memory abAtt, bytes[] memory abSigs
        ) = _prepareTallyAttestations(proposalId);
        vm.expectRevert(AlreadyRevealed.selector);
        space.finalizeReveal(proposalId, aAtt, aSigs, fAtt, fSigs, abAtt, abSigs);
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
        (
            DecryptionAttestation memory aAtt, bytes[] memory aSigs,
            DecryptionAttestation memory fAtt, bytes[] memory fSigs,
            DecryptionAttestation memory abAtt, bytes[] memory abSigs
        ) = _prepareTallyAttestations(proposalId);
        // Swap For/Against attestations so the handle check fails.
        vm.expectRevert("Tally handle mismatch");
        space.finalizeReveal(proposalId, fAtt, fSigs, aAtt, aSigs, abAtt, abSigs);
    }
}
```

**Step (run):** `forge test --match-path test/Reveal.t.sol -vv` → iterate until PASS. If
`testRunningTallyNotDecryptableByAuthorDuringVoting` fails, an EOA `.allow` was left in `vote()` — remove it.

**Step (commit):**

```bash
git add test/utils/Space.t.sol test/Execute.t.sol test/Reveal.t.sol
git commit -m "test: reveal/execute split — privacy gate, one-time lock, exact counts

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Owner `withdraw` test

**File:** Add to `test/SpaceOwnerActions.t.sol` (or a new `test/Withdraw.t.sol` if cleaner).

```solidity
    function testOwnerCanWithdrawFeeFloat() public {
        // space funded with 10 ether in setUp
        address payable sink = payable(address(0xBEEF));
        uint256 before = sink.balance;
        space.withdraw(sink, 1 ether);
        assertEq(sink.balance, before + 1 ether);
    }

    function testNonOwnerCannotWithdraw() public {
        vm.prank(unauthorized);
        _expectOnlyOwnerRevert(unauthorized);
        space.withdraw(payable(unauthorized), 1 ether);
    }
```

> If added to `SpaceOwnerActions.t.sol`, confirm `unauthorized` and `_expectOnlyOwnerRevert` are in scope (they are, via
> `SpaceTest`).

**Step (run):** `forge test --match-path test/SpaceOwnerActions.t.sol -vv` → PASS.

---

## Task 7: Fix remaining test/script files referencing the old API

**Step 1:** Find every remaining reference:

```bash
grep -rln "tryExecute\|encryptedIsQuorumReached\|encryptedIsSupportAchieved\|getQuorumAndSupportHandles" src test script
```

Expected remaining after Tasks 2-6: `test/Vote.t.sol`, `test/SimpleQuorum.t.sol`, `test/OptimisticQuorum.t.sol`,
`test/EmergencyQuorumExecutionStrategy.t.sol`, the timelock/avatar execution-strategy tests,
`test/UpdateProposal.t.sol`, `test/EthTxAuthenticator.t.sol`, `script/Example.s.sol`.

**Step 2:** For each, replace `_tryExecute(id, payload)` → `_revealAndExecute(id, payload)` (after ensuring the test
rolls past `maxVotingDuration`), and `_tryExecuteExpectRevert(...)` → the appropriate new path (`_reveal` +
`vm.expectRevert` + `space.execute`, or a direct `requestReveal`/`finalizeReveal` revert). Most are mechanical. Work
file-by-file, running that file's tests after each edit:

```bash
forge test --match-path test/<File>.t.sol -vv
```

**Step 3:** `script/Example.s.sol` — update or delete the `tryExecute` usage to the new
`requestReveal`/`finalizeReveal`/`execute` calls (scripts aren't covered by tests; just make it compile: `forge build`).

**Step (commit):**

```bash
git add test script
git commit -m "test: migrate remaining suites to reveal/execute split

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Full verification

**Step 1:** Full test suite.

```bash
forge test -vv
```

Expected: all green. Investigate any failure before proceeding — do not skip.

**Step 2:** Lint.

```bash
yarn lint:sol
```

Fix any solhint violations in the touched files.

**Step 3:** Gas snapshot (the repo tracks `.forge-snapshots/`). Regenerate and review the vote/execute deltas (vote
should be cheaper — one Inco op instead of several).

```bash
forge test -vv   # GasSnapshot writes updated snapshots; review the diff
git diff --stat .forge-snapshots/ .gas-snapshot 2>/dev/null
```

**Step 4:** Final commit.

```bash
git add -A
git commit -m "chore: update gas snapshots for reveal/execute split

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Out of scope (note for later)

- **Frontend/SDK (`@inco/lightning-js`) wiring** for the two-step reveal (call `requestReveal`, `attestedDecrypt` the
  three handles, submit `finalizeReveal`). Contract-only here.
- **Small-anonymity-set leak:** revealing exact counts with 1-2 voters can expose individual choices. Inherent to
  "public after voting"; flag to Snapshot, no code change.
- **Per-voter fee (pay-per-call) instead of sponsored voting** — explicitly deferred per design decision 5.
