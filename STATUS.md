# LapEE Measurement/SNP Status

## Current Focus

Branch: `feat/measurement-snp`.

Normalize TPM and SEV-SNP style node evidence under `~measurement@1.0`, then
route green-zone admission through that common measurement protocol.

## Latest Checkpoint

The measurement reorg is live-validated on the signed production-shaped
no-TME runtime image. Local TPM/QEMU, remote real SEV-SNP/QEMU, and mixed
real Framework TPM + remote SEV-SNP + Yoga TPM green-zone flows all pass
through `~measurement@1.0`.

Current validated artefact:

- image: `build/images/lapee-runtime-no-tme-signed.img`
- image SHA-256:
  `6c0fb241fdd1848549f214fa08b3659afd5a6a0ead22e8d95fb8ee2de98842e5`
- signed UKI SHA-256 / release template value:
  `p29uO0tz_uX9tUOM2BEqcu1naOMEjmApy8Kqa2QntSo`
- cmdline:
  `console=tty0 quiet loglevel=0 vt.global_cursor_default=0 rdinit=/init lapee.mode=prod lapee.wifi=enabled lapee.splash=blue LAPEE_NO_TME=1`

## Implemented

- Added `~measurement@1.0` as the primary LapEE measurement API:
  `info`, `boot`, `fresh`, `verify`, `verify-peer`, `subject`,
  `wrap-secret`, and `unwrap-secret`.
- Standardized measurement messages as signed AO-Core messages with:
  `type`, `version`, `issued-at-unix`, `measurement-device`, `body`,
  `evidence`, and `secret-recipient`.
- Moved the common subject construction into measurement:
  `body.system` comes from `~system@1.0/all`; `body.node` comes from signed
  `~meta@1.0/info`.
- Refactored `~tpm@2.0a` into a measurement-capable backend while preserving
  TPM-specific public endpoints for debugging and compatibility.
- Mapped TPM `MakeCredential` / `ActivateCredential` onto generic
  `wrap-secret` / `unwrap-secret`.
- Added `~snp@1.0` as a measurement-capable backend with boot-local X25519
  recipient keys, report-data binding, Erlang-side report parsing, and
  X25519/HKDF/AES-GCM secret wrapping.
- Added explicit test-only `~snp-mock@1.0` protocol backend. It is never part
  of production `measurement-device = auto` selection.
- Updated `~green-zone@1.0` to verify peers and wrap ring secrets through
  `~measurement@1.0` instead of calling TPM functions directly.
- Updated QEMU green-zone harnesses so `MEASUREMENT_DEVICE=snp-mock@1.0` can
  exercise green-zone without TPM-specific credential paths.
- Updated the green-zone cluster harness to support per-node measurement
  devices and common templates that do not pin the backend. This lets one
  acceptance run exercise TPM-backed nodes and SNP-style nodes in the same
  ring.
- Added kernel/build support needed for SEV-SNP guest probing.
- Replaced green-zone peer transport calls with HB HTTP plus AO-Core JSON
  bundle negotiation, avoiding the older custom JSON helper path.
- Fixed admission response handling so a status-200 response with a linked
  body is normalized through the same policy/error path as direct bodies.
- Rebuilt the SNP backend around a tiny overlay-owned Rust NIF:
  `supported/0` checks `/dev/sev-guest`; `report/2` returns raw SNP report
  bytes. The NIF no longer performs JSON construction or report verification.
- Switched live SNP report collection to the basic `SNP_GET_REPORT` path. The
  extended report/certificate-table ioctl wedged the guest on the current
  remote SNP stack, while the basic report path returns promptly.
- Moved SNP report parsing, report-data checks, AMD KDS/certificate handling,
  and ECDSA signature verification into `dev_snp.erl`.
- Added a process-local AMD KDS fetch cache so a verifier does not request the
  same immutable ARK/ASK/VCEK material repeatedly during one peer verification
  flow.
