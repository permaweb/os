# LapEE Measurement/SNP Status

## Current Focus

Branch: `feat/measurement-snp`.

Normalize TPM and SEV-SNP style node evidence under `~measurement@1.0`, then
route green-zone admission through that common measurement protocol.

## Implemented In This Checkpoint

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
- Built signed debug no-TME image:
  - `build/images/lapee-measurement-debug-greenjoin-signed.img`
  - `sbverify` reported `Signature verification OK`.
- QEMU nonvolatile TPM green-zone cluster passed before the final admission
  response normalization patch:
  - four nodes booted and answered `~measurement@1.0/boot`;
  - node 4 was rejected by template mismatch;
  - nodes 1-3 produced ring-signed membership proofs;
  - node 2 reused encrypted nonvolatile storage after reboot;
  - node 2's current boot measurement stayed current after store activation.

## Currently Running

- Plain TPM four-node QEMU green-zone cluster:
  - command:
    `IMG=build/images/lapee-measurement-debug-greenjoin-signed.img OUTDIR=build/qemu-measurement-plain TIMEOUT=1200 ./scripts/qemu-green-zone-cluster.sh`
  - current evidence:
    - all four nodes answered `~measurement@1.0/boot`;
    - node 1 initialized the green zone;
    - node 1 produced a valid `~measurement@1.0/verify-peer` for node 2;
    - node 1 admitted node 2;
    - harness is waiting for node 2's local join to complete.

## Not Yet Verified

- Fresh plain TPM QEMU cluster completion after the final admission response
  normalization patch.
- Fresh `MEASUREMENT_DEVICE=snp-mock@1.0` QEMU cluster after this checkpoint.
- Real SEV-SNP run on `hb@dev-1.forward.computer`.
- Mixed TPM/SNP green-zone behavior.
- Production, non-debug runtime image after the measurement reorg.

## Known Gaps

- Real SNP endorsement-chain validation is not yet proven on hardware. The
  current SNP implementation has report binding/parsing and mock protocol
  coverage, but the remote SEV-SNP acceptance test is still required before
  calling SNP production-ready.
- `~measurement@1.0` is now the intended primary LapEE API, but old
  TPM-specific endpoints still exist for compatibility/debugging during the
  transition.
