# Advanced Track: Ritual-Native Hidden Submissions

This document is the design deliverable for the homework's **Advanced
Track** — a more Ritual-native version of the bounty judge where
encrypted answers can stay hidden until the AI judging step is
complete, evaluated inside a Ritual TEE.

It is **not** implemented in this repository; full implementation
requires wiring the Ritual TEE executor and DKMS precompile
(`0x081B`) for key handling, which is beyond the workshop's existing
`LLM_INFERENCE_PRECOMPILE` integration. Per the homework statement:

> *"Keep the required track simple. The advanced track can be a design
> document if full implementation is too complex."*

## Goals

1. Plaintext answers must **never** appear on-chain — not before
   judging, not during, not after, except via an opt-in revealed
   bundle.
2. AI judging must see all eligible answers **together** in one batched
   LLM call, inside the TEE.
3. The final revealed bundle is published off-chain with an on-chain
   hash commitment, so verifiers can check integrity.
4. The owner retains human-in-the-loop finalization authority; the AI
   only recommends.

## Threat model

The commit-reveal pattern protects against **late copy**: a participant
who joins after the first submission sees only hashes, not answers.
But after `revealAnswer()`, plaintext is on-chain.

The Ritual-native pattern additionally protects against **observer
privacy**: nobody — not even after judging — sees plaintext on-chain.
Only the bundle hash is published.

The remaining threat: a malicious TEE operator could leak plaintext.
Ritual mitigates this via remote attestation; the contract can verify
attestation reports before accepting judging output.

## Design

### Components

```
                ┌────────────────────┐
                │  BountyJudge       │
                │  (on-chain)        │
                │                    │
                │  ciphertexts[]     │  ← stores only encrypted
                │  bundlesHash       │     submissions
                │                    │
                └─────────┬──────────┘
                          │
                          │  judgeAll()
                          ▼
                ┌────────────────────┐
                │  Ritual TEE        │
                │  Executor          │
                │                    │
                │  1. attest()       │  ← remote attestation
                │  2. decrypt()      │  ← using DKMS / enclave key
                │  3. llmJudge()     │  ← batched LLM inference
                │  4. publish()      │  ← bundle to IPFS/storage
                └─────────┬──────────┘
                          │
                          ▼
                ┌────────────────────┐
                │  Storage layer     │
                │  (IPFS / Arweave)  │
                │                    │
                │  /bounty/42/       │
                │    bundle.json     │  ← revealed answers + ranking
                │                    │
                │  hash on-chain     │
                └────────────────────┘
```

### Submission flow

1. Participant fetches the **enclave public key** from Ritual (via
   `DKMS_PRECOMPILE` or a known registry).
2. Participant encrypts their answer with that key:
   `ciphertext = enclavePubKey.encrypt(answer)`.
3. Participant calls
   `submitEncrypted(bountyId, ciphertext, commitmentHash)` where
   `commitmentHash = keccak256(answer)` so they can later prove the
   decrypted answer matches what they submitted.
4. The contract stores the ciphertext and `commitmentHash`. No
   plaintext ever lands on-chain.

### Judging flow

1. Owner waits until the reveal deadline.
2. Owner calls `judgeAll(bountyId, llmPrompt, bundleRef)` after the
   TEE has produced a result. The contract:
   a. Verifies the TEE's attestation report
      (via `SECP256R1_PRECOMPILE` or a verify-and-recover pattern).
   b. Verifies the returned `bundleHash` matches the bundle stored in
      IPFS.
   c. Stores the bundle hash and ranking on-chain.

### Finalization flow

1. Owner calls
   `finalizeWinner(bountyId, winnerIndex, bundleRef, bundleHash)`.
2. The contract verifies:
   - `bundleHash == stored.bundleHash` (judging already stored it)
   - `winnerIndex` is within `ciphertexts.length`
   - `winnerCommitment == keccak256(decrypted[winnerIndex])` — requires
     re-decryption or a TEE-signed statement
3. The winner pulls their reward via `claimReward()`.

### What is on-chain vs off-chain

| Item | Location |
|---|---|
| Encrypted submission | On-chain (`bytes ciphertext`) |
| Commitment hash of plaintext | On-chain (`bytes32 commitmentHash`) |
| Bounty metadata (title, rubric, deadlines, reward) | On-chain |
| Decrypted plaintext | Never on-chain |
| Revealed bundle (all answers + ranking) | Off-chain (IPFS / storage) |
| Bundle hash | On-chain |
| TEE attestation report | On-chain (or verified off-chain and hash stored) |
| Winner address | On-chain |
| Reward payout | On-chain (ETH transfer) |

### How the LLM receives all submissions together

In the TEE:
1. The TEE fetches the bundle from IPFS using a key it controls.
2. It iterates the bundle entries, filters out non-matching
   commitment hashes, and constructs one prompt:
   *"Given the rubric X, rank the following N submissions..."*
3. It calls the LLM precompile once with the batched prompt.
4. It writes the result back to the bundle and re-uploads to IPFS.

### How the final reveal happens

The bundle is published as JSON in IPFS. The contract only stores the
bundle's `keccak256` hash. Anyone can fetch the bundle from IPFS and
verify the hash. The bundle contains:

```json
{
  "bountyId": 42,
  "ranking": [
    {"index": 2, "score": 94, "reason": "Best satisfies the rubric."}
  ],
  "winnerIndex": 2,
  "answers": [
    {"index": 0, "commitment": "0xabc...", "plaintext": "...", "decryptedBy": "tee-attestation-id"},
    ...
  ],
  "summary": "Submission 2 is the strongest answer.",
  "teeAttestation": "0x..."
}
```

### How the contract verifies the final bundle

1. `judgeAll` requires the TEE to provide:
   - A signed bundle hash
   - An attestation report
2. The contract stores `(bundleHash, attestationHash)`.
3. `finalizeWinner` requires the caller to pass `bundleRef` and
   `bundleHash`. The contract verifies `bundleHash == stored.bundleHash`.

## Ritual feature usage

| Ritual feature | How it's used |
|---|---|
| TEE executor | Decrypts ciphertexts, runs batched LLM call, signs bundle |
| DKMS precompile (`0x081B`) | Distributes / rotates the enclave public key |
| `SECP256R1_PRECOMPILE` (`0x0100`) | Verifies the TEE's attestation signature |
| `LLM_INFERENCE_PRECOMPILE` (`0x0802`) | Runs the batched judging prompt inside the TEE |
| Human-in-the-loop finalization | Owner still calls `finalizeWinner()`; AI only recommends |

## Why this design uses Ritual, not just the LLM

The required track already uses Ritual's `LLM_INFERENCE_PRECOMPILE`.
The advanced track goes further by using Ritual's **enclave-based
execution model**: the TEE is what makes hidden judging possible.
Generic EVM chains have no equivalent; you'd need a ZK coprocessor or
MPC layer, both of which are heavier and slower than a TEE.

## Why the design is a doc, not code

Implementing the full TEE wiring requires:
- A registered enclave identity in Ritual's DKMS
- An on-chain attestation verifier contract
- A storage layer (IPFS pinning, etc.)
- A bundle publisher service

These are out of scope for a single-homework deliverable, but the
**contract surface** is small and could be implemented incrementally:

```solidity
// Sketch — not compiled, illustrative only

function submitEncrypted(
    uint256 bountyId,
    bytes calldata ciphertext,
    bytes32 commitmentHash
) external;

function judgeAll(
    uint256 bountyId,
    bytes calldata llmInput,
    bytes32 bundleHash,
    bytes calldata attestationReport
) external;

function finalizeWinner(
    uint256 bountyId,
    uint256 winnerIndex,
    string calldata bundleRef,
    bytes32 bundleHash
) external;
```

The required track's contract handles the simpler case where plaintext
appears on-chain after reveal. The advanced contract stores ciphertext
and lets the TEE do the rest.