- Added AMD ARK pinning for Milan, Genoa, and Turin.
- Changed SNP VMPL default to `0`, matching the remote host's
  `sev-guest` initialization (`VMPCK0`).
- Made `lapee_tpm_nif` load failure nonfatal. SNP guests and verifier-only
  nodes can now load modules that reference TPM code without a local TPM; TPM
  operations still fail closed through the Erlang stubs if called.
- Added bounded measurement steps around system report, node message, backend
  subject, and backend evidence collection. A stuck probe should now fail the
  measurement instead of wedging the caller forever.
- Added `scripts/qemu-measurement-remote.sh` and `make
  qemu-measurement-remote` for single-node remote measurement smoke tests on
  `TARGET=ssh://...`.
- Added `scripts/qemu-green-zone-remote-snp.sh` and `make
  qemu-green-zone-remote-snp` for four-node real SEV-SNP green-zone
  acceptance on a remote SNP host.
- Fixed SNP secret activation credential canonicalization so peer HTTP
  negotiation fields do not change the credential ID used in the X25519
  unwrap proof.

## Verified

- Staged the overlay into `build/hyperbeam/src-edge`.
- Unit tests:
  - `HB_PORT=0 rebar3 eunit --module=dev_measurement`
    - 2 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_tpm2`
    - 42 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_green_zone`
    - 23 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_snp`
    - 6 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_snp_mock`
    - compiles; no tests defined.
- Re-ran the core staged overlay tests after the raw SNP NIF changes:
  - `HB_PORT=0 rebar3 eunit --module=dev_measurement`
    - 2 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_snp`
    - 6 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_green_zone`
    - 23 tests passed.
  - `HB_PORT=0 rebar3 eunit --module=dev_tpm2`
    - 42 tests passed.
- The raw `dev_snp_nif` crate compiles when staged into
  `build/hyperbeam/src-edge`.
- A real AMD SNP sample report from AMD KDS material validates through the
  Erlang-side certificate/signature path after the EC public-key fix.
- Built signed debug no-TME image:
  - `build/images/lapee-measurement-debug-greenjoin-signed.img`
  - `sbverify` reported `Signature verification OK`.
- Built signed serial debug no-TME SNP images for the remote host:
  - `build/images/lapee-measurement-snp-debug-serial-signed.img`
  - `build/images/lapee-measurement-snp-debug-serial-quiet-signed.img`
  - `sbverify` reported `Signature verification OK`.
- QEMU nonvolatile TPM green-zone cluster passed before the final admission
  response normalization patch:
  - four nodes booted and answered `~measurement@1.0/boot`;
  - node 4 was rejected by template mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - node 2 reused encrypted nonvolatile storage after reboot;
  - node 2's current boot measurement stayed current after store activation.
- Plain TPM four-node QEMU green-zone cluster passed after the final admission
  response normalization patch:
  - command:
    `IMG=build/images/lapee-measurement-debug-greenjoin-signed.img OUTDIR=build/qemu-measurement-plain TIMEOUT=1200 ./scripts/qemu-green-zone-cluster.sh`
  - all four nodes answered `~measurement@1.0/boot`;
  - node 1 initialized the green zone;
  - node 1 produced a valid `~measurement@1.0/verify-peer` for node 2;
  - nodes 2 and 3 joined;
  - node 4 was rejected by template mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - output ended with `=== green-zone QEMU cluster PASSED ===`.
- SNP-mock four-node QEMU green-zone cluster passed:
  - command:
    `IMG=build/images/lapee-measurement-debug-greenjoin-signed.img OUTDIR=build/qemu-measurement-snp-mock TIMEOUT=900 MEASUREMENT_DEVICE=snp-mock@1.0 ./scripts/qemu-green-zone-cluster.sh`
  - all four nodes answered `~measurement@1.0/boot`;
  - all four boot measurements reported `measurement-device = "snp-mock@1.0"`;
  - nodes 2 and 3 joined;
  - node 4 was rejected by template mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - output ended with `=== green-zone QEMU cluster PASSED ===`.
