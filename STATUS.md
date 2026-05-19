# LapEE Clean-Room Compression Status

Branch: `agent/lapee-cleanroom-compression`

Mission: rebuild the LapEE device layer from protocol specs, reduce production
device/runtime LoC by at least 60%, stretch beyond 70%, preserve the v1 product
flows, and move toward normal HyperBEAM rc/0.10 packageable devices.

## Baseline

- Starting commit: `34c08f1` (`main`, v1 cleanup merge).
- Tracked text baseline: `51,184` lines.
- Production overlay baseline, strict: `31,443` lines
  (`hyperbeam-overlay/src`, NIF source excluding lockfile, overlay fragment).
- Production overlay baseline, repo-counted: `32,123` lines
  (same, including native lockfile).
- 40% strict target: `18,866` lines.
- 50% strict target: `15,721` lines.
- 60% strict target: `12,577` lines.
- 70% strict stretch: `9,433` lines.

## Product Specs

The working spec wiki is under `wiki/`:

- `wiki/features.md`
- `wiki/protocols/measurement.md`
- `wiki/protocols/zone.md`
- `wiki/protocols/provisioning.md`
- `wiki/devices/system.md`
- `wiki/devices/tpm.md`
- `wiki/devices/snp.md`
- `wiki/devices/measurement.md`
- `wiki/devices/zone.md`
- `wiki/testing.md`
- `wiki/cut-ledger.md`

## Current Intent

Keep only the public product:

- signed appliance boot,
- policy-neutral system report,
- common measurement API,
- TPM and SNP measurement engines,
- named zones and membership proofs,
- Secure Boot and storage provisioner,
- encrypted zone storage after verified admission.

Remove historical/debug-only surfaces:

- public `~tpm-interpret@1.0`,
- TPM-specific peer verification flows superseded by `~measurement@1.0`,
- pre-v1 compatibility branches,
- trust scoring,
- broad catalogue interpretation not used by the product tests.

## Next Steps

1. Keep cutting from the device contracts, not from comments: measurement,
   zone, nonvolatile, then package layout.
2. Remove remaining public secret unwrap surfaces from HTTP paths by moving
   admission activation behind zone-internal calls.
3. Collapse duplicated measurement/zone canonicalization into one AO-Core
   boundary shape.
4. Package the devices for the HyperBEAM rc/0.10 device repository shape.
5. After each round: run tests, count LoC, update this file, commit, push.

## Validation Log

- Sub-agent review complete:
  - `Helmholtz`: found spec/package ambiguity and confirmed
    `~tpm-interpret@1.0` + catalogue removal as a valid product cut.
  - `Carson`: found the public unwrap-secret/decryption-oracle issue and
    tightened the measurement/zone specs around internal-only secret
    activation.
  - `Gauss`: confirmed the overlay reduction path and recommended compacting
    TCG/TPM before device packaging.
- First compression checkpoint:
  - Deleted public `~tpm-interpret@1.0`, its local-capture helper, and the
    historical firmware/OS/catalogue corpus. Kept EK root CAs and Intel ODCA
    fixtures needed by TPM verification.
  - Removed in-module test blocks from production overlay modules; acceptance
    coverage must now live in QEMU/integration harnesses or package tests.
  - Rewrote `dev_tpm_tcg` from broad firmware archaeology to the runtime
    contract LapEE actually needs: TCG event parsing for PCR replay,
    measured Secure Boot extraction, ACPI header helpers, and small
    compatibility stubs.
  - Removed the old TPM-specific `verify-peer` HTTP path. Peer verification is
    now owned by `~measurement@1.0`.
  - Simplified `hb_db_tpm` to load measured EK root CAs only.
- First checkpoint production-overlay count:
  - `12,056` lines across `hyperbeam-overlay/src`, native NIF sources, and
    `rebar.lapee.fragment`.
  - Reduction from strict baseline `31,443 -> 12,056`: `61.7%`.
