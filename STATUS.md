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

1. Rebuild and run the QEMU acceptance matrix for the current reduced surface.
2. Collapse duplicated measurement/zone canonicalization only if the AO-Core
   admission shape can stay identical under QEMU/remote SNP tests.
3. Package the devices for the HyperBEAM rc/0.10 device repository shape.
4. After each round: run tests, count LoC, update this file, commit, push.

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
- Splash cleanup checkpoint:
  - Removed the experimental alternate splash layouts. Production now has the
    release blue proof splash and the Secure Boot provisioner warning/report
    splash only.
  - Runtime init only accepts `blue` and `provision` for `LAPEE_SPLASH_LAYOUT`;
    unknown values fall back to the compiled default.
  - `lapee_splash.erl` shrank from `1,758` lines in v1 to `1,223` lines.
  - Validation:
    - `erlc -o /tmp buildroot-external/board/lapee/files/lapee_splash.erl`:
      pass.
    - `sh -n buildroot-external/board/lapee/rootfs-overlay/init`: pass.
    - `bash -n scripts/render-splash-previews.sh`: pass.
    - Rendered blue/provision previews at `160x50` and `128x48` for boot,
      hb-wait, and ready states under
      `build/splash-previews/compression-check/`.
  - Tracked text count after this cut: `26,078` lines outside `.git` and
    `build/`.
- TPM/system/measurement cleanup checkpoint in progress:
  - Removed raw public TPM `extend`, `quote`, `pcr-read`, and direct
    `activate-credential` surfaces; TPM remains available only as a
    measurement engine plus `info`/`supported` diagnostics.
  - Removed unused TPM NIF `pcr_read`, unused NIF handle echoes, and the dead
    AK parent-handle argument.
  - Removed the userspace Intel Meteor Lake `resource0` DRAM fallback. LPDDR
    evidence now comes from the read-only kernel DRM DRAM export plus EDAC
    evidence rather than userspace MMIO.
  - Removed unused TCG helper exports/stubs for SMBIOS, device paths, systemd
    PE sections, and cmdline parsing; the appliance uses only Secure Boot
    signal extraction and ACPI table headers.
  - Removed the public measurement `wrap-secret` endpoint. The public
    `unwrap-secret` endpoint remains intentionally narrow: it returns a signed
    challenge activation proof for peer liveness and never returns plaintext
    secrets.
  - Current strict production-overlay count: `10,177`.
  - Current non-comment/non-blank overlay code count: `8,939`.
  - Strict reduction from baseline: `31,443 -> 10,177`, `67.6%`.
  - Code-line reduction from strict baseline: `31,443 -> 8,939`, `71.6%`.
  - Direct Erlang syntax check for all overlay modules: pass.
  - `make verify-config-invariants`: pass.
  - `make hb-fetch`: pass; staged the reduced overlay into the disposable
    HyperBEAM checkout.
  - `make runtime-image TME=0`: pass. Built signed image
    `build/images/lapee-runtime-no-tme-signed.img` (`232M`).
  - `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
    HyperBEAM answered `/~meta@1.0/info`, `/~measurement@1.0/boot`, and
    `/~system@1.0/all` under QEMU+swtpm.
  - `make qemu-operator-config IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. Operator config was included in the boot measurement, PCR15 replay
    verified through `~measurement@1.0/verify`, and only the configured node
    could initialize the signer-required zone.
  - `make qemu-zone IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
    Four TPM-backed nodes formed a zone; the inadmissible node was rejected
    and could not produce a membership proof.
  - `make qemu-zone-nonvolatile IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. The admitted node reopened the same encrypted non-volatile volume
    after reboot, recovered the pre-reboot object, and produced current
    membership evidence.
