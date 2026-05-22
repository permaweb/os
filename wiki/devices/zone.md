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
- Enforce `zone-allow` before any local zone identity is installed.
- Optionally bootstrap explicit zones from `zone-allow` during startup.

## Non-Responsibilities

- It does not verify TPM or SNP evidence directly.
- It does not trust stored peer attestations as admission inputs.
- It does not expose arbitrary signing with the zone key.

## `zone-allow`

`zone-allow` controls local zone installation:

- `0` or `false`: no new zone may be initialized or joined.
- `1` or unset: exactly one zone may be initialized or joined during this node
  run.
- positive integer: at most that many zones may be installed.
- `true`: no count limit.
- list of zone IDs: only those named zones may be installed.
- map of `ZONE_ID => PEER_URL`: only those named zones may be installed, and
  `start` schedules post-listener joins against the listed peers.
