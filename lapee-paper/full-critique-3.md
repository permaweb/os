# Full critique of `paper-3.pdf`

Third pass. The paper is at 6 pages, argument flows, logical gaps are plugged. This critique looks for the subtler issues that survive the first two passes.

## Critical issues

### C1. The Arweave citation is to `ao-core`, which is wrong

I wrote "published to Arweave~\cite{ao-core}" — but cite key `ao-core` points at the AO-Core docs, not an Arweave reference. There is no dedicated Arweave citation in `references.bib`. This is a bibliography error: the citation is factually wrong.

**Fix options:** (a) Add an Arweave cite (preferred; Williams et al. 2018 protocol paper); (b) drop the citation entirely and just say "to Arweave"; (c) cite AO-Core and make it "published to the Arweave-backed AO log."

### C2. The signature-scheme footnote in §5.2 is awkward mid-paragraph

"(LapEE uses PSS, so the bytes differ per signature; a deployment using deterministic ECDSA or Ed25519 should note that replayed signatures are byte-identical, which is relevant only if distinctness matters to a consumer)" — this is a genuine technical point, but it reads as an afterthought inside a parenthetical. Either commit to it as an architectural decision (and therefore state it cleanly: "LapEE uses RSA-PSS for this reason") or move it to a footnote.

### C3. The Conclusion sentence "Composing them is the work we do next" is ambiguous

Does "we" refer to the authors, the HyperBEAM project, the reader? A stronger close commits to an action: "Composing them into a ready-to-deploy appliance is ongoing engineering at \texttt{permaweb/hb-os}."

## Major issues

### M1. §3 Threat Model is now terse enough to lose clarity

After the cuts, the threat-model section compresses three concepts into one dense "Actors" paragraph. A reader unfamiliar with the system must parse "each request flows through one or more operators, each attesting independently" without prior context about AO-Core's multi-hop nature. The per-request framing is correct but introduced without setup. Either add a one-sentence introduction ("In AO-Core, a computation may traverse multiple operators; each attests independently, and a consumer's trust decision is over the full transcript.") or defer that framing to the AO-Core section.

### M2. The "conditional on A1" point has been cut everywhere — this may be over-correction

Previous critique noted it was repeated three times. It's now entirely absent from §4 and §5. That's too minimal — a reader following the AO-Core continuity argument should be reminded that the chain binds the transcript \emph{conditional on A1}, because it's the most common point reviewers will push on. One sentence in §4 is appropriate.

### M3. The "LapEE uses PSS" claim is not actually stated as a design decision anywhere

C2 above. The paper doesn't commit to a signature scheme. If it's PSS, say so in the architecture section. If it could be either, say so. If we don't actually care — why are we discussing it in §5.2?

### M4. "approximately 100×/50–100×" numbers in abstract and §8 aren't reconciled to the per-feature percentages in §8

In §8 I show 11–35% composite viability on random laptop purchases vs. low-single-digit % for TDX server installed base. If I use 35% vs 2%, the ratio is ~17×, not 100×. If I use the business-class-filtered 70% vs TDX's 2%, it's 35×. My "100×" claim in the abstract doesn't match my own cited numbers. Either adjust the claim to "roughly 20–70× larger installed base" or commit to a specific framing ("vs installed base of TDX-capable silicon, ...") and number.

**Fix:** Soften the abstract to "roughly an order of magnitude larger installed base at one to two orders of magnitude lower per-machine cost." Ambiguous enough to survive either reading without being misleading.

### M5. Figure 1 still says "HyperBEAM unikernel-style"

"Unikernel-style" is hedged. Either it is a unikernel (single-address-space, single-purpose, no traditional OS userspace) or it isn't. LapEE has Linux under HyperBEAM, so strictly speaking it is not a unikernel. The phrase "unikernel-style" captures "HyperBEAM is the sole userspace service" but may mislead readers into thinking we've eliminated the kernel distinction. Better: "single-service appliance" or "HyperBEAM as sole userspace service."

### M6. The "decentralized-compute threat model" is invoked repeatedly but never defined

The paper refers to "the decentralized-compute threat model" in the abstract, intro, and conclusion. What does it mean, exactly? The actors and capabilities in §3 define it, but we don't label them as "the decentralized-compute threat model." A reader who grabs just the intro will see the phrase used as if agreed terminology. Either define briefly in §1 ("threat model: adversarial operator with physical custody and root; honest consumer; untrusted network") or don't claim it's "the" model — say "for our threat model."

## Minor issues

### m1. "ALSR-per-allocation" has been cut