- Static validation:
  - `make verify-config-invariants`: pass.
  - Direct Erlang syntax checks for `dev_tpm2`, `dev_tpm_tcg`, `dev_system`,
    and `hb_db_tpm`: pass.
  - `make hb-fetch`: pass, overlay stages into disposable HyperBEAM checkout.
  - `rebar3 as lapee compile` in the staged checkout: reaches native compile
    and fails on this macOS host because `tss2/tss2_esys.h` is unavailable.
    Erlang compilation reached the staged LapEE modules before that native
    host-header failure; full image validation still needs Buildroot/Docker.
- Second compression checkpoint:
  - Removed old direct TPM public attestation paths; `~measurement@1.0` is the
    only public boot/fresh measurement API.
  - Removed public TPM `credential-subject` / `wrap-secret`; TPM secret
    wrapping now lives behind the measurement/zone flow. The public
    `unwrap-secret` compatibility path still remains for the generic
    measurement implementation and is the next internalization target.
  - Dropped NIF operations that duplicated Erlang or no longer served v1:
    TPM MakeCredential, NV public-read diagnostics, context flush, TCTI
    mutation, and marshalled quote-signature echoing.
  - Removed duplicate TPM platform probes from `dev_tpm2`; `~system@1.0` owns
    policy-neutral system evidence.
  - Pruned `~system@1.0` broad inventory crawls for PCI, DRM, block, network,
    module, vulnerability, mount, and per-memory-block listings while keeping
    boot, kernel, CPU, memory, firmware, TPM, IOMMU, ACPI, EDAC, Boot Guard,
    and controller-backed hardware evidence.
  - Removed unused `~zone@1.0/match`; zone matching remains internal to init
    and admission.
- Current production-overlay count:
  - Strict line count: `10,783`.
  - Non-comment/non-blank code count: `9,410`.
  - Strict reduction from baseline: `31,443 -> 10,783`, `65.7%`.
  - Code-line reduction from strict baseline: `31,443 -> 9,410`, `70.1%`.
- Validation after second checkpoint edits:
  - Direct Erlang syntax check for all overlay modules: pass.
  - `make verify-config-invariants`: pass.
  - `make hb-fetch`: pass; overlay stages into disposable HyperBEAM checkout.
  - `make runtime-image TME=0`: pass. Built signed image
    `build/images/lapee-runtime-no-tme-signed.img` (`215M`).
  - `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
    HyperBEAM `/~meta@1.0/info`, `/~measurement@1.0/boot`, and
    `/~system@1.0/all` answered under QEMU+swtpm.
  - QEMU artefacts:
    `build/qemu-network-test/boot-attestation.json` (`156K`) and
    `build/qemu-network-test/system.json` (`60K`).
- Third cleanup checkpoint in progress:
  - Removed the obsolete standalone Python TPM verifier. Runtime and QEMU
    checks now use `~measurement@1.0/verify`, keeping one measured verifier
    implementation rather than a parallel off-node policy engine.
  - Updated the operator-config QEMU flow to prove quote, PCR15 replay, and
    PCR15 node-message binding through the node's measurement verifier.
  - `make qemu-operator-config IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. Two QEMU nodes booted; one with a trusted signer could initialize the
    signer-required zone and the empty-signer node was rejected.
  - Tracked text count after this cut: `26,603` lines outside `.git` and
    `build/`.

## Reviewer Notes For Next Pass

- `dev_zone` still carries a custom admission authorization envelope. Replace
  with a zone-signed AO-Core admission message if acceptance tests stay green.
- `dev_measurement` and `dev_zone` duplicate payload normalization and stable
  ID code. Collapse toward one AO-Core boundary shape.
- Public `unwrap-secret` remains as a compatibility surface in the checkpoint.
  The specs now mark secret activation as internal-only; remove or hide this in
  the next round by moving activation behind zone-owned calls.
- Strict-line stretch remaining for 70%: target `9,433`, delta `1,350`.
