import {
  castVoteTx,
  createProposalTx,
  deployFixture,
  executeProposal,
  getProposalStatus,
  proposalStatus,
  revealProposal,
  sponsor,
  voteChoice,
} from "./lib/snapshot-inco.js";

export async function runHappyPath(): Promise<void> {
  console.log("Base Sepolia Inco + Snapshot happy-path smoke runner");
  console.log("Sponsor:", sponsor.address);

  const fixture = await deployFixture("inco-snapshot-happy-path");
  const proposalId = await createProposalTx(fixture);
  console.log("Proposal ID:", proposalId.toString());

  await castVoteTx(fixture, proposalId, sponsor.address, voteChoice);

  const result = await revealProposal(fixture, proposalId);
  console.log("Revealed result:", result);

  if (result.passed) {
    await executeProposal(fixture, proposalId);
  }

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Final proposal status enum:", status.toString());
  if (voteChoice === 1n && status !== proposalStatus.Executed) {
    throw new Error(`Expected executed proposal for for-vote, got status ${status}`);
  }
  console.log("Happy-path smoke run complete.");
}

runHappyPath().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
