import {
  castMismatchedCiphertextVote,
  castVoteTx,
  createProposalTx,
  deployFixture,
  expectRevert,
  finalizeReveal,
  getProposalStatus,
  prepareTallies,
  proposalStatus,
  revealProposal,
  sponsor,
} from "./lib/snapshot-inco.js";

async function main(): Promise<void> {
  console.log("Base Sepolia Inco + Snapshot negative-case runner");
  console.log("Sponsor:", sponsor.address);

  const fixture = await deployFixture("inco-snapshot-negative-cases");

  await wrongCiphertextOwnerCase(fixture);
  await swappedAttestationCase(fixture);

  console.log("Negative-case run complete.");
}

async function wrongCiphertextOwnerCase(fixture: Awaited<ReturnType<typeof deployFixture>>): Promise<void> {
  const proposalId = await createProposalTx(fixture, "ipfs://inco-snapshot-wrong-ciphertext-owner");
  console.log("Wrong-owner proposal ID:", proposalId.toString());

  // The encrypted input is created for another account but consumed as sponsor.
  // Inco should not treat this as a valid sponsor-created private input.
  await castMismatchedCiphertextVote(
    fixture,
    proposalId,
    sponsor.address,
    "0x000000000000000000000000000000000000dEaD",
    1n,
  );

  const result = await revealProposal(fixture, proposalId);
  console.log("Wrong-owner revealed result:", result);

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Wrong-owner status enum:", status.toString());
  if (result.passed || status === proposalStatus.Executed) {
    throw new Error("Mismatched ciphertext owner unexpectedly produced a passing/executed proposal");
  }
}

async function swappedAttestationCase(fixture: Awaited<ReturnType<typeof deployFixture>>): Promise<void> {
  const proposalId = await createProposalTx(fixture, "ipfs://inco-snapshot-swapped-attestation");
  console.log("Swapped-attestation proposal ID:", proposalId.toString());

  await castVoteTx(fixture, proposalId, sponsor.address, 1n);

  // tallies are [against(0), for(1), abstain(2)]. Swapping against<->for makes each handle no longer
  // match the slot it's submitted for, so finalizeReveal must revert on the handle-mismatch check.
  const tallies = await prepareTallies(fixture, proposalId);
  const swapped = [tallies[1], tallies[0], tallies[2]];

  await expectRevert("Swapped tally attestation handles", async () => {
    await finalizeReveal(fixture, proposalId, swapped);
  });
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