- Fourth cleanup checkpoint in validation:
  - Removed the public measurement `subject` route. Peer verification now
    derives the recipient subject from the peer's signed boot measurement,
    eliminating an extra peer HTTP fetch and an extra public surface.
  - Removed the test-only `dev_snp_mock` engine. Local QEMU exercises TPM
    zones; the real SNP path is covered by the remote SNP harness.
  - Removed old TPM verifier compatibility normalization. TPM verification now
    accepts the normalized `~measurement@1.0` envelope shape.
  - Removed duplicate prose/report mirrors from `~system@1.0`, narrow TCG
    parsing to Secure Boot extraction plus ACPI headers, and shortened TPM EK
    chain diagnostics without changing EK/AK, quote, PCR15, or credential
    activation checks.
  - Current strict production-overlay count: `9,430`.
  - Current non-comment/non-blank overlay code count: `8,274`.
  - Strict reduction from baseline: `31,443 -> 9,430`, `70.0%`.
  - Code-line reduction from strict baseline: `31,443 -> 8,274`, `73.7%`.
  - Direct Erlang syntax check for all overlay modules: pass.
  - `make verify-config-invariants`: pass.
  - `make hb-fetch`: pass; staged overlay and removed stale `dev_snp_mock`
    from the disposable HyperBEAM checkout.
  - `make runtime-image TME=0`: pass. Built signed image
    `build/images/lapee-runtime-no-tme-signed.img` (`232M`).
  - `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
    HyperBEAM answered `/~meta@1.0/info`, `/~measurement@1.0/boot`, and
    `/~system@1.0/all`.
  - `make qemu-operator-config IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. Config appears in the node message, PCR15 replay verifies through
    `~measurement@1.0/verify`, and only the configured node can initialize the
    signer-required zone.
  - `make qemu-zone IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
    Four TPM-backed nodes used `measurement-device=auto`; three admitted
    nodes joined and produced ring-signed membership proofs, while the
    inadmissible node was rejected.
  - `make qemu-zone-nonvolatile IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. The rebooted node matched a partial zone-label prefix, could not
    read the stored object before rejoining, then reopened the encrypted
    volume after admission and recovered the pre-reboot object plus current
    boot-attestation path.
  - Next validation: remote real-SNP zone on `hb@dev-1.forward.computer`.
  - `make qemu-zone-remote-snp IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
    pass. Four real SNP-backed QEMU nodes booted on
    `hb@dev-1.forward.computer`; all exposed `measurement-device =
    "snp@1.0"` and common safe-boot properties, three admissible nodes joined
    the zone and produced ring-signed membership proofs, while the DMI-mismatched
    node was rejected and could not produce a membership proof. Remote timing:
    image prep/copy `32s`, SNP boot readiness `43s`, admission flow `26s`,
    total `104s`. Ring address:
    `xGzEfEK2X8Ej3936jTqkV-pJSHZAe3sAFAcVbsxtWSE`.

## Reviewer Notes For Next Pass

- `dev_measurement` and `dev_zone` duplicate payload normalization and stable
  ID code. Collapse toward one AO-Core boundary shape.
- Public `unwrap-secret` is still named like a decryption endpoint even though
  it returns only activation proof. Consider renaming the protocol once the
  zone and peer scripts can migrate atomically.
- The next major cleanup is packaging, not more in-place shrinking: turn the
  overlay devices into normal HyperBEAM packageable/preloadable devices and
  shrink the static preloaded-device config.

## Production Validation Pass

Checkpoint: `7c1c28e` (`Normalize measurement and zone protocol`).

Purpose: prove the current signed no-TME runtime image is production-ready
before a final real-hardware loop, while continuing to simplify rather than
paper over AO-Core/codec issues.

Rules for this pass:

- Bind protocol facts to AO-Core message IDs, not JSON renderings.
- Treat JSON as an operator/test-harness representation only.
- For any source patch that adds or changes lines, remove at least twice as
  many real lines without dropping product features or useful comments.
- Prefer HyperBEAM primitives over local protocol helpers when the semantics
  match.

Validation matrix to complete:

1. Re-run local TPM QEMU zone formation against the current signed image.
2. Re-run remote real-SNP single-node measurement verification.
3. Run remote real-SNP zone formation with at least one accept/reject
   configuration split.
4. Inspect boot measurements in depth: node message, UKI hash, command line,
   Secure Boot/TCG, TPM/SNP evidence, memory, EDAC, DRM DRAM, ACPI, IOMMU,
   and TME command-line state.
5. Audit memory/TME/LPDDR collection paths statically and against generated
   boot-attestation artefacts.
6. Leave the repo in a committed state with all generated crash/build junk
   removed from git.

Completed validation:

- Rebuilt signed no-TME runtime image after the `~system@1.0` memory-shape
  simplification:
  - `build/images/lapee-runtime-no-tme-signed.img`
  - SHA-256:
    `f223fdcc2d5f3ab816c922f0d638183b62bd980342ddbf9ab4a99371f571e766`
  - Boot-attested UKI SHA-256:
    `JU54qbhUs0iAIVbYt0F0XJ6qHuI4sP8XAlJPkeDZlBs`
- `IMG=build/images/lapee-runtime-no-tme-signed.img make qemu-zone`:
  pass. Four TPM-backed nodes booted the same prod no-TME image; three
  template-matching nodes joined and produced ring-signed membership proofs;
  the DMI-mismatched node was rejected and could not produce one.
- `IMG=build/images/lapee-runtime-no-tme-signed.img make qemu-zone-nonvolatile`:
  pass. The admitted node wrote a pre-reboot sentinel, rebooted with changed
  boot evidence, matched a partial zone-label prefix, could not read the
  object before rejoining, then reopened the encrypted volume and recovered
  both the old object and the current boot-attestation path after admission.
- `IMG=build/images/lapee-runtime-no-tme-signed.img make qemu-operator-config`:
  pass. USB `config.json` appeared in the node message, PCR15 replay verified
  through `~measurement@1.0/verify`, and only the configured node could
  initialize the signer-required zone.
- `OUTDIR=build/qemu-single-validation HOST_PORT=18737
  ./scripts/boot-usb-image.sh --img build/images/lapee-runtime-no-tme-signed.img
  --oracle-url https://example.com/`: pass. A single QEMU+swtpm appliance
  served `~measurement@1.0/boot`, `~system@1.0/all`, and a relay/oracle
  response signed by the node key.
