# Andock filesystem-capability status

Updated: 2026-07-16 America/New_York

## Objective and isolation

Replace the correct but unacceptably slow per-path Binder filesystem prototype
with a capability-backed filesystem that executes locally inside each Android
isolated worker.

- Worktree: `/Users/sam/.codex/worktrees/lapee-andock-image-fd`
- Branch: `agent/andock-image-fd`
- Exact base: `b2fcf2fa2741018635c72b7b4663ddb820aa9e14`
  (`agent/hb-edge-e445`).
- The prototype is parked at `492c34dcb852552d7c376abcae1ac769a46b906e`
  on `agent/andock-1.0` and is not merged into this branch.
- The shared checkout `/Users/sam/src/lapee` remains dirty with another
  developer's work and must not be modified.
- No push, publication, external infrastructure change, or wallet use.

The complete threat model, implementation sequence, performance gates, and
validation matrix are in `decisions/andock-filesystem-capability.md`.

## Immediate work

1. Capture reproducible current-broker metadata and package baselines.
2. Remove the repeated regular-file `TCGETS`/SELinux audit storm and remeasure.
3. Test whether a received app-private directory FD supports safe `openat2`
   mutation from an isolated UID.
4. If it does not, prove a local userspace filesystem image through one passed
   FD and select the filesystem/storage representation using measured results.
5. Implement locally resolved filesystem syscalls and delete the per-operation
   socket/Binder/Kotlin host broker.

## Non-negotiable acceptance

- Android isolated UID and SELinux remain the security boundary.
- No guest host-path concatenation or descriptor exposure.
- PyTorch install and post-install traversal meet the explicit performance
  gates in the decision record.
- The seven-tool contract, package-manager parity, network policy, lifecycle,
  persistence, destroy, and cross-member isolation pass on emulator and real
  ARM64 hardware.
- Measurement changes follow the stable implementation rather than naming the
  parked `android-app-broker@1` design.

---

# Inherited HyperBEAM e445 LapEE/AndEE integration record

## Completed runtime contracts

- [x] HyperBEAM, Forge plugin, and both dependency locks use exact e445.
- [x] Forge plugin path follows e445's `src/forge/plugin` layout.
- [x] The generated preloaded-index header/environment convention is removed;
  packaging resolves e445's real LMDB
  `~meta@1.0/preloaded-devices-index` link instead.
- [x] `trusted-device-signers` is the sole e445 remote-loading switch and
  remains part of the effective, measured node message. The obsolete
  `load-remote-devices` operator key is stripped.
- [x] Android packages real NDK builds of `b64veryfast`, `elmdb`, `hb_beamr`,
  `hb_keccak`, `hb_util_string`, and secp256k1 for ARM64 and the existing
  emulator ABI. No pure-Erlang base64 substitute remains.
- [x] Buildroot separates host Forge executables/NIFs from the x86-64 target
  release, passes the real `BR2_ARCH`, and rejects foreign target ELF.
- [x] `hb_buildinfo` is normalized after the final build hook to the source
  SHA, 12-character short SHA, and commit epoch `1784173208`.
- [x] Buildroot hashes and copies only five declared PermawebOS device inputs;
  ignored `_build` caches and `hyperbeam-key.json` cannot enter the image.
- [x] Generic AO decoding and normal device resolution are unchanged.
- [x] No `dev_measurement` change is needed: existing measurement already
  commits the effective node message and packaged runtime artifacts.

## Validation ledger

All listed commands exited 0 unless explicitly described as an earlier probe.

### Dependency and device package

- `devices/common`: `../../arch/android/scripts/verified-rebar3.sh compile`
  built against e445. An initial probe caught e445's new direct `lmdb-sys`
  dependency; the checked-in upstream lock was updated and the clean compile
  passed.
- Real Forge preload completed and `hb_store_lmdb` resolved
  `~meta@1.0/preloaded-devices-index` to
  `8K834mDI2S0fVHsUkDnoXOMQ1A1HkhpGWE0HnC1e9Vw`.
- `../../arch/android/scripts/verified-rebar3.sh eunit
  --application=lapee_devices`: 32 tests, 0 failures.
- Staged Android `eunit --application=andee_devices`: 39 tests, 0 failures.
- Both `rebar.lock` files are byte-identical.

### Android cross-build and native behavior

