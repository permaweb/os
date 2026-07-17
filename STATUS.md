# HyperBEAM fcdf LapEE/AndEE Integration Status

Updated: 2026-07-16 America/New_York

## Objective and isolation

Advance the stock HyperBEAM runtime packaged by LapEE and AndEE from
`e445aad9da2a3017023ce99bd934540729e3b872` to exact edge
`fcdf5867686c64a8abe79e04e10f3590fbd62b7f`, preserving the native-build,
device-loading, configuration, and measurement contracts established by the
e445 integration.

- Worktree: `/Users/sam/.codex/worktrees/lapee-hb-edge-fcdf`
- Branch: `agent/hb-edge-fcdf`
- LapEE base: `b2fcf2fa2741018635c72b7b4663ddb820aa9e14`
- No edits to `/Users/sam/src/lapee`, upstream HyperBEAM, another worktree,
  emulator, shared process, remote, or external infrastructure.
- No push or publication.

## Upstream assessment

The final HyperBEAM tree delta from e445 to fcdf is one file and 25 added
lines:

```text
 src/core/http/hb_http.erl | 25 +++++++++++++++++++++++++
 1 file changed, 25 insertions(+)
```

The change adds the request host to HTTP response logs. `rebar.config`,
`rebar.lock`, `src/forge`, native sources, scripts, Makefiles, and submodules
are unchanged. Intermediate commits in the range touched name-device code, but
those edits cancel in the final fcdf tree; packaging is based on the final tree,
not the intermediate history.

Consequently this upgrade requires only the exact source/Forge/lock pins and
the normalized source epoch to change. The e445 native, preloaded-store,
remote-device trust, generic AO decoding, and measurement decisions remain
valid. No measurement-device or effective-config change is warranted.

## Completed pin update

- [x] Common and Android HyperBEAM dependencies use exact fcdf.
- [x] Common and Android Forge plugin dependencies use exact fcdf.
- [x] Both checked-in dependency locks use exact fcdf and remain byte-identical.
- [x] AndEE's runtime builder rejects any HyperBEAM source other than fcdf.
- [x] Buildroot uses exact fcdf and commit epoch `1784211633`.
- [x] No active e445 source or epoch pin remains under `arch/`, `devices/`, or
  `scripts/`.

## Validation ledger

All commands below exited 0 unless a diagnostic probe is explicitly described.

### Dependency and device packages

- Clean common compile:
  `cd devices/common && ../../arch/android/scripts/verified-rebar3.sh compile`.
  The resolved HyperBEAM and Forge plugin repositories both have HEAD fcdf.
- Common device EUnit:
  `../../arch/android/scripts/verified-rebar3.sh eunit
  --application=lapee_devices`: 32 tests, 0 failures. Expected warnings report
  the absence of laptop-only TPM/SNP NIFs on the macOS host.
- Staged Android device EUnit:
  `cd arch/android/build/android-devices &&
  ../../scripts/verified-rebar3.sh eunit --application=andee_devices`: 40 tests,
  0 failures.
- `cmp devices/android/rebar.lock devices/common/rebar.lock`: identical.

### Native behavior

- `hb_util_string,hb_ecdsa_tests`: 68 tests, 0 failures.
- `hb_beamr,hb_beamr_io`: 11 tests, 0 failures from the exact HyperBEAM source
  root; benchmark observed 74,096 calls/s.
- Native `b64veryfast` round-tripped 1,048,576 random bytes.
- A direct `rebar3 eunit --module=hb_http` diagnostic cancelled before tests
  because the standalone harness starts `hb_http_client` before hackney's pool
  ETS table exists. The Forge core-device selector also has no `hb_http`
  module target. Neither probe reports an assertion failure, and the upstream
  fcdf change itself is compile-covered by all complete builds below.

### Android runtime and APK

- Clean `JOBS=8 make -C arch/android runtime`: passed for ARM64 and the existing
  emulator ABI.
- Runtime manifest: 54 native APK payloads, 54 native libraries, and 26 runtime
  links per ABI.
- All 54 packaged JNI/native payloads have the expected architecture. Android
  `DT_NEEDED` closure is limited to `libandroid.so`, `libc.so`, `libdl.so`,
  `liblog.so`, and `libm.so`.
- Both ABI runtime trees carry exact fcdf `hb_buildinfo`, short source
  `fcdf5867686c`, and commit epoch `1784211633`.
- `JOBS=8 make -C arch/android apk`: passed (`BUILD SUCCESSFUL`).
- `make -C arch/android android-check`: passed.
- `make -C arch/android erl-compile`: passed.
- `make -C arch/android verify-config-invariants`: passed.
- Runtime ZIP:
  `64112eb87321c21afbc3436193579ddc51373bf05327dfb0134c0a2cb28f8627`
  (62,584,707 bytes).
- Debug APK:
  `e247dcc17785cedc4961432f69e8ef2663b4a26a6312e56d7e1e43dfc8bb620e`
  (78,719,751 bytes).

### Linux / Buildroot

- The pinned local Debian builder image rebuilt successfully from
  `arch/common/linux/docker/Dockerfile`. Docker's registry API returned one
  transient HTTP 500 while `make toolchain` attempted a redundant pull; the
  exact cached-image build completed locally without changing inputs.
- Full isolated build:
  `JOBS=8 make buildroot BUILD_IMAGE=lapee-hb-edge-fcdf-build:local
  BUILDROOT_VOLUME=lapee-hb-edge-fcdf-buildroot`.
- The build compiled host-native Forge, produced a real preloaded LMDB, then
  cleanly cross-compiled the x86-64 HyperBEAM release and every mandatory NIF.
- The resolved preloaded-device index was
  `FjrwNyFV0FutEBDmCfeghpOFOvfYoYNrgQKbnQT2r6Q`.
- The declared PermawebOS device input closure remains 916 KiB containing
  exactly `cargo-locks`, `native`, `src`, `rebar.config`, and `rebar.lock`.
- Every executable/runtime ELF under `/usr/lib/hyperbeam` is x86-64. Required
  native artifacts are present for ASN.1, b64, LMDB, Beamr/WAMR, Keccak, string
  utilities, and secp256k1. Non-x86 ELF files elsewhere in the target are
  hardware firmware blobs, not host-executable runtime code.
- The packaged preloaded LMDB is 8.0 MiB. No `b64rs`, generated preload header,
  private wallet/key material, or foreign runtime ELF is present. The
  `ar_wallet.beam` module name is code, not packaged credential material.
- Both shipped `hb_buildinfo` copies contain exact fcdf, short source
  `fcdf5867686c`, and epoch `1784211633`.
- Kernel:
  `27054ee53e78c02773fd9e64c528c6020572fe6260bcad186ad7ba87b9aad808`.
- Initramfs:
  `70c037b7bc3255153ef23a3cf3eb6e8a3147658652005f97f35408ad29b887ab`.
- An unchanged replay completed with the same two hashes. Buildroot reruns the
  deterministic kernel configuration and image-generation phases, but did not
  rebuild the already stamped fcdf HyperBEAM package.

### Static gates

- Root `make verify-config-invariants`: passed.
- Edited shell files pass `bash -n`; the config-invariant script passes
  `py_compile`.
- `git diff --check`: passed.
- Active-pin, stale-pin, upstream-delta, lock-identity, packaged-architecture,
  native-dependency, credential, and runtime-buildinfo audits passed.

The retained e445 architectural reasoning is in
`decisions/hyperbeam-e445-runtime-contracts.md`; the incremental fcdf decision
is in `decisions/hyperbeam-fcdf-runtime-contracts.md`.
