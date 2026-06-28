# AI Bounty Judge — Privacy-Preserving Homework

This directory extends the Ritual workshop's `AIJudge` starter into a
**privacy-preserving** bounty judge using a **commit-reveal** submission
flow. Late participants can no longer read earlier answers and copy them
before judging.

## What was built

- **`contracts/BountyJudge.sol`** — single contract implementing the
  commit-reveal flow plus the original `judgeAll` Ritual LLM precompile
  integration. Submission phase only stores a keccak256 commitment;
  plaintext answers are revealed only after the submission deadline.
- **`test/BountyJudge.t.sol`** — 24 Solidity unit tests covering create,
  commit, reveal (valid + 6 invalid variants), deadline enforcement,
  replay protection, phase transitions, and access control.
- **`ignition/modules/BountyJudge.ts`** — Hardhat Ignition deploy module.
- **`docs/ARCHITECTURE.md`** — design notes comparing commit-reveal
  (this implementation) with Ritual-native TEE/encrypted judging.
- **`docs/ADVANCED_TRACK.md`** — design document for the Ritual TEE flow.
- **`docs/REFLECTION.md`** — reflection on public/hidden/AI/human
  boundaries in bounty systems.

## Bounty lifecycle

```
                ┌───────────────────────┐
                │  Owner creates bounty │   msg.value = reward
                │  (title, rubric,      │   submissionDeadline
                │   submissionDeadline, │   revealDeadline
                │   revealDeadline)     │
                └──────────┬────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │  Phase: Submission                   │
        │  Each participant calls              │
        │    submitCommitment(bountyId, hash)  │
        │  where                               │
        │    hash = keccak256(                 │
        │      abi.encodePacked(               │
        │        answer, salt, msg.sender,     │
        │        bountyId))                    │
        │  One commitment per address.         │
        │  Plaintext answer stays off-chain.   │
        └──────────────────┬───────────────────┘
                           │  block.timestamp ≥ submissionDeadline
                           ▼
        ┌──────────────────────────────────────┐
        │  Phase: Reveal                       │
        │  Each participant calls              │
        │    revealAnswer(bountyId, answer,    │
        │                  salt)               │
        │  Contract recomputes hash, verifies  │
        │  it matches the commitment.          │
        │  Only valid reveals are eligible.    │
        └──────────────────┬───────────────────┘
                           │  block.timestamp ≥ revealDeadline
                           ▼
        ┌──────────────────────────────────────┐
        │  Phase: Judging                      │
        │  Owner builds a batched LLM input    │
        │  from all eligible revealed answers  │
        │  and calls                           │
        │    judgeAll(bountyId, llmInput,      │
        │             rankingHash)             │
        │  Contract invokes the Ritual LLM     │
        │  precompile, stores completion +     │
        │  ranking hash.                       │
        └──────────────────┬───────────────────┘
                           │
                           ▼
        ┌──────────────────────────────────────┐
        │  Phase: Finalized                    │
        │  Owner calls                         │
        │    finalizeWinner(bountyId, idx,     │
        │                    answersRef,       │
        │                    answersHash)      │
        │  Winner pulls their reward via       │
        │    claimReward(bountyId)             │
        └──────────────────────────────────────┘
```

## Quick start

### Install

```bash
npm install
```

### Build

```bash
npx hardhat build
```

### Run tests

```bash
npx hardhat test solidity
```

### Typecheck

```bash
npx hardhat build && npx tsc --noEmit
```

### Deploy to Ritual (chainId 1979)

The recommended path is Hardhat Ignition:

```bash
npx hardhat keystore set DEPLOYER_PRIVATE_KEY
npx hardhat ignition deploy --network ritual \
  ignition/modules/BountyJudge.ts
```

For non-interactive deploys (CI / scripted), use the Viem-based
fallback script:

```bash
DEPLOYER_PRIVATE_KEY=0x... node scripts/deploy-direct.mjs
```

### Live deployment (homework submission)

| Field | Value |
|---|---|
| Contract address | `0x6b2c16e11e9b5509b9335921f7af02e58c899021` |
| Deploy tx hash | `0x320f9396fc5b3a0e83aedef99c3671c52f9bdd470f78194f23f0da8b55d0ffdd` |
| Block | `38656891` |
| Gas used | `1,516,484` |
| Network | Ritual (chainId 1979) |
| RPC | `https://rpc.ritualfoundation.org` |
| Explorer | `https://explorer.ritualfoundation.org/address/0x6b2c16e11e9b5509b9335921f7af02e58c899021` |

## Commit-reveal commitment formula

```solidity
bytes32 commitment = keccak256(
  abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

`msg.sender` and `bountyId` are part of the hash so a participant cannot
copy someone else's commitment and reveal it themselves.

## Security properties

- **Late copy protection** — plaintext answers are not on-chain until the
  reveal phase, so later participants gain no information advantage by
  reading earlier submissions.
- **One commitment per address per bounty** — enforced via
  `submitterToIndex` mapping.
- **Deadline enforcement** — submissions / reveals are gated by the
  current phase (`Submission`, `Reveal`, `Judging`).
- **Pull-pattern payout** — `claimReward()` lets the winner pay gas when
  they want, avoiding re-entrancy risks in `finalizeWinner`.
- **Off-chain answers bundle** — final reveal publishes
  `revealedAnswersRef` (off-chain pointer) and `revealedAnswersHash`
  on-chain, so the bundle can be cross-checked.

## Further reading

- [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) — commit-reveal vs
  Ritual-native comparison.
- [`docs/ADVANCED_TRACK.md`](./docs/ADVANCED_TRACK.md) — design doc for
  TEE-based encrypted judging.
- [`docs/REFLECTION.md`](./docs/REFLECTION.md) — public/hidden/AI/human
  boundaries.