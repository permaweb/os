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

1. Re-run acceptance harnesses after the first compression checkpoint.
2. Continue clean-room rewrites in order: measurement, zone, nonvolatile,
   TPM/SNP edge APIs, then package layout.
3. Remove remaining public secret unwrap surfaces from HTTP paths by moving
   admission activation behind zone-internal calls.
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
- Current production-overlay count:
  - `12,056` lines across `hyperbeam-overlay/src`, native NIF sources, and
    `rebar.lapee.fragment`.
  - Reduction from strict baseline `31,443 -> 12,056`: `61.7%`.
  - Stretch remaining for 70%: target `9,433`, delta `2,623`.
- Static validation:
  - `make verify-config-invariants`: pass.
  - Direct Erlang syntax checks for `dev_tpm2`, `dev_tpm_tcg`, `dev_system`,
    and `hb_db_tpm`: pass.
  - `make hb-fetch`: pass, overlay stages into disposable HyperBEAM checkout.
  - `rebar3 as lapee compile` in the staged checkout: reaches native compile
    and fails on this macOS host because `tss2/tss2_esys.h` is unavailable.
    Erlang compilation reached the staged LapEE modules before that native
    host-header failure; full image validation still needs Buildroot/Docker.
+- QEMU runtime validation:
+  - `make runtime-image TME=0`: pass. Built signed image
+    `build/images/lapee-runtime-no-tme-signed.img`.
+  - `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass.
+    HyperBEAM `/~meta@1.0/info`, `/~measurement@1.0/boot`, and
+    `/~system@1.0/all` answered under QEMU+swtpm.
+
## Reviewer Notes For Next Pass
+
- `dev_zone` still carries a custom admission authorization envelope. Replace
+  with a zone-signed AO-Core admission message if acceptance tests stay green.
+- `dev_measurement` and `dev_zone` duplicate payload normalization and stable
+  ID code. Collapse toward one AO-Core boundary shape.
+- Public `wrap-secret` / `unwrap-secret` endpoints remain as compatibility
+  surfaces in the checkpoint. The specs now mark secret activation as
+  internal-only; remove or hide these in the next round by moving activation
+  behind zone-owned calls.
+- Stretch target needs another `2,623` production-overlay lines removed.
