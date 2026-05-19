# `~zone@1.0` Device Specification

`~zone@1.0` is the only public shared-identity admission device.

## Responsibilities

- Initialize a zone only if the local boot measurement matches the template.
- Admit a peer only after `~measurement@1.0/verify-peer` succeeds and the peer
  boot measurement matches the template.
- Generate zone wallet and AES material internally.
- Sign admission authorizations over recomputed stable payload IDs.
- Install admitted zone identities through normal HyperBEAM identity options.
- Return membership proofs signed by the zone identity.
- Activate matching nonvolatile storage after successful join.

## Non-Responsibilities

- It does not verify TPM or SNP evidence directly.
- It does not trust stored peer attestations as admission inputs.
- It does not expose arbitrary signing with the zone key.