- Mixed TPM/SNP-mock four-node QEMU green-zone cluster passed:
  - command:
    `IMG=build/images/lapee-measurement-snp-debug-serial-quiet-signed.img OUTDIR=build/qemu-green-zone-mixed-mock TIMEOUT=1200 GREEN_ZONE_TEMPLATE_MODE=common NODE1_MEASUREMENT_DEVICE=auto NODE2_MEASUREMENT_DEVICE=snp-mock@1.0 NODE3_MEASUREMENT_DEVICE=snp-mock@1.0 NODE4_MEASUREMENT_DEVICE=snp-mock@1.0 ./scripts/qemu-green-zone-cluster.sh`
  - node 1 reported `measurement-device = "tpm@2.0a"`;
  - nodes 2-4 reported `measurement-device = "snp-mock@1.0"`;
  - node 1 initialized a common-template green-zone;
  - node 1 admitted node 2 across TPM-to-SNP-style secret wrapping;
  - node 2 admitted node 3;
  - node 4 was rejected by DMI product mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - output ended with `=== green-zone QEMU cluster PASSED ===`.
- Production-shaped signed no-TME image booted under local QEMU+swtpm:
  - image: `build/images/lapee-measurement-prod-no-tme-signed.img`;
  - command:
    `OUTDIR=build/qemu-prod-measurement-smoke TIMEOUT=600 ./scripts/boot-usb-image.sh --img build/images/lapee-measurement-prod-no-tme-signed.img --timeout 600`;
  - `sbverify` reported `Signature verification OK` during image build;
  - `~measurement@1.0/info`, `~measurement@1.0/boot`, and
    `~system@1.0/all` answered;
  - output ended with `=== QEMU boot test PASSED ===`.
- Remote real SEV-SNP green-zone cluster passed on
  `ssh://hb@dev-1.forward.computer`:
  - image:
    `build/images/lapee-measurement-snp-debug-serial-quiet-signed.img`;
  - command:
    `TARGET=ssh://hb@dev-1.forward.computer IMAGE=build/images/lapee-measurement-snp-debug-serial-quiet-signed.img OUTDIR=build/qemu-green-zone-remote-snp TIMEOUT=1200 ./scripts/qemu-green-zone-remote-snp.sh`;
  - all four nodes booted as real SNP guests and reported
    `measurement-device = "snp@1.0"` with `lapee-snp-evidence`;
  - nodes 1-3 matched the green-zone template and joined;
  - node 4 was rejected by DMI product mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - output ended with `=== remote SNP green-zone QEMU cluster PASSED ===`;
  - measured timings:
    prepare image 11s, install helper 2s, copy image 80s, start QEMU 3s,
    wait boot 29s, fetch subjects 3s, admission flow 36s, total 164s.
- Remote SEV-SNP host reconnaissance:
  - Host: `ssh://hb@dev-1.forward.computer`.
  - CPU: AMD EPYC 9254, family 25 model 17, inferred KDS product `Genoa`.
  - SNP host support is enabled; the guest kernel reports:
    `sev-guest ... using VMPCK0 communication key`.
  - The SNP guest now gets past the previous fatal TPM NIF load failure.
- Remote SEV-SNP smoke passed on `ssh://hb@dev-1.forward.computer`:
  - image:
    `build/images/lapee-measurement-snp-debug-serial-quiet-signed.img`;
  - command:
    `TARGET=ssh://hb@dev-1.forward.computer IMAGE=build/images/lapee-measurement-snp-debug-serial-quiet-signed.img MEASUREMENT_DEVICE=snp@1.0 MEASUREMENT_TRACE=1 MEASUREMENT_TIMEOUT_MS=10000 OUTDIR=build/qemu-measurement-remote-snp-full TIMEOUT=300 ./scripts/qemu-measurement-remote.sh`;
  - `~measurement@1.0/info` selected `snp@1.0`;
  - `~measurement@1.0/boot` returned a signed `lapee-measurement` with
    `measurement-device = "snp@1.0"`;
  - `~measurement@1.0/fresh` returned a nonce-bound signed SNP measurement;
  - `~measurement@1.0/verify` accepted both boot and fresh measurements;
  - output ended with `=== remote measurement smoke PASSED ===`.
