import "dotenv/config";

import type { HexString } from "@inco/js";
import {
  bytesToHex,
  createPublicClient,
  createWalletClient,
  encodeAbiParameters,
  encodePacked,
  hexToSignature,
  http,
  keccak256,
  pad,
  parseAbiParameters,
  stringToBytes,
  toHex,
  type Abi,
  type Address,
  type Hash,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const require = createRequire(import.meta.url);
const { Lightning } = require("@inco/js/lite") as typeof import("@inco/js/lite");
const { handleTypes, supportedChains } = require("@inco/js") as typeof import("@inco/js");

export type IncoClient = any;

export type Deployment = {
  address: Address;
  abi: Abi;
};

export type DecryptionResult = {
  handle: HexString;
  value: bigint | boolean;
  attestation: {
    handle: HexString;
    value: Hex;
  };
  signatures: Hex[];
};

type Artifact = {
  abi: Abi;
  bytecode?: Hex | { object?: Hex };
};

export type Fixture = {
  validation: Deployment;
  voting: Deployment;
  txAuthenticator: Deployment;
  sigAuthenticator: Deployment;
  execution: Deployment;
  space: Deployment;
  fee: bigint;
  zap: IncoClient;
};

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "../../..");

export const rpcUrl = requireEnv("BASE_SEPOLIA_RPC_URL");
export const privateKey = (process.env.PRIVATE_KEY_BASE_SEPOLIA ?? process.env.PRIVATE_KEY) as Hex | undefined;
export const voteChoice = BigInt(process.env.VOTE_CHOICE ?? "1");
// Number of blocks the voting window stays open. Votes must land before it ends; reveal is only
// allowed once block.number >= maxEndBlockNumber, so keep it small to limit the post-vote wait.
export const votingDurationBlocks = Number(process.env.MAX_VOTING_DURATION ?? "30");
export const decryptRetries = Number(process.env.INCO_DECRYPT_RETRIES ?? "12");
export const decryptRetryMs = Number(process.env.INCO_DECRYPT_RETRY_MS ?? "5000");

if (!privateKey) {
  throw new Error("Missing PRIVATE_KEY_BASE_SEPOLIA or PRIVATE_KEY. See inco-base-sepolia-runner/.env.example");
}

if (![0n, 1n, 2n].includes(voteChoice)) {
  throw new Error("VOTE_CHOICE must be 0, 1, or 2");
}

export const sponsor = privateKeyToAccount(privateKey);
export const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(rpcUrl),
});
export const walletClient = createWalletClient({
  account: sponsor,
  chain: baseSepolia,
  transport: http(rpcUrl),
});

