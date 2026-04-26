# Full critique of `paper-2.pdf`

Second pass. The substantive fixes from critique-1 have landed cleanly. The paper reads better and the logical gaps are plugged. But it is still 7 pages (target: 6) and a close re-read surfaces fresh issues.

## Critical issues

### C1. Still 7 pages

This must get to 6. After the previous pass the obvious short-term cuts are gone; deeper moves are needed. Candidates, in order of least to most painful:

- Abstract is at a natural length but carries a clause "producing a single merkle chain from CPU architecture to signed result" that is arguably already implied by the contribution listing; it duplicates.
- §2 "Runtime integrity is shared ground" paragraph is good but the ME/PSP sentence at the end is out of place structurally; could be folded into §3 actors.
- §4 AO-Core has a paragraph about "ingredients exist now, etc." that appears again in the conclusion. One can go.
- The Residual Threats section currently has one paragraph with 7 clauses; tight but could be shortened to 4–5 clauses focusing on what is genuinely distinctive (e.g., the Rowhammer clause can be removed since it is a general DRAM concern not a LapEE-specific one, and we mention it once already).
- Appendix/methodology: fold the four sub-points into two compact sentences; delete the "sources" enumeration entirely and just cite the sources where we use the numbers.
- Table captions are slightly verbose; could drop 10–15 words each.
- Figure captions for Figure 2 can go down to one sentence.

This is mechanical work, not architectural.

### C2. The "conditional on A1" framing is repeated three times

Once in §2 (shared ground), once in §4 (conditional structurally identical), once implied in §5 (workload integrity requires honest guest kernel). We risk sounding defensive. Consolidate into one strong statement in §2, and reference back from §4.

### C3. The "published to a public immutable log (e.g., Arweave)" phrasing is honest but now reads as if we are distancing from AO

After the fix in critique-1, the phrasing is accurate but introduces ambiguity about whether AO/Arweave matters to the design or is one option among many. The paper is written for the AO ecosystem; readers outside it need the generic phrasing, but readers inside will notice the hedging. Better: "published to Arweave~\cite{arweave}" (add the citation) on first use, with no further generalization.

### C4. The two-party framing in §3 is still a bit thin

"Consumer $C$ submits work, trusted for own data. Operator $O$ owns the machine..." — the reader may not realize these are defined relative to a \emph{per-request} interaction, not a persistent binding. In AO-Core, a computation might flow through multiple operators. We should be explicit: each operator attests independently; a consumer's trust decision is about the entire transcript of operators participating.

## Major issues

### M1. The "four layers" replay defense numbering still has a stated weakness

We now say: (1) hardware XTS tweak, (2) BEAM immutability, (3) allocator randomization, (4) TPM counters. Reading critically, (1) is confidentiality-plus-relocation, not replay defense. The tweak prevents ciphertext from being *moved* to a different address, but the whole premise of the replay attack we worry about is replaying ciphertext \emph{at the same address}, where the tweak does not help. So listing (1) as a "layer" of replay defense is actually incorrect.

**Fix:** Drop (1) from the replay-defense list. Keep it in the introductory paragraph of §5.2 as the confidentiality-at-rest claim. The replay defenses are then three layers: immutability, randomization, TPM counters.

### M2. "Golden" was supposed to replace "blessed"

I missed several instances. Grep for "blessed" shows it still appears in the Threat Model assumptions ("blessed image"), in §4 attestation evidence, and in the attack table ("blessed PCR set" — now changed to "golden PCR set" in one place but not all). Make it consistent.

### M3. The "(e.g., Arweave)" generic phrasing undermines the merkle-chain argument

Once we say the signed artifact can be published to any public immutable log, the implication is that Arweave-specific properties don't matter. But the merkle-chain-from-CPU-to-result argument derives its force partly from the fact that AO-Core is a merkle-structured substrate; without a merkle-structured receiving ledger the chain doesn't extend past the node. Either bite the bullet and say "Arweave" (it is the destination for this specific system) or generalize further to "any log with cryptographic permanence." My preference: just say "Arweave" — we are writing for a specific system.

### M4. Abstract "CPU architecture to signed result" line is beautiful but unqualified

We say the merkle chain runs "from CPU architecture to signed result." That is accurate in spirit but strictly speaking CPU architecture is a \emph{property} captured in firmware measurements, not an \emph{event} in the chain. A reader who zooms in will notice. Better: "from firmware measurement to signed result" — slightly less evocative but technically precise.

