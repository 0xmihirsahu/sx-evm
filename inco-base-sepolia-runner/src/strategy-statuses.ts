import {
  castVoteTx,
  createProposalTx,
  deployFixture,
  executeProposal,
  getProposalStatus,
  proposalStatus,
  revealProposal,
  sponsor,
} from "./lib/snapshot-inco.js";

async function main(): Promise<void> {
  console.log("Base Sepolia Inco + Snapshot strategy-status runner");
  console.log("Sponsor:", sponsor.address);

  await acceptedCase();
  await rejectedCase();
  await abstainCase();

  console.log("Strategy-status run complete.");
}

async function acceptedCase(): Promise<void> {
  const fixture = await deployFixture("inco-snapshot-strategy-accepted");
  const proposalId = await createProposalTx(fixture, "ipfs://strategy-accepted");

  await castVoteTx(fixture, proposalId, sponsor.address, 1n);
  const result = await revealProposal(fixture, proposalId);
  console.log("Accepted case result:", result);
  if (!result.passed) {
    throw new Error("Accepted case expected the proposal to pass");
  }
  await executeProposal(fixture, proposalId);

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Accepted case status:", status);
  if (status !== proposalStatus.Executed) {
    throw new Error(`Accepted case expected Executed, got ${status}`);
  }
}

async function rejectedCase(): Promise<void> {
  const fixture = await deployFixture("inco-snapshot-strategy-rejected");
  const proposalId = await createProposalTx(fixture, "ipfs://strategy-rejected");

  await castVoteTx(fixture, proposalId, sponsor.address, 0n);
  const result = await revealProposal(fixture, proposalId);
  console.log("Rejected case result:", result);
  if (result.passed) {
    throw new Error("Rejected case unexpectedly passed");
  }

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Rejected case status:", status);
  if (status === proposalStatus.Executed) {
    throw new Error("Rejected case unexpectedly executed");
  }
}

async function abstainCase(): Promise<void> {
  const fixture = await deployFixture("inco-snapshot-strategy-abstain");
  const proposalId = await createProposalTx(fixture, "ipfs://strategy-abstain");

  await castVoteTx(fixture, proposalId, sponsor.address, 2n);
  const result = await revealProposal(fixture, proposalId);
  console.log("Abstain case result:", result);
  if (result.passed) {
    throw new Error("Abstain case unexpectedly passed");
  }

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Abstain case status:", status);
  if (status === proposalStatus.Executed) {
    throw new Error("Abstain case unexpectedly executed");
  }
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