export const getFeeAbi = [
  {
    inputs: [],
    name: "getFee",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

export const proposalStatus = {
  VotingDelay: 0,
  VotingPeriod: 1,
  VotingPeriodAccepted: 2,
  Accepted: 3,
  Executed: 4,
  Rejected: 5,
  Cancelled: 6,
} as const;

export const proposeSelector = selector("propose(address,string,(address,bytes),bytes)");
export const voteSelector = selector("vote(address,uint256,bytes,(uint8,bytes)[],string)");

export async function initInco(): Promise<{ zap: IncoClient; fee: bigint }> {
  const zap = await Lightning.latest("testnet", supportedChains.baseSepolia);
  const fee = await publicClient.readContract({
    address: zap.executorAddress as Address,
    abi: getFeeAbi,
    functionName: "getFee",
  });
  return { zap, fee };
}

export async function deployFixture(label = "inco-snapshot-poc"): Promise<Fixture> {
  const { zap, fee } = await initInco();

  console.log("Inco executor:", zap.executorAddress);
  console.log("Inco fee:", fee.toString());

  const validation = await deploy(
    "VanillaProposalValidationStrategy",
    "out/VanillaProposalValidationStrategy.sol/VanillaProposalValidationStrategy.json",
  );
  const voting = await deploy("VanillaVotingStrategy", "out/VanillaVotingStrategy.sol/VanillaVotingStrategy.json");
  const txAuthenticator = await deploy("EthTxAuthenticator", "out/EthTxAuthenticator.sol/EthTxAuthenticator.json");
  const sigAuthenticator = await deploy("EthSigAuthenticator", "out/EthSigAuthenticator.sol/EthSigAuthenticator.json", [
    "snapshot-x",
    "1",
  ]);
  const execution = await deploy(
    "VanillaExecutionStrategy",
    "out/VanillaExecutionStrategy.sol/VanillaExecutionStrategy.json",
    [sponsor.address, 1n],
  );
  const space = await deploy("Space", "out/Space.sol/Space.json");

  await writeAndWait("Initialize Space", {
    address: space.address,
    abi: space.abi,
    functionName: "initialize",
    args: [
      {
        owner: sponsor.address,
        votingDelay: 0,
        minVotingDuration: 0,
        maxVotingDuration: votingDurationBlocks,
        proposalValidationStrategy: { addr: validation.address, params: "0x" },
        proposalValidationStrategyMetadataURI: "",
        daoURI: label,
        metadataURI: label,
        votingStrategies: [{ addr: voting.address, params: "0x" }],
        votingStrategyMetadataURIs: [""],
        authenticators: [txAuthenticator.address, sigAuthenticator.address],
      },
    ],
  });

  // Voter-pays model: the Space is no longer pre-funded. Each vote forwards the Inco fee as msg.value.

  return { validation, voting, txAuthenticator, sigAuthenticator, execution, space, fee, zap };
}

export async function deployTimelockFixture(label = "inco-snapshot-timelock-poc"): Promise<Fixture> {
  const fixture = await deployFixture(label);
  const timelockExecution = await deploy(
    "TimelockExecutionStrategy",
    "out/TimelockExecutionStrategy.sol/TimelockExecutionStrategy.json",
  );
  return { ...fixture, execution: timelockExecution };
}

export async function createProposalTx(fixture: Fixture, metadata = "ipfs://inco-snapshot-poc"): Promise<bigint> {
  const proposalId = (await publicClient.readContract({
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "nextProposalId",
  })) as bigint;

  const proposeArgs = encodeProposeArgs(sponsor.address, metadata, fixture.execution.address);
  await writeAndWait("Create proposal through EthTxAuthenticator", {
    address: fixture.txAuthenticator.address,
    abi: fixture.txAuthenticator.abi,
    functionName: "authenticate",
    args: [fixture.space.address, proposeSelector, proposeArgs],
  });

  return proposalId;
}

export async function castVoteTx(fixture: Fixture, proposalId: bigint, voter: Address, choice: bigint): Promise<void> {
  const ciphertext = await encryptVote(fixture.zap, fixture.space.address, voter, choice);
  const voteArgs = encodeVoteArgs(voter, proposalId, ciphertext);

  await writeAndWait(`Cast encrypted tx vote choice=${choice.toString()}`, {
    address: fixture.txAuthenticator.address,
    abi: fixture.txAuthenticator.abi,
    functionName: "authenticate",
    args: [fixture.space.address, voteSelector, voteArgs],
    // Voter-pays: forward the per-vote Inco fee that Space.vote() consumes via newEuint256.
    value: fixture.fee,
  });
}

export async function castVoteSig(
  fixture: Fixture,
  proposalId: bigint,
  voterPrivateKey: Hex,
  choice: bigint,
  metadata = "",
): Promise<void> {
  const voter = privateKeyToAccount(voterPrivateKey);
  const ciphertext = await encryptVote(fixture.zap, fixture.space.address, voter.address, choice);
  const userVotingStrategies = [{ index: 0, params: "0x" as Hex }];
  const voteArgs = encodeVoteArgs(voter.address, proposalId, ciphertext, userVotingStrategies, metadata);
  const digest = voteDigest({
    authenticator: fixture.sigAuthenticator.address,
    space: fixture.space.address,
    voter: voter.address,
    proposalId,
    ciphertext,
    userVotingStrategies,
    metadata,
  });
  const signature = hexToSignature(await voter.sign({ hash: digest }));

  await writeAndWait(`Cast encrypted sig vote ${voter.address} choice=${choice.toString()}`, {
    address: fixture.sigAuthenticator.address,
    abi: fixture.sigAuthenticator.abi,
    functionName: "authenticate",
    args: [Number(signature.v), signature.r, signature.s, 0n, fixture.space.address, voteSelector, voteArgs],
    // Voter-pays: the relayer forwards the per-vote Inco fee for the signed vote.
    value: fixture.fee,
  });
}

export async function castMismatchedCiphertextVote(
  fixture: Fixture,
  proposalId: bigint,
  voter: Address,
  ciphertextOwner: Address,
  choice: bigint,
): Promise<void> {
  const ciphertext = await encryptVote(fixture.zap, fixture.space.address, ciphertextOwner, choice);
  const voteArgs = encodeVoteArgs(voter, proposalId, ciphertext);
  await writeAndWait("Cast mismatched ciphertext-owner vote", {
    address: fixture.txAuthenticator.address,
    abi: fixture.txAuthenticator.abi,
    functionName: "authenticate",
    args: [fixture.space.address, voteSelector, voteArgs],
    // Forward the fee so the call reverts (if it does) for ciphertext-owner reasons, not fee reasons.
    value: fixture.fee,
  });
}

export type ProposalResult = {
  againstVotes: bigint;
  forVotes: bigint;
  abstainVotes: bigint;
  passed: boolean;
};

/// Blocks until the proposal's voting window has closed (reveal is gated to block >= maxEndBlockNumber).
export async function waitForVotingPeriodEnd(fixture: Fixture, proposalId: bigint): Promise<void> {
  const proposal = (await publicClient.readContract({
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "proposals",
    args: [proposalId],
  })) as readonly unknown[];
  // proposals() tuple: author, startBlockNumber, executionStrategy, minEndBlockNumber, maxEndBlockNumber, ...
  const maxEndBlockNumber = BigInt(proposal[4] as number | bigint);
  for (;;) {
    const current = await publicClient.getBlockNumber();
    if (current >= maxEndBlockNumber) break;
    console.log(`Waiting for voting period to end: block ${current} / ${maxEndBlockNumber}`);
    await sleep(3000);
  }
}

/// Grants the sponsor decrypt access (requestReveal) and returns the attested decryptions of the
/// three frozen tallies, indexed [against(0), for(1), abstain(2)].
export async function prepareTallies(fixture: Fixture, proposalId: bigint): Promise<DecryptionResult[]> {
  await waitForVotingPeriodEnd(fixture, proposalId);

  await writeAndWait("Request reveal (grant decrypt access to tallies)", {
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "requestReveal",
    args: [proposalId],
  });

  // Poll for the tally handles (Base Sepolia public RPCs are eventually-consistent).
  let handles: HexString[] = [];
  for (let attempt = 1; attempt <= 20; attempt++) {
    const [against, forH, abstain] = (await publicClient.readContract({
      address: fixture.space.address,
      abi: fixture.space.abi,
      functionName: "getVoteTallyHandles",
      args: [proposalId],
    })) as [HexString, HexString, HexString];
    handles = [against, forH, abstain];
    if (handles.every((h) => h && h !== "0x")) break;
    if (attempt === 20) throw new Error("Tally handles unavailable after poll");
    await sleep(1500);
  }

  console.log("Tally handles [against, for, abstain]:", handles);
  const tallies = await decryptWithRetry(fixture.zap, handles);
  console.log(
    "Decrypted tallies [against, for, abstain]:",
    tallies.map((t) => t.value.toString()),
  );
  return tallies;
}

/// Submits attested tally decryptions to finalizeReveal, locking the cleartext result on-chain.
export async function finalizeReveal(fixture: Fixture, proposalId: bigint, tallies: DecryptionResult[]): Promise<void> {
  const encoded = tallies.map((t) => ({ attestation: t.attestation, signatures: t.signatures }));
  await writeAndWait("Submit tally attestations to Space.finalizeReveal", {
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "finalizeReveal",
    args: [proposalId, encoded],
  });
}

/// Full reveal: wait, requestReveal, decrypt tallies, finalizeReveal, and return the locked result.
export async function revealProposal(fixture: Fixture, proposalId: bigint): Promise<ProposalResult> {
  const tallies = await prepareTallies(fixture, proposalId);
  await finalizeReveal(fixture, proposalId, tallies);
  return getResult(fixture, proposalId);
}

export async function getResult(fixture: Fixture, proposalId: bigint): Promise<ProposalResult> {
  const result = (await publicClient.readContract({
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "result",
    args: [proposalId],
  })) as readonly [bigint, bigint, bigint, boolean];
  return { againstVotes: result[0], forVotes: result[1], abstainVotes: result[2], passed: result[3] };
}

/// Executes a revealed-and-passed proposal.
export async function executeProposal(fixture: Fixture, proposalId: bigint, executionPayload: Hex = "0x"): Promise<void> {
  await writeAndWait("Execute revealed proposal via Space.execute", {
    address: fixture.space.address,
    abi: fixture.space.abi,
    functionName: "execute",
    args: [proposalId, executionPayload],
  });
}

export async function getProposalStatus(fixture: Fixture, proposalId: bigint): Promise<number> {
  // After finalizeReveal/execute, the new status may not be visible on every RPC node
  // immediately. Poll until the status is terminal (>=3 covers Accepted/Executed/
  // Rejected/Cancelled), or 10 attempts.
  let status = 0;
  for (let attempt = 1; attempt <= 10; attempt++) {
    status = (await publicClient.readContract({
      address: fixture.space.address,
      abi: fixture.space.abi,
      functionName: "getProposalStatus",
      args: [proposalId],
    })) as number;
    if (status >= 3) return status;
    if (attempt === 10) break;
    await sleep(1500);
  }
  return status;
}

export async function expectRevert(label: string, fn: () => Promise<unknown>): Promise<void> {
  try {
    await fn();
  } catch (error) {
    console.log(`${label}: reverted as expected (${shortError(error)})`);
    return;
  }
  throw new Error(`${label}: expected revert but call succeeded`);
}

export async function deploy(label: string, artifactPath: string, args: unknown[] = []): Promise<Deployment> {
  const artifact = await readArtifact(artifactPath);
  const nonce = await publicClient.getTransactionCount({ address: sponsor.address, blockTag: "pending" });
  const hash = await walletClient.deployContract({
    abi: artifact.abi,
    bytecode: artifactBytecode(artifact),
    args,
    nonce,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (!receipt.contractAddress) {
    throw new Error(`${label} deployment did not return a contract address`);
  }
  console.log(`${label}: ${receipt.contractAddress} (${hash})`);
  return { address: receipt.contractAddress, abi: artifact.abi };
}

export async function writeAndWait(
  label: string,
  // `value` is widened to bigint so payable calls (e.g. the voter-pays vote) can forward the Inco fee;
  // viem's broad-Abi overload otherwise types value as `undefined`.
  request: Omit<Parameters<typeof walletClient.writeContract>[0], "value"> & { value?: bigint },
): Promise<Hash> {
  // Some Base Sepolia RPCs return a too-low eth_estimateGas (~36k) for tuple-heavy
  // calls right after the target contract is deployed — the mempool view of the new
  // bytecode is stale. Estimate explicitly with retries and apply a 2x buffer.
  let gas: bigint | undefined;
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const estimated = (await publicClient.estimateContractGas({
        address: (request as any).address,
        abi: (request as any).abi,
        functionName: (request as any).functionName,
        args: (request as any).args,
        value: (request as any).value,
        account: sponsor,
      })) as bigint;
      // If estimate is suspiciously low, retry – odds are the node hasn't seen the deploy yet.
      if (estimated < 50_000n && attempt < 5) {
        await sleep(1500);
        continue;
      }
      gas = (estimated * 2n) + 50_000n;
      break;
    } catch (err) {
      if (attempt === 5) throw err;
      await sleep(1500);
    }
  }
  const nonce = await publicClient.getTransactionCount({ address: sponsor.address, blockTag: "pending" });
  const hash = (await walletClient.writeContract({ ...(request as any), gas, nonce })) as Hash;
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`${label}: ${hash} [${receipt.status}]`);
  if (receipt.status !== "success") {
    throw new Error(`${label} failed`);
  }
  return hash;
}

export async function decryptWithRetry(zap: IncoClient, handles: HexString[]): Promise<DecryptionResult[]> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= decryptRetries; attempt++) {
    try {
      const results = await zap.attestedDecrypt(walletClient, handles);
      return results.map(formatDecryption);
    } catch (error) {
      lastError = error;
      if (attempt === decryptRetries) break;
      console.log(`Attested decrypt not ready (${attempt}/${decryptRetries}); retrying in ${decryptRetryMs}ms`);
      await sleep(decryptRetryMs);
    }
  }
  throw lastError;
}

