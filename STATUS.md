# LapEE v1 Release Status

Branch: `agent/v1-cleanup`

This branch is the v1 cleanup pass. It standardizes the admission device as
`~zone@1.0`, removes generated/stale documentation artifacts, and keeps the
release surface focused on signed runtime images, the Secure Boot provisioner,
operator config injection, and QEMU/remote validation.

## Current System

- `~measurement@1.0` is the primary hardware-measurement API.
- `~tpm@2.0a` and `~snp@1.0` are measurement-capable backends.
- `~zone@1.0` creates named shared identities from verified measurements.
- Production runtime images are signed UKIs and may be built with `TME=1`
  or the measured no-TME flag `TME=0`.
- Optional non-volatile storage is provisioned by the Secure Boot
  provisioner and opened only after a node joins the matching zone.

## Verified In This Pass

- Static checks:
  - `git grep` found no tracked old admission-device names.
  - `git grep` found no tracked deferred-work markers.
  - `make verify-config-invariants` passed.
  - `bash -n` passed for the release QEMU/provisioner scripts.
  - `python3 -m py_compile` passed for the QEMU request generator and
    config invariant checker.
  - `git diff --check` passed.
- Staged HyperBEAM overlay eunit:
  - `dev_zone`: 28 tests passed.
  - `dev_measurement`: 12 tests passed.
  - `dev_tpm2`: 43 tests passed.
  - `lapee_nonvolatile`: 5 tests passed.
  - `dev_snp`: 9 tests passed.
  - `dev_snp_mock`: loaded; no tests to run.
- Built images:
  - `build/images/lapee-runtime-no-tme-signed.img`
    SHA-256 `11f36a5aeb036917710f2b78c76e5f09cb2e71adf46134e689fd235ae9085f7d`.
  - `build/images/lapee-sb-provisioner.img`
    SHA-256 `66d717e3cbc28bec79103fde9e7ad702e251022fa1004548e9ab149333a39090`.
  - Both UKIs were signed and verified by `sbverify` during image build.
- Local QEMU:
  - Signed no-TME runtime boot plus signed HTTPS relay oracle passed.
  - Operator config measurement/PCR15 replay passed.
  - Four-node TPM/swtpm zone admission passed:
    three admitted nodes, one rejected node, and three ring-signed
    membership proofs.
  - Four-node TPM/swtpm zone plus non-volatile store reuse passed:
    partial `ZONE_` label matching, reboot, rejoin, old object recovery,
    and current boot-measurement refresh.
  - Signed provisioner non-volatile disk preparation passed and created
    `ZONE_test-zone`.
- Remote SNP:
  - Four real SEV-SNP QEMU nodes on `hb@dev-1.forward.computer` passed.
  - All nodes measured as `snp@1.0` with `lapee-snp-evidence`.
  - Three matching nodes joined the zone and produced ring-signed
    membership proofs; the mismatched DMI node was rejected.
  - Total remote SNP run time: 148 seconds.

## Not Revalidated

- `make -C paper quick` could not run because `pdflatex` is not installed
  on this host. Generated PDFs are removed from git; the paper source is
  now the maintained artefact.

## Open Questions For Review

None yet.
