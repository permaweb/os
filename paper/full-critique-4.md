# Full critique of `paper-4.pdf`

Fourth pass. The prior critique's concerns have been addressed. Remaining issues are polish and minor precision items; core structure, argument, and claims are stable.

## Remaining issues (minor)

### m1. "decentralized-compute threat model" still undefined explicitly

In the abstract and intro we invoke "the decentralized-compute threat model" as if a term of art. It isn't. The §3 threat model specifies our threat model; whether it's "the" decentralized-compute threat model is an editorial choice. Either change to "our threat model" or add a one-clause gloss ("adversarial operator with physical custody; honest consumer; untrusted network"). Light touch needed.

### m2. Two references to "Composed" that could be more active

"Composed, they produce an attested appliance" (§1) and "composed on top" (§9). Both readable; neither wrong. Stylistic preference.

### m3. "RSASSA-PSS chosen so that replayed signatures over the same plaintext produce distinct bytes" — phrasing could be tighter

"RSASSA-PSS produces distinct bytes on each signing of the same message, relevant if a consumer treats signature distinctness as an event-freshness signal." Minor.

### m4. "roughly an order of magnitude larger... one to two orders of magnitude lower"

These numbers appear in both the abstract and §8. Consistent now. Fine.

### m5. Figure 2 caption is extremely short ("A single merkle chain across both layers")

On the third look this is actually fine — the figure explains itself, and a longer caption would duplicate the surrounding text. Leave as-is.

### m6. The "S1: move 'runtime integrity is shared ground' to beginning of §2" from critique-3 was not applied

The current structure still has the paragraph at the end of §2, after the TCB table. That actually works — the reader sees the TCB comparison first, then the runtime-integrity acknowledgement second. The previous critique suggested reversing; on re-reading I prefer the current order. The TCB table is the rhetorical heart of §2, and putting it first lets it carry the section's weight.

### m7. "three layers" in §5.2 still slightly asymmetric

Layers (1) and (2) are both probabilistic BEAM/allocator defenses; (3) is the cryptographic TPM counter. The asymmetry is natural to the argument but the reader might feel (1) and (2) are "two flavors of one thing." Could be reframed as "two probabilistic defenses for bulk state plus one cryptographic primitive for load-bearing state." The current organization is fine; this would be a rhetoric tweak, not a substantive change.

### m8. "unikernel-style" is gone

Good.

### m9. Related work still has tight density

Apple PCC (one line), Naik (two sentences), Keylime/RATS/BuilderNet (three sentences). This is unavoidable given the 6-page budget; acceptable.

## What the paper does well

At this point it's worth noting what is working:

- The abstract makes a specific, verifiable claim ("this view is mistaken for the decentralized-compute threat model specifically, and wastefully so").
- §2 Positioning uses the TCB table to carry rhetorical weight.
- §3 Threat Model is tight and enumerates actors, capabilities, assumptions cleanly.
- §4 Architecture does the heavy technical work compactly.
- §5 AO-Core Continuity makes a novel claim (silicon-to-result merkle chain) that is well-supported.
- §6 Security Argument's attack table categorizes defense types honestly.
- §7 Availability uses a table with an explicit methodology note.
- Every controversial claim has been hedged or qualified appropriately.
- The paper is 6 pages and reads cleanly.

## Should we iterate further?

**Probably not.** The remaining issues are stylistic rather than substantive. A fifth pass would:
- Further polish sentence-level phrasing (m2, m3)
- Possibly add the "our threat model" clarification (m1)
- Marginally improve the three-layer framing (m7)

These are returns-to-polish territory. The paper is publishable as-is for internal review, and substantively close to publishable for external review (where minor editorial cleanup from a human editor would produce the final version).

## Overall assessment

From paper-0 (12 pages, overclaimed "TEE-like" throughout, self-reported binary hash argument, rhetorical overreach) to paper-4:

- Length cut by half (12pp → 6pp) with no loss of substance
- "This view is false" softened to "mistaken for this threat model specifically"
- Workload-measurement argument grounded in the HyperBEAM-as-unikernel packaging
- AO-Core continuity elevated to a standalone section with strong "silicon to signed result" framing
- Attack table reorganized by defense type (blocked at load / detected in attestation / at-rest / partial)
- Memory-encryption section honestly labels the integrity gap and applies three well-specified layers of mitigation
- ME/PSP explicitly brought into the hardware-vendor TCB
- "Arweave" committed to (with correct citation) rather than hedged behind "public immutable log"
- Ratio claims softened to match cited numbers
- Ephemeral-key binding via PCR extension is the cryptographic centerpiece and cleanly stated
- Runtime integrity assumption (A1) is load-bearing and explicitly shared with every deployed confidential-VM platform

The argument has survived adversarial critique from the gpt-5.4-xhigh reviewer and three rounds of self-critique. It is substantively right and rhetorically honest.
