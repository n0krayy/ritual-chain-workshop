# Reflection: Public, Hidden, AI, Human

In a bounty system that uses AI for judging, four boundaries must be
designed deliberately: **what is public**, **what stays hidden**, **what
the AI decides**, and **what a human finalizes**.

**Public** state belongs on-chain and should be enough for anyone to
verify the system ran honestly: bounty metadata, the list of
submission commitments, the ranking hash, the final winner address, and
the bundle hash for the revealed answers. Anyone can fetch the
revealed bundle from IPFS and re-compute the hash. This is what makes
the system auditable without trusting the owner.

**Hidden** state is everything participants do not want exposed to
competitors: their plaintext answer, their random salt, and the
internal reasoning of the AI judge during a single submission. The
commit-reveal pattern hides plaintext during the submission phase by
storing only a hash. The advanced-track Ritual-native design goes
further by hiding plaintext even after judging — only the bundle hash
is published, and the plaintext lives in IPFS rather than in contract
storage. The AI never sees plaintext on-chain; the TEE handles it.

**AI** should decide things that are reproducible, mechanical, and
have a clear rubric: ranking submissions against the rubric, scoring
each on a fixed scale, summarizing differences. The LLM should not
decide who gets paid — it can recommend a winner, but the contract
should never auto-pay from raw LLM output without the owner's
finalization step. AI output must be parsed into a deterministic
structure (ranking + score + reason), hashed, and stored. The owner
binds that hash to a specific winner.

**Human** finalization is non-negotiable for any system that handles
real money. The owner reviews the AI's ranking, confirms the winner,
and triggers the payout. This means a malicious or buggy AI cannot
drain the contract — at worst it produces a bad ranking that the
owner rejects. The pull-pattern `claimReward()` further ensures the
winner pays gas to receive their payout, which lets them notice and
reject an incorrect finalization.

The boundary is: **public for verifiability, hidden for fairness, AI
for ranking, human for payment**. Each piece of state should live on
exactly one side of those four lines.