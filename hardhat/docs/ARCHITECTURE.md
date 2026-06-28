# Architecture: Commit-Reveal vs Ritual-Native

This document compares two designs for keeping AI bounty submissions
hidden until judging is complete. The first is the implemented
commit-reveal pattern; the second is the advanced-track design
documented in `ADVANCED_TRACK.md`.

## 1. Commit-reveal (implemented, required track)

### Flow

1. **Submission phase.** Each participant submits only
   `commitment = keccak256(answer, salt, msg.sender, bountyId)`. The
   plaintext answer never touches the chain.
2. **Reveal phase.** After the submission deadline, each participant
   submits `(answer, salt)`. The contract recomputes the hash and
   checks it matches the stored commitment.
3. **Judging phase.** After the reveal deadline, the owner batches all
   eligible revealed answers into a single LLM prompt and calls
   `judgeAll()`. The Ritual LLM precompile returns the ranking.
4. **Finalization.** The owner calls `finalizeWinner()` to select a
   winner, then publishes an off-chain `revealedAnswersRef` and
   `revealedAnswersHash` for verifiability.
5. **Payout.** The winner calls `claimReward()` (pull pattern).

### Where plaintext exists

- **On-chain:** never, until after `revealAnswer()`.
- **Off-chain:** in the participant's wallet/UI when they construct
  their commitment.
- **During judging:** in the LLM precompile's runtime memory only,
  during the `judgeAll()` call.

### Pros

- **Works on any EVM chain.** No TEE required, no Ritual-specific
  cryptography. Can be deployed on Sepolia, Base, Arbitrum, etc.
- **Simple.** One contract, ~250 lines, easy to audit.
- **Verifiable on-chain.** All commitments and revealed answers are
  public; anyone can re-verify hash matches.

### Cons / limitations

- **Plaintext answers become public before judging.** Once
  `revealAnswer()` is called, the answer is in `Submission.answer` for
  the world to see. The AI still judges against the *latest* answers,
  but a curious observer can read them. In practice this is fine for
  bounty systems where answers are meant to be public eventually, but
  it is *not* fully private.
- **Two-phase UX.** Participants must save their `(answer, salt)`
  somewhere durable or they cannot reveal and lose their chance to win.
- **No protection against late entry between submission and reveal.**
  Anyone can still call `submitCommitment()` right before the
  submission deadline — but they cannot read earlier commitments'
  plaintext before revealing. The privacy guarantee is symmetric:
  nobody sees plaintext until the reveal phase opens.
- **Salt reuse or loss.** If a participant reuses a salt or loses it,
  they cannot reveal. The hash formula includes `msg.sender` so
  cross-participant salts are not catastrophic, but client UX must
  emphasize salt uniqueness.

## 2. Ritual-native (advanced track, design doc)

See `ADVANCED_TRACK.md` for the full design.

### Where plaintext exists

- **On-chain:** never. Only ciphertext or hash pointers.
- **Off-chain:** in the participant's wallet when encrypting.
- **During judging:** inside the Ritual TEE executor. Plaintext is
  decrypted by the TEE's enclave key, used for the LLM prompt, and
  never leaves the enclave unencrypted.
- **After judging:** revealed bundle published off-chain
  (`revealedAnswersRef`) with on-chain hash commitment.

### Pros

- **Stronger privacy.** Plaintext is never on-chain, even after judging
  — only the bundle hash is. The actual plaintext bundle lives in
  IPFS/storage, and the LLM only sees it inside the TEE.
- **Better fit for Ritual.** Uses Ritual's native TEE/encrypted
  primitives, not just its LLM precompile.

### Cons

- **Ritual-specific.** Tied to Ritual's TEE executor and key
  infrastructure.
- **More complex.** Encrypted submission, TEE attestation flow, bundle
  publishing. More attack surface.
- **Higher deployment cost.** Multiple components: TEE executor,
  storage layer, attestation verifier.

## When to use which

| Scenario | Use |
|---|---|
| Public bounty, answers will be revealed after judging anyway | Commit-reveal |
| Privacy-sensitive judging (e.g. medical, legal, internal R&D) | Ritual-native |
| Multi-chain deployment required | Commit-reveal |
| Need Ritual as the differentiator | Ritual-native |

For this homework, the **commit-reveal** track is implemented because it
is generic, simple, and exercises the core fairness property: late
participants cannot read earlier answers before they submit. The
Ritual-native track is documented but not implemented; full
implementation requires TEE executor wiring that goes beyond the
workshop's existing `LLM_INFERENCE_PRECOMPILE` integration.