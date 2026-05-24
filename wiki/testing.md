# Acceptance Test Contract

Acceptance tests prove that PermawebOS still behaves as a distribution across
architectures: local QEMU, remote SNP QEMU, Android/AndEE, measurement, zones,
and encrypted storage must keep using the same AO-Core protocol surfaces.

## Static and Unit

- Device package, verify, and test through HyperBEAM rc/0.10 Forge.
- Config invariant check: permanent node message, no remote device loading by
  default where the release profile requires it, measurement boot hook present.
- Erlang unit tests for each device contract and helper library.
- Native TPM/SNP compile checks.

## Local QEMU

- Single signed runtime boots and returns `~measurement@1.0/boot`.
- Signed relay oracle response works.
- Operator config appears in the node message and boot measurement.
- Four TPM/swtpm nodes: three admitted to a zone, one rejected.
- TPM/swtpm nonvolatile flow: provision, join, write, reboot, rejoin, read.
- Provisioner storage test: destructive prompt, target selection, `ZONE_`
  label creation.

## Screenshots

Capture and inspect:

- blue runtime splash while booting,
- runtime ready QR screen,
- red provisioner warning,
- confirmation input failure and retry,
- post-provisioning report,
- encrypted storage prompt and result.

## Remote SNP

On `hb@dev-1.forward.computer`, under a dedicated workdir:

- Boot four real SNP QEMU nodes.
- Admit three matching nodes to a zone.
- Reject one mismatched node.
- Confirm membership proofs.
- Run a mixed TPM/SNP policy and an SNP-only rejection policy.

## Android / AndEE

- Build the Android runtime/APK.
- Run emulator smoke checks for `~measurement@1.0/boot`, `fresh`, and
  `verify`.
- Join a zone with Linux QEMU and remote SNP peers using the same
  `~zone@1.0` protocol.
- On a real Android device when available, verify that AndEE can join a Linux
  or SNP-founded zone and that the other nodes can verify the AndEE
  measurement.