- `make -C arch/android runtime`: passed from the exact branch source.
- Runtime manifest: 54 native APK payloads and 26 runtime links per ABI.
- Every packaged native payload has the expected ELF machine. The ARM64
  critical NIFs/drivers are AArch64 ELF; the emulator copies are x86-64 ELF.
- Android `DT_NEEDED` closure is only `libandroid.so`, `libc.so`, `libdl.so`,
  `liblog.so`, and `libm.so`.
- Host Forge's cached `b64veryfast.so` is a native arm64 Mach-O bundle, proving
  the build host never executes an Android target object.
- `hb_util_string,secp256k1_nif` targeted EUnit: 7 tests, 0 failures.
- `hb_ecdsa_tests`: 61 tests, 0 failures against the native secp NIF.
- `hb_beamr,hb_beamr_io`: 11 tests, 0 failures; benchmark observed 92,900
  calls/s in this run.
- Native `b64veryfast` round-tripped 1,048,576 random bytes.
- `make -C arch/android apk`: passed (`BUILD SUCCESSFUL`).
- `make -C arch/android android-check`: passed.
- `make -C arch/android erl-compile`: passed.
- `make -C arch/android verify-config-invariants`: passed.
- Runtime ZIP from this build:
  `ce2ff8797d1a6d7b351337ce50a92f64d041170e2dab389d4cea2c7137efbab6`
  (62,477,527 bytes).
- Debug APK from this build:
  `7f1003c88bfd76091f72d9b02514618586cd01bced77f1cee150d69430a610bf`
  (78,612,947 bytes).

### Linux / Buildroot

- Full isolated build command:
  `make buildroot BUILD_IMAGE=lapee-hb-edge-e445-build:local
  BUILDROOT_VOLUME=lapee-hb-edge-e445-buildroot`.
- The first cross-only probe correctly failed because Forge is a host tool and
  cannot load x86-64 target NIFs on an ARM64 build host. The final build first
  compiles host-native Forge dependencies, creates the store, cleans native
  state, then produces the target runtime.
- Exact source replay completed from the persistent isolated volume without a
  HyperBEAM rebuild marker, proving the recipe hash excludes ignored caches
  and wallet material.
- Copied device input closure: 916 KiB containing exactly `cargo-locks`,
  `native`, `src`, `rebar.config`, and `rebar.lock`.
- All ELF under `/usr/lib/hyperbeam` is x86-64. Required native artifacts are
  present for b64, LMDB, Beamr/WAMR, Keccak, string utilities, and secp256k1.
- Runtime native dependencies are limited to the target loader/libc,
  `libcrypto.so.3`, and `libgcc_s.so.1`.
- The packaged preloaded LMDB is 7.9 MiB. No `b64rs`, generated preload header,
  wallet, or foreign ELF is present.
- Both shipped `hb_buildinfo` copies (`bin/priv` and the `hb` application) have
  the exact e445 SHA, 12-character short SHA, and commit epoch. A final audit
  caught and corrected relx's duplicate `bin/priv` copy before commit.
- Final initramfs:
  `a4cd80c2e95ab6d94c917db21589db30a92b5bea1faeae8a887ae722c3ee368a`.
- Final kernel:
  `470ef8caa1f2e67ed1204db4e0d0cd210767ee6ad248db55120481804b10bfe8`.
- The final no-change replay produced those same hashes, retained the 916 KiB
  five-path device closure, and contained no HyperBEAM rebuild marker.
- Buildroot's transient container name now derives from its selected volume
  (or `BUILDROOT_CONTAINER`), so isolated worktrees cannot remove one another's
  in-progress build container. The final replay exercised that path and left
  no container behind.
- A clean Forge preload uses a fresh build-only signing identity by default,
  so this branch does not claim the signed LMDB store is byte-reproducible
  across clean builds. The private build wallet is never copied into the
  builder or runtime; measurement commits the resulting immutable store.

### Static gates

- `make verify-config-invariants`: passed.
- Edited shell files pass `bash -n`; edited Python files pass `py_compile`.
- `git diff --check`: passed.
- Stale pin, obsolete preload-header, removed b64 fallback, generic-decoder,
  and signer-policy scans completed.
- Final static/invariant gates were repeated after the last source edit.

Non-obvious design reasoning is recorded in
`decisions/hyperbeam-e445-runtime-contracts.md`.