### M5. The §7 "Hardware Availability" Methodology paragraph now reads like an apology

After compressing the appendix, the methodology paragraph acknowledges limitations three times in four sentences: "informed estimates, not market-survey data," "community compatibility lists," "not formal." Over-hedged. One acknowledgement suffices.

## Minor issues

### m1. "Same order of magnitude" appears twice in §2

Once in the introduction, once in the ME/PSP paragraph. Cut one.

### m2. "No side-load path" is jargon

For readers outside Erlang/HyperBEAM, "no side-load path" reads as opaque. Rephrase: "devices cannot be injected at runtime outside the first-load path."

### m3. The closing line of §8 conclusion is elegant but a touch glib

"The ingredients exist now. They ship in ordinary business hardware. We have only to compose them." — "we have only to compose them" is both the claim and suggests the composition is trivial. It isn't. A small adjustment: "Composing them is the work we now do."

### m4. "$C$" and "$O$" are introduced but never used again

If the consumer and operator letters aren't referenced later in the paper, the math-style notation is pretense. Either reference them ("a consumer $C$ verifying against an operator $O$'s attestation") or drop the letters.

### m5. Hyphenation inconsistency

"decentralized-compute" and "decentralized compute" both appear. The former is only required when the compound is a modifier; standardize.

### m6. The term "golden PCR set" appears but is not defined

First use should be something like "the expected PCR set (the \emph{golden} set)".

### m7. Device-author trust set

The phrase "the operator's device-author trust set" in §4 is awkward. Better: "the operator's \texttt{trusted\_signers} set."

### m8. Related work paragraph is packed

Six references in 5 lines. Reader struggles. Could become two paragraphs with slight expansion (but that fights the 6-page target). Leave as-is but rearrange sentence order so the most important comparison (Apple PCC) is at the head and BuilderNet (most important for the operator-measurement point) is at the tail with a bit more weight.

## Structural

### S1. §6 Residual Threats is odd — it is currently a single paragraph but the other sections have structure

We removed the bullet list. The dense paragraph packs in 7 separate topics, which is harder to parse than a tight list. A middle ground: 4 short paragraphs, one per category (physical, runtime integrity, supply chain, out-of-scope).

### S2. The "Implementation, Related Work, Conclusion" super-section feels rushed

Three distinct topics under one header. Could split into separate \paragraph blocks (already done) but the section title elides that they are three things. Rename to something like "Implementation, Comparison, and Conclusion" or just drop the super-section and have three tiny sections. On reflection: the unified section is a deliberate space-saving choice and is fine, but rename to "Implementation and Conclusion" and move Related Work into an earlier section or the abstract citations.

Actually better: move the Related Work content to §2 Positioning (which is where comparisons belong). Then "Implementation and Conclusion" is a short final section.

## Evidentiary

### E1. "BuilderNet uses TDX with cloud-operator-set measurements"

I stated this confidently. BuilderNet actually uses TDX attestation validated against measurements published by Flashbots themselves, I think, not the cloud operator. If the distinction matters (it affects how much circular-trust critique lands), I should check. As written, the paper might misrepresent BuilderNet's architecture. Safer phrasing: "uses TDX attestation in a cloud deployment model where the operator-supplied image and expected measurement are trust-bound to the service operator rather than to open reproducible source."

### E2. The RSASSA-PSS argument for replayed signatures is technically fine but narrow

We argue that re-signing the same message under PSS produces different bytes but the same message-commitment, so replay does not break semantics. True, but this assumes LapEE uses PSS specifically; the paper does not say which signature scheme. If a deployment uses ECDSA or deterministic Ed25519, the bytes would be identical under replay — which is arguably \emph{worse} for an operator trying to prove distinct events, since the network sees identical signatures. This is a subtle point but worth flagging: LapEE's choice of signature scheme has replay-visibility implications.

### E3. The "$100\times$ larger installed base, $50$--$100\times$ lower cost" claim

Numbers: the TDX-capable server market share is unknown in hard numbers. If we say "100x larger installed base," we should have some grounding beyond intuition. I used "low-single-digit percent of the x86 server installed base" for TDX, which if we assume $\sim$2\%, gives a $50\times$ ratio; if we assume $\sim$1\%, $100\times$. Either way the claim is noisy but in the right ballpark. Flag as estimate in the methodology note.

## Summary

The revision is good. The 6-page cut is the highest priority, followed by M1 (remove the XTS tweak from the replay-defense layer count, which is technically wrong), M3 (commit to Arweave), and the consistency cleanups.
