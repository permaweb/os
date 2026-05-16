# LapEE Measurement/SNP Status

## Current Focus

Branch: `feat/measurement-snp`.

Normalize TPM and SEV-SNP style node evidence under `~measurement@1.0`, then
route green-zone admission through that common measurement protocol.

## Latest Checkpoint

The TPM side of the measurement reorg is working through local/QEMU coverage.
The SNP side now has the intended small native boundary and Erlang-side
verification shape, but the real remote SNP guest is not yet answering HTTP
requests after boot. The current blocker is now isolated to real-SNP runtime
bring-up, not to the local protocol model or the older TPM NIF crash.

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
- Added kernel/build support needed for SEV-SNP guest probing.
- Replaced green-zone peer transport calls with HB HTTP plus AO-Core JSON
  bundle negotiation, avoiding the older custom JSON helper path.
- Fixed admission response handling so a status-200 response with a linked
  body is normalized through the same policy/error path as direct bodies.
- Rebuilt the SNP backend around a tiny overlay-owned Rust NIF:
  `supported/0` checks `/dev/sev-guest`; `report/2` returns raw SNP report
  bytes plus the platform certificate table. The NIF no longer performs JSON
  construction or report verification.
- Moved SNP report parsing, report-data checks, AMD KDS/certificate handling,
  and ECDSA signature verification into `dev_snp.erl`.
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
- Remote SEV-SNP host reconnaissance:
  - Host: `ssh://hb@dev-1.forward.computer`.
  - CPU: AMD EPYC 9254, family 25 model 17, inferred KDS product `Genoa`.
  - SNP host support is enabled; the guest kernel reports:
    `sev-guest ... using VMPCK0 communication key`.
  - The SNP guest now gets past the previous fatal TPM NIF load failure.

## Not Yet Verified

- Real SEV-SNP `~measurement@1.0/boot`, `fresh`, and `verify` on
  `hb@dev-1.forward.computer`.
- Mixed TPM/SNP green-zone behavior.
- Production, non-debug runtime image after the measurement reorg.

## Known Gaps

- Real SNP endorsement-chain validation is proven only against fetched sample
  AMD material so far, not against a live guest report.
- The remote SNP guest currently boots to the HyperBEAM banner and accepts TCP
  connections on the forwarded port, but HTTP requests to
  `~measurement@1.0/info`, `~system@1.0/all`, and `~meta@1.0/info` time out
  with zero response bytes. The latest serial log shows no Erlang crash. This
  suggests a startup/on-start/runtime wedge inside the real SNP guest rather
  than the old `lapee_tpm_nif` crash.
- `qemu-measurement-remote` currently implements the SSH/SNP path only; the
  `TARGET=local` placeholder exits explicitly.
- `~measurement@1.0` is now the intended primary LapEE API, but old
  TPM-specific endpoints still exist for compatibility/debugging during the
  transition.

## Next Steps

1. Isolate the remote SNP HTTP wedge by adding measured diagnostic tracing or
   by booting a controlled image with the measurement `on/start` hook disabled.
2. Confirm whether the hang is in the start hook, system report collection,
   SNP report collection, message signing/cache, or HyperBEAM HTTP startup.
3. Make the fix in the smallest layer that actually owns the fault.
4. Re-run the remote SNP smoke until `info`, `boot`, and `fresh` all return
   signed AO-Core measurement messages.
5. Run mixed TPM/SNP green-zone admission after the live SNP measurement path
   works.
