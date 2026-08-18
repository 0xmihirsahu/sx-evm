import { privateKeyToAccount } from "viem/accounts";
import type { Hex } from "viem";
import {
  castVoteSig,
  createProposalTx,
  deployFixture,
  getProposalStatus,
  proposalStatus,
  revealProposal,
  sponsor,
} from "./lib/snapshot-inco.js";

function voterKeys(): Hex[] {
  const raw = process.env.VOTER_PRIVATE_KEYS;
  if (!raw) {
    throw new Error(
      "Missing VOTER_PRIVATE_KEYS. Provide comma-separated private keys for at least two voters. They do not need ETH when using EthSigAuthenticator.",
    );
  }
  const keys = raw
    .split(",")
    .map((key) => key.trim())
    .filter(Boolean) as Hex[];
  if (keys.length < 2) {
    throw new Error("VOTER_PRIVATE_KEYS must contain at least two private keys");
  }
  return keys;
}

async function main(): Promise<void> {
  console.log("Base Sepolia Inco + Snapshot multi-voter signature runner");
  console.log("Sponsor:", sponsor.address);

  const keys = voterKeys();
  keys.slice(0, 2).forEach((key, index) => {
    console.log(`Voter ${index + 1}:`, privateKeyToAccount(key).address);
  });

  const fixture = await deployFixture("inco-snapshot-multi-voter");
  const proposalId = await createProposalTx(fixture, "ipfs://inco-snapshot-multi-voter");
  console.log("Proposal ID:", proposalId.toString());

  await castVoteSig(fixture, proposalId, keys[0], 1n);
  await castVoteSig(fixture, proposalId, keys[1], 0n);

  const result = await revealProposal(fixture, proposalId);
  console.log("Revealed result:", result);
  if (result.passed) {
    throw new Error("Expected mixed 1-for/1-against vote not to pass under strict support");
  }

  const status = await getProposalStatus(fixture, proposalId);
  console.log("Final proposal status enum:", status.toString());
  if (status === proposalStatus.Executed) {
    throw new Error("Expected mixed 1-for/1-against vote not to execute under strict support");
  }
  console.log("Multi-voter signature run complete.");
}

main().catch((error: unknown) => {
  console.error(error);
  process.exitCode = 1;
});