- `TARGET=ssh://hb@dev-1.forward.computer
  IMAGE=build/images/lapee-runtime-no-tme-signed.img
  ./scripts/qemu-measurement-remote.sh`: pass. Real SEV-SNP guest selected
  `snp@1.0`, returned boot and fresh measurements, and self `verify-peer`
  verified boot, fresh evidence, and credential activation.
- `IMAGE=build/images/lapee-runtime-no-tme-signed.img
  ./scripts/qemu-zone-remote-snp.sh`: pass after the harness cleanup. Four
  real SNP-backed guests booted on `hb@dev-1.forward.computer`; all exposed
  `measurement-device = "snp@1.0"`, evidence type `lapee-snp-evidence`, the
  same prod no-TME command line, the same UKI hash, and distinct X25519
  recipient keys. Three DMI-matching nodes joined the zone and produced
  membership proofs; the DMI-mismatched node was rejected. Timing: prepare
  `8s`, install helper `4s`, copy image `46s`, start SNP nodes `3s`, boot
  readiness `45s`, admission flow `39s`, total `145s`.
- Remote cleanup verified:
  `/home/hb/lapee-measurement-tests/zone-snp/run-snp-cluster.sh status`
  reports `node1` through `node4` stopped.
- Static checks:
  - `make verify-config-invariants`: pass.
  - Direct overlay Erlang syntax check with staged HyperBEAM include paths:
    pass.
  - `git diff --check`: pass.
- Boot-attestation evidence audit:
  - `body` contains only AO-Core `system` and signed `node` subjects.
  - Node config is `initialized = permanent`, `load-remote-devices = false`,
    and `access-remote-cache-for-client = false`.
  - Kernel command line includes `LAPEE_NO_TME=1`; this is the expected
    measured no-TME runtime policy for the test image.
  - Memory evidence now has one canonical shape: `meminfo`, `edac`, and
    `controller-probes`; the duplicate `topology` alias was removed.
  - EDAC reports `available = false` in QEMU/SNP guests, as expected.
  - Intel DRM DRAM evidence remains exposed through `controller-probes` when
    hardware provides the read-only i915/xe sysfs attributes.
  - ACPI and Boot Guard reports remain linked AO-Core submessages from
    `firmware.acpi` and `firmware.boot-guard`.
  - TPM boot measurements include PCRs `[0,1,7,10,11,14,15]`, runtime event
    log entries for the boot subject and TCG tip commitment, and encrypted
    HMAC TPM session mode `hmac-aes128cfb`.
  - SNP boot/fresh measurements include `lapee-snp-evidence`, SNP report-data,
    and a boot-local X25519 recipient bound to the measurement.
- Source cleanup accounting for this pass: current source diff is `25`
  inserted lines and `55` removed lines, before this status-only log.