Previous version said the allocator randomization was "conceptually similar to ASLR-per-allocation." Current version doesn't. This was a useful pointer for readers familiar with ASLR. Consider restoring one word.

### m2. "Per-feature composition (product of rates)" is jargon

For a reader who is not a statistician, "product of rates" is opaque. Clearer: "multiplying the per-feature availability rates together."

### m3. Table 1 TCB row for LapEE is now very long

It's readable but visually dominates the other rows. Consider breaking into two columns (silicon + software) or using a nested `\parbox` structure.

### m4. The Apple PCC comparison in §8 is short but the Naik comparison is deeper

Related work sentence ordering puts Apple PCC first (one line) and Naik second (two sentences). Naik is more important for our argument (we contrast with it explicitly) but Apple PCC is more important structurally (architectural precedent). Current ordering is fine; the density difference is just noticeable.

### m5. "operator-enrolled Secure Boot on operator-owned hardware" in §2 Related Work

Our position against BuilderNet is: they use cloud-operator-set measurements, we don't. But we say "operator-enrolled Secure Boot and open publication of golden measurements against reproducible source" — three points. The sentence is long. Compress: "operator-enrolled Secure Boot and open measurements against reproducible source."

### m6. First mention of "golden PCR set" is still not defined

In §5.2 we say "the golden PCR set is satisfied" without definition. First use should be "the expected PCR set (\emph{golden})." (Same point as critique-2 m6; did I miss this in the edit pass?)

### m7. Tight line spacing in the attack table makes the continuation of "Debugger attach to HyperBEAM" awkward

"ptrace(PTRACE\_ATTACH), /proc/*/mem" wraps oddly. Could be abbreviated further.

### m8. "Composed, they produce an attested appliance"

The sentence is fine but "composed" is a touch passive-technical. "These four primitives combine into an attested appliance" is slightly stronger.

## Structural

### S1. §2 Positioning is the section that does the most rhetorical work

It asserts the TCB-equivalence claim that drives the whole thesis. Arguably, the "Runtime integrity is shared ground" paragraph could move up (become the first paragraph of §2) so that the rhetorical claim appears before the TCB table, not after. Readers would then encounter the framing, the comparison table, and the "so what" conclusion in a more logical order.

### S2. "Implementation and Conclusion" section title is accurate but the section has three distinct subsections

Implementation → Related work → Conclusion. The section title omits Related Work. Either rename or break into three.

### S3. No explicit "future work"

The paper doesn't have a "future work" section. For a short paper this is fine, but a formal hardware compatibility survey, multi-node coordination specifics, and detailed performance benchmarks are all plausible candidates worth flagging for follow-up. A single sentence in the Conclusion would cover this.

## Evidentiary

### E1. The installed-base ratio number is still a weak point (C.f. M4)

Even if I soften the abstract, §8 still makes the claim. Either I need a citation for "low-single-digit percent of x86 server installed base" for TDX, or I need to qualify as "by industry estimates."

**Fix:** Add "(industry estimates)" parenthetically in §8.

### E2. The memory-encryption-active MSR read is presented as portable

"Early init reads `IA32_TME_ACTIVATE` (Intel) or `SYSCFG` bit 23 (AMD)" — both real MSRs, but the exact bit semantics are: Intel `IA32_TME_ACTIVATE` bit 1 is "TME Enable" and is correct; AMD `SYSCFG` bit 23 is "MemEncryptionModeEn" but SME vs TSME vs SEV-family are distinguished by further bits in `MSR 0xC0010010` that we don't describe. A reviewer who implements this will find it insufficiently specified.

**Fix:** Add a footnote or cite: "See Intel TDX/TME programming reference and AMD PPR for full MSR semantics."

### E3. The "BuilderNet uses TDX in a deployment where the operator supplies both image and expected measurement" claim

Still potentially inaccurate (c.f. critique-2 E1). I should either verify or hedge with "in the dominant TDX deployment pattern, not specifically BuilderNet's current configuration."

## Summary

At 6 pages and with the core argument intact, this iteration is quite close to publishable. The critical issues (C1 bibliography error, C2/M3 signature-scheme framing) are genuine errors worth fixing; the major issues (M1, M2, M4, M6) are clarity and precision items; minor issues are polish. The paper is no longer substantially wrong anywhere that I can find on close reading. The remaining work is editorial.

Further iterations past this one would likely produce diminishing returns — a fourth pass could sharpen M4's ratio framing and clean up the remaining citation and MSR specificity, but the core argument and expression are now stable.