export async function encryptVote(
  zap: IncoClient,
  spaceAddress: Address,
  voter: Address,
  choice: bigint,
): Promise<HexString> {
  if (![0n, 1n, 2n].includes(choice)) {
    throw new Error("Vote choice must be 0, 1, or 2");
  }
  return (await zap.encrypt(choice, {
    accountAddress: voter,
    dappAddress: spaceAddress,
    handleType: handleTypes.euint256,
  })) as HexString;
}

export function encodeProposeArgs(author: Address, metadata: string, executionAddress: Address, params: Hex = "0x"): Hex {
  return encodeAbiParameters(
    parseAbiParameters(
      "address author, string metadataURI, (address addr, bytes params) executionStrategy, bytes userProposalValidationParams",
    ),
    [author, metadata, { addr: executionAddress, params }, "0x"],
  );
}

export function encodeVoteArgs(
  voter: Address,
  proposalId: bigint,
  ciphertext: HexString,
  userVotingStrategies: Array<{ index: number; params: Hex }> = [{ index: 0, params: "0x" }],
  metadata = "",
): Hex {
  return encodeAbiParameters(
    parseAbiParameters(
      "address voter, uint256 proposalId, bytes ciphertext, (uint8 index, bytes params)[] userVotingStrategies, string metadataURI",
    ),
    [voter, proposalId, ciphertext, userVotingStrategies, metadata],
  );
}