- Local production-shaped TPM QEMU green-zone cluster passed on the current
  signed no-TME image:
  - command:
    `IMG=build/images/lapee-runtime-no-tme-signed.img OUTDIR=build/qemu-green-zone-measurement-fix2-local BASE_PORT=19380 TIMEOUT=900 KEEP_RUNNING=0 ./scripts/qemu-green-zone-cluster.sh`;
  - all four nodes reported UKI hash
    `p29uO0tz_uX9tUOM2BEqcu1naOMEjmApy8Kqa2QntSo`;
  - nodes 1-3 joined and produced ring-signed membership proofs;
  - node 4 was rejected by template mismatch;
  - output ended with `=== green-zone QEMU cluster PASSED ===`.
- Remote real SEV-SNP production-shaped green-zone cluster passed on the
  current signed no-TME image:
  - command:
    `TARGET=ssh://hb@dev-1.forward.computer IMAGE=build/images/lapee-runtime-no-tme-signed.img OUTDIR=build/qemu-green-zone-remote-snp-measurement-fix2 REMOTE_WORKDIR=/home/hb/lapee-green-zone-remote-snp-measurement-fix2 BASE_PORT=20040 TIMEOUT=1200 KEEP_RUNNING=0 MEASUREMENT_TIMEOUT_MS=30000 ./scripts/qemu-green-zone-remote-snp.sh`;
  - all four guests reported `measurement-device = "snp@1.0"` and the same
    UKI hash above;
  - nodes 1-3 joined and produced ring-signed membership proofs;
  - node 4 was rejected by template mismatch;
  - output ended with `=== remote SNP green-zone QEMU cluster PASSED ===`;
  - total remote run time was 172s.
- Mixed real-device green-zone passed:
  - remote SEV-SNP node initialized `book-shelf`;
  - Framework `.207` joined the SNP node;
  - Yoga `.210` joined through Framework `.207`;
  - all three used the same release template constraints: signed UKI hash
    `p29uO0tz_uX9tUOM2BEqcu1naOMEjmApy8Kqa2QntSo`, permanent node message,
    `load-remote-devices = false`, and
    `access-remote-cache-for-client = false`;
  - Framework and Yoga both loaded `green-zone/book-shelf` and produced
    ring-signed membership proofs;
  - local `status.members` is not a convergent global roster. It includes
    only members known through that node's admission history, plus AO-Core
    commitment metadata in the raw message map.

## Not Yet Verified

- TME-enabled runtime image after the measurement reorg.
- Nonvolatile green-zone rejoin on the current production-shaped measurement
  image after a real Framework power cycle.

## Known Gaps

- The live SNP path currently depends on AMD KDS when platform certificates
  are not embedded in the evidence. Verification is cryptographic and pinned
  to known AMD ARKs, but fully offline SNP replay is not yet available for
  live reports from this host.
- `qemu-measurement-remote` currently implements the SSH/SNP path only; the
  `TARGET=local` placeholder exits explicitly.
- `~measurement@1.0` is now the intended primary LapEE API, but old
  TPM-specific endpoints still exist for compatibility/debugging during the
  transition.

## Next Steps

1. Reboot the Framework with its nonvolatile green-zone disk and confirm it
   can rejoin via Yoga using the persisted ring material.
2. Add an SNP-specific green-zone template check against real SNP evidence.
3. Build and validate the signed TME runtime image.
4. Decide whether live SNP measurements should opportunistically embed AMD KDS
   endorsement material in `evidence.certificates` after successful fetches.
