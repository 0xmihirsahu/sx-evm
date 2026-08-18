# Inco Snapshot Base Sepolia Runner

This is an isolated smoke runner for exercising the Snapshot `Space` contracts with the real Inco JS SDK on Base Sepolia.

It deploys a minimal setup:

- `Space`
- `EthTxAuthenticator`
- `VanillaVotingStrategy`
- `VanillaProposalValidationStrategy`
- `VanillaExecutionStrategy`

Then it:

1. Initializes `Space`.
2. Creates a proposal through `EthTxAuthenticator`.
3. Encrypts a private vote choice with `@inco/js`.
4. Votes through `EthTxAuthenticator`, forwarding the per-vote Inco fee as `msg.value` (voter-pays).
5. Waits for the voting period to end, then calls `Space.requestReveal`.
6. Reads the encrypted per-choice tally handles (`getVoteTallyHandles`).
7. Requests attested decryptions from Inco and submits them to `Space.finalizeReveal`.
8. Calls `Space.execute` when the revealed result passed.

Additional scripts cover:

- Multi-voter signature voting via `EthSigAuthenticator`
- Negative cases for ciphertext-owner mismatch and swapped attestations
- Strategy status variants for for/against/abstain private votes

## Setup

From repo root:

```bash
cd inco-base-sepolia-runner
npm install
cp .env.example .env
```

Fill in:

```bash
BASE_SEPOLIA_RPC_URL=...
PRIVATE_KEY_BASE_SEPOLIA=...
VOTER_PRIVATE_KEYS=... # optional except multi-voter/all
```

The private key must be funded with Base Sepolia ETH.

## Run

First make sure the Foundry artifacts exist:

```bash
cd ..
forge build
```

Then:

```bash
cd inco-base-sepolia-runner
npm run smoke
```

Run individual scenarios:

```bash
npm run smoke
npm run multi-voter
npm run negative
npm run strategies
```

Run everything:

```bash
npm run all
```

`multi-voter` uses `EthSigAuthenticator`, so the keys in `VOTER_PRIVATE_KEYS` sign votes but do not need Base Sepolia ETH. The funded sponsor key submits those transactions.

## Notes

- Vote choice is encrypted client-side with `@inco/js`.
- `Space.vote` consumes one encrypted input via `newEuint256` and is `payable`. Under the voter-pays model the `Space` is no longer pre-funded; each vote forwards `inco.getFee()` as `msg.value` (the sponsor key supplies it when submitting). Reveal/execute carry no Inco fee.
- Reveal is gated to after the voting window closes. `MAX_VOTING_DURATION` (default `30` blocks) sets the window; the runner waits for it to elapse before `requestReveal`.
- The runner uses `VOTE_CHOICE=1` by default (`0 = against`, `1 = for`, `2 = abstain`).
- Each scenario deploys fresh contracts by default so runs are isolated and deterministic.