export function selector(signature: string): Hex {
  return keccak256(stringToBytes(signature)).slice(0, 10) as Hex;
}

export function voteDigest(input: {
  authenticator: Address;
  space: Address;
  voter: Address;
  proposalId: bigint;
  ciphertext: Hex;
  userVotingStrategies: Array<{ index: number; params: Hex }>;
  metadata: string;
}): Hex {
  const domainTypehash = keccak256(stringToBytes("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"));
  const voteTypehash = keccak256(
    stringToBytes(
      "Vote(address space,address voter,uint256 proposalId,bytes ciphertext,IndexedStrategy[] userVotingStrategies,string voteMetadataURI)IndexedStrategy(uint8 index,bytes params)",
    ),
  );
  const indexedStrategyTypehash = keccak256(stringToBytes("IndexedStrategy(uint8 index,bytes params)"));
  const domain = keccak256(
    encodeAbiParameters(parseAbiParameters("bytes32, bytes32, bytes32, uint256, address"), [
      domainTypehash,
      keccak256(stringToBytes("snapshot-x")),
      keccak256(stringToBytes("1")),
      BigInt(baseSepolia.id),
      input.authenticator,
    ]),
  );
  const strategyHashes = input.userVotingStrategies.map((strategy) =>
    keccak256(
      encodeAbiParameters(parseAbiParameters("bytes32, uint8, bytes32"), [
        indexedStrategyTypehash,
        strategy.index,
        keccak256(strategy.params),
      ]),
    ),
  );
  const strategiesHash = keccak256(encodePacked(strategyHashes.map(() => "bytes32"), strategyHashes));
  const structHash = keccak256(
    encodeAbiParameters(parseAbiParameters("bytes32, address, address, uint256, bytes32, bytes32, bytes32"), [
      voteTypehash,
      input.space,
      input.voter,
      input.proposalId,
      keccak256(input.ciphertext),
      strategiesHash,
      keccak256(stringToBytes(input.metadata)),
    ]),
  );

  return keccak256(encodePacked(["bytes2", "bytes32", "bytes32"], ["0x1901", domain, structHash]));
}

async function readArtifact(relativePath: string): Promise<Artifact> {
  const artifact = await readFile(resolve(repoRoot, relativePath), "utf8");
  return JSON.parse(artifact) as Artifact;
}

function artifactBytecode(artifact: Artifact): Hex {
  const bytecode = typeof artifact.bytecode === "string" ? artifact.bytecode : artifact.bytecode?.object;
  if (!bytecode || bytecode === "0x") {
    throw new Error("Artifact has no deployable bytecode");
  }
  return bytecode;
}

function formatDecryption(result: any): DecryptionResult {
  const value = result.plaintext.value as bigint | boolean;
  const encodedValue = pad(toHex(typeof value === "boolean" ? (value ? 1 : 0) : value), { size: 32 });

  return {
    handle: result.handle as HexString,
    value,
    attestation: {
      handle: result.handle as HexString,
      value: encodedValue,
    },
    signatures: result.covalidatorSignatures.map((signature: Uint8Array) => bytesToHex(signature)),
  };
}

function shortError(error: unknown): string {
  if (error instanceof Error) {
    return error.message.split("\n")[0] ?? error.message;
  }
  return String(error);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing ${name}. See inco-base-sepolia-runner/.env.example`);
  }
  return value;
}
