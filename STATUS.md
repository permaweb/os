# Andock ARM64 release status

Updated: 2026-07-17 America/New_York

## Active execution

The implementation is now authorized to proceed autonomously. The validated
runtime base has been advanced to exact HyperBEAM edge
`fcdf5867686c64a8abe79e04e10f3590fbd62b7f` and integrated here before the
Andock implementation.

Parallel work is isolated as follows:

- `agent/hb-edge-fcdf`: completed upstream runtime/NIF/build integration;
- `agent/andock-fs-spike`: completed and rejected the one-time directory
  capability route on stock Android;
- `agent/ouroboros-portable-scoped`: completed portable device/UI/package-
  boundary reconciliation from the pre-auth ancestor, without publication;
- `agent/ouroboros-andock-backend`: ordinary trusted `~andock@1.0` package,
  branched from that clean pre-auth baseline; and
- `agent/andock-image-fd-stable`: architecture record and eventual clean
  integration.

No component is merged to `main` until the final dependency graph, emulator
runtime, package workloads, security assertions, and locally available target
builds are green together.

Authentication and workspace authorization are explicitly outside this
filesystem/runtime port. Andock preserves the existing interchangeable
Docker/QEMU request and `member-context` contract; any broader auth redesign is
tracked separately and is not a merge dependency here.

The final review boundary is now enforced mechanically as well as by scope:
the composed Android branch has no changed auth, session, bearer, wallet,
credential, or member-identity filename. Reviews proposing unrelated auth work
are stopped rather than converted into Andock requirements.

The scoped portable Ouroboros branch is clean at `20b293013f2ba307e44e1bb416146127420b679b`
from pre-auth base `3d708da8dd32ddd2810893841d722bf0cd0602e7`.
HyperBEAM/Forge are pinned to fcdf, seven real device specifications and package
boundaries are verified, and `make test` passed 11 source and 246 packaged
tests. Its diff contains no auth, session, bearer, node-wallet, identity,
`member-context`, or related test changes. The unchanged desktop QEMU harness
passed the seven tools, representative errors, file-list parity, and a 2.24 MB
round trip, then was bounded and reaped after the later attachment phase ran
for more than seven minutes and exceeded 6 GiB RSS; this is recorded as an
existing harness pathology rather than widened into the Andock scope.

The first standalone `~andock@1.0` package checkpoint is committed at
`59474d2` on `agent/ouroboros-andock-backend`. It delegates all seven tools,
file browsing, authorization, validation, serialization, clipping, and errors
to the existing shared `lib_ouroboros_execution` contract. Its only private
mechanic is the fail-closed local Android execution transport. Package and
import-boundary verification passed for all eight device archives, its real
Unix-domain framing tests passed 3/3, and `make test` passed 14 source plus
253 packaged tests. The branch contains no auth, bearer, session, node-wallet,
identity, or member-context change; the out-of-scope review task that proposed
such expansion was stopped.

The measurement-layer decision is now fixed: `~measurement@1.0` and
`~andee@1.0` do not change for Andock. The stable implementation will add only
reserved Android execution facts to `~system@1.0/all` plus matching verifier
policy/specification. The old `agent/andock-measurement` broker projection is
rejected. See `decisions/andock-measurement.md`.

## Objective and isolation

Replace the correct but unacceptably slow per-path Binder filesystem prototype
with a capability-backed filesystem that executes locally inside each Android
isolated worker.

- Worktree: `/Users/sam/.codex/worktrees/lapee-andock-image-fd`
- Branch: `agent/andock-image-fd-stable`
- Original clean base: `b2fcf2fa2741018635c72b7b4663ddb820aa9e14`
  (`agent/hb-edge-e445`). Exact HyperBEAM fcdf is integrated in this branch at
  `8b6ed2c4`.
- The prototype is parked at `492c34dcb852552d7c376abcae1ac769a46b906e`
  on `agent/andock-1.0` and is not merged into this branch.
- The shared checkout `/Users/sam/src/lapee` remains dirty with another
  developer's work and must not be modified.
- No push, publication, external infrastructure change, or wallet use.

At 23:11:55 an unrelated process force-moved the former
`agent/andock-image-fd` ref while this worktree was active. Every prior commit
remained recoverable in the reflog. The exact tree and parent chain were
reconstructed at `9707d6e` on the uniquely named stable branch above; neither
active Andock subtask reported touching the old ref. The old mutable ref is no
longer used as an integration anchor.

The complete threat model, implementation sequence, performance gates, and
validation matrix are in `decisions/andock-filesystem-capability.md`.

## Immediate work

1. Complete the syscall-layer synthetic `/dev` and bounded `/proc/self`
   surface without broad host binds, writable host temporary directories, or
   Android-root escape.
2. Integrate the pinned ARM64 native adapter and deterministic Ubuntu sparse
   template into the release runtime builder, with manifest validation and no
   generated image committed to git.
3. Run the full emulator contract, package-manager, Python/Node/Transformers/
   PyTorch, lifecycle, cancellation, concurrency, and adversarial network/
   app-private isolation matrix.
4. Recursively deep-clean the implementation and preserve the component branch
   split before composing the final dependency branch.
5. Validate the ordinary trusted Ouroboros packages and Arweave UI manifest on
   stock HyperBEAM and AndEE without auth, session, wallet, identity, or
   application-server changes.

## Current integrity gate

The per-command Android network broker is composed at `39ec02a`. Its focused
policy/protocol suite passed 9 tests, and the Android debug APK, unit, and lint
tasks are green. Native socket injection remains deliberately unclaimed until
the syscall adapter is integrated and the real IPv4, IPv6, UDP, DNS, redirect,
subprocess, copied-binary, local-address, and listener-denial probes pass.

The strengthened filesystem adapter gate rejected the latest native candidate
before integration: independent fresh template copies returned inconsistent
guest bytes for `/usr/bin/python3.12`, and `dpkg -V python3.12-minimal` reported
the executable as changed. The raw template itself is being checked separately
from the cached memfd/open-file-description layer. No APK or member image will
be accepted until fresh copies read identically, Python runs without a signal,
the synthetic kernel-path suite passes with seccomp enabled, and the exact
command is green three times.

## Dedicated emulator baseline

The owned test target is `emulator-5562`, AVD `codex-handee-4g`: ARM64, API 36,
Android 16, enforcing SELinux, 4 GiB RAM. It is separate from the pre-existing
`emulator-5554` and its active tunnel/node forwards.

The clean prototype APK (`b3e4ed8a...`) passed the full direct extended suite
on this emulator. Current timings are 1,551 ms cold, 363 ms warm, 18.25 s pip,
25.63 s local pip, 40.06 s apt, 15.74 s toolchain, 65.54 s espeak, 220.81 s
Transformers, 54.59 s Node/native addon, 8.10 s restart to first command, and
52.33 s full package audit after restart. Evidence is under the parked
prototype's ignored
`arch/android/build/evidence/image-fd-baseline/` directory.

A same-app-UID standard PRoot control traversed `/usr/lib/python3.12` with
`du` in 0.485 s. The isolated per-path broker took 2.324 s over the same
immutable tree, confirming that PRoot itself is not the dominant multiplier.
A deterministic deep-overlay control populated 10,000 empty files across four
directory levels directly under one member's writable state, then measured only
guest traversal. `du -s /root/meta` took 135.177 s inside the guest and
135.723 s through the command transport. The member was destroyed after the
run. This is 27 times the 5 s acceptance ceiling and isolates the current
per-path overlay broker as the pathological surface; no installation, download,
or file creation is included in that timing.

The matching immutable-base control removed overlay lookup, whiteouts,
hard-link markers, copy-up, and mutation entirely. The same 10,000-file
`du -s /root/meta` took 24.380 s inside the guest and 24.990 s through the
transport. The current overlay algorithm is a further 5.5x multiplier, but the
per-operation isolated-socket/Binder round trip alone is still 4.9x slower than
the 5 s ceiling. Caching or flattening only the host overlay cannot satisfy the
accepted architecture.

## Directory capability result

The disposable production-shaped probe used two separately named
`bindIsolatedService` instances. The application ran as UID 10250; the workers
ran as UIDs 99043 and 99044. Each worker called back into an application-UID
broker, matching the real Andock Binder direction. Android's Binder driver
rejected the app-private directory FD before worker code could use it and
logged `translate fd failed` for both instances. The API 36 ARM64 kernel also
has `CONFIG_SECURITY_LANDLOCK`, `CONFIG_USER_NS`, and `CONFIG_FANOTIFY` unset.

This closes the direct-directory route without relaxing owner-only modes,
SELinux, or the isolated UID. The complete probe, exact APK hashes, runtime
report, and decision rule are on `agent/andock-fs-spike` at `07eafbd`.

The emulator cannot provide the optional creation fast path: GNU
`cp --reflink=always` over two app-private regular files returned
`EOPNOTSUPP` for a 16 MiB control. The v1 storage model is therefore one
complete writable filesystem image per member, created atomically with a
sparse extent-preserving copy from the measured immutable template. Reflink
may accelerate creation on supporting retail storage, but overlay, whiteout,
copy-up, and runtime base lookup are explicitly out of scope for v1.

The app-private filesystem does preserve sparse holes: a 1 GiB control file
with one 4 KiB extent occupied 8 KiB (`st_blocks=16`). Android's Toybox `cp`
materialized the same copy to 1,073,750,016 bytes (`st_blocks=2097168`), so
member creation cannot delegate to the platform `cp`. The implementation must
copy data extents explicitly, with a zero-scanning fallback where
`SEEK_DATA`/`SEEK_HOLE` is unavailable, then `fsync` and atomically rename the
completed image.

## Regular-file image capability result

The pinned lwext4 spike is green on `emulator-5562` at
`agent/andock-image-engine-spike` commit `716af74`. A main-app regular-file FD
was transferred to three distinct isolated UIDs; each run formatted and
mutated a journaled ext4 image, deliberately killed the parser, rebound a new
isolated process, recovered and verified the filesystem, sparse-copied the
complete image, reopened the copy, and rejected four malformed-image classes.
All runs ended with `regular-file-image-capability=ok`, with no matching SELinux
denial.

The 64 MiB fixture occupied 1,409,024 bytes after copy. Three Android
`SEEK_DATA`/`SEEK_HOLE` copies took 1.859, 2.095, and 1.741 ms (1.859 ms
median). This accepts the one-time regular-file capability route but does not
The actual populated-tree checkpoint is green at `78661a8`. Three independent
2 GiB templates made from the pinned 823 MiB source tree were byte-identical at
`1935843759cb448ebfb95115021d210a908b5595a89dab4e10ca9e1567df42f9`
and occupied 938,082,304 bytes. The gate enumerated all 26,931 imported entries,
read the exact AArch64 glibc/Python/Node ELFs and usr-merge symlinks, persisted
hard links, symlinks, modes, timestamps, and `user.*` xattrs, and recovered a
committed rename after deliberate process death. Three complete sparse copies
took 149.034, 109.940, and 123.512 ms.

This accepts the populated image format, but not the prototype's macOS staging
metadata. Host extraction collapsed numeric OCI ownership and Linux xattrs to
the macOS user. The production template must be built as root inside the pinned
Linux builder/directly from the numeric-owner OCI export and assert service
ownership and Linux xattr/capability fidelity. The PRoot syscall adapter,
coherent repeated-open behavior, writable `mmap`, Android lifecycle, and
checker strategy remain explicit gates.

## Local-image Android integration checkpoint

The Android service implementation now compiles and launches the execution
manager beneath the stock HyperBEAM process. A standard Android sparse image
in the runtime ZIP expands to a hole-preserving app-private raw image, and the
manager atomically creates one complete writable sparse image per member. The
2 GiB integration fixture occupies 805 MiB on the emulator; the persisted
member image survived an in-place APK replacement.

The corrected PRoot adapter removed both the Termux-incompatible talloc abort
and the failed-initialization null cleanup crash. The isolated worker runs under
`u:r:isolated_app:s0:c512,c768`; it cannot read the application data root,
crypto socket, effective config, encrypted-zone state, or execution-state
directory. A one-shot abstract `SOCK_SEQPACKET` capability handoff now restores
the member image descriptor that Android's `ProcessBuilder` deliberately
closes. Its native launcher requires the same isolated UID, exactly one regular
read-write image descriptor, a fixed capability byte, no truncation, and no
extra descriptors before replacing itself with PRoot.

The next exact Android failure was SELinux denial of `open(/proc/self/fd/N)` on
the materialized `memfd:andock-file`; direct probes proved that memfd creation,
read/write, duplication, and executable mappings work while all proc-fd reopen
variants fail with `EACCES`. The native layer no longer reopens proc-fd paths.
It uses `F_DUPFD_CLOEXEC` and preserves Linux open-file-description semantics
inside the tracer: independent positions across separate opens; shared
positions/flags across dup and fork; positional read/write vector rewrites;
synthetic `lseek`, `F_GETFL`, and `F_SETFL`; logical access-mode checks; and
ext4 identity/capacity for both `statfs` and `fstatfs`. Host image-engine and
launcher regressions are green, the first ARM64 cross-build linked, and the
final artifact rebuild is running before emulator integration. This change is
entirely within the filesystem compatibility layer; it does not alter identity,
authorization, or credentials.

The deterministic production template is complete at `5e1b23c`. Two clean,
pinned builders produced byte-identical 8 GiB raw ext4 images, Android sparse
images, manifests, and 26,938-entry metadata inventories. The raw image SHA-256
is `a2da758ebe2b780a2a4b271d35747a3d7116ffb91677395484c1f8f0fccb32a5`, the
sparse image SHA-256 is
`febb51845e8becf078195c0c805c34df91dd7bc8e9f709ec595488691892dc63`, and the
manifest SHA-256 is
`1b1e4af37819ca92b20eb80c16e42a39ba57bab582ec3be66baf92f972eb90ab`;
standard `simg2img` and the pinned lwext4 probe both independently reopen the
result. Raw images remain ignored build artifacts and are never packaged.

The native build is content-addressed: an unchanged pinned source/patch/output
set validates and exits in 0.05 s, while a tampered binary fails validation.
No authentication, session, bearer-token, wallet, identity, or member-context
file is changed in the Andock, portable Ouroboros, or Android service diffs.

The first complete writable-image service checkpoint is committed at
`c952ade0f72370f5a32c4e96c296901c6351c2f8`. On a clean APK install, the
production-shaped 8 GiB Ubuntu image expanded sparsely and the first member
clone plus command completed in 1.12 s. The guest reported 987 MiB used and
7.1 GiB free. Binary/UTF-8 file content round-tripped exactly; a second member
could not read it; state survived a service/process restart; destroy removed
it; and a 500 ms command deadline returned exit 124 with `timed-out=true` in
1.25 s without crashing the isolated service. `/proc/self/root` resolved to
`/system`, app-private paths were absent, and the tracee exposed only its own
stdio descriptors. A cancellation race found during this run is fixed in the
checkpoint and awaits the next installed-APK repetition.

The remaining real guest failure is not image or CPU performance. Because the
safe root remains `/system`, stock PRoot's normal host-path translation cannot
provide `/dev/null` or its peers, and PRoot bind glue cannot create targets:
the isolated UID deliberately has no writable host directory for
`PROOT_TMP_DIR`. Broad `/dev`, Android-root, or app-data binds are rejected.
The bounded fix is direct syscall-layer FD injection plus synthetic metadata
for safe device paths, with adversarial denial of `/proc/self/root`, `cwd`,
`exe`, arbitrary descriptors, and all non-self process paths.

The release staging path is committed at `8c497df`: it validates the pinned
template recipe and both sparse/raw digests, stages only the Android sparse
image plus its manifest, and stages content-addressed ARM64 PRoot/launcher/
loader binaries into the APK native payload. The direct ARM64 emulator suite
is committed at `12477e4`; it covers the actual app-private Unix socket,
isolated UID/SELinux process, binary and unusual filenames, exact 20 MiB
clipping, timeout, concurrent cancellation, network denial, app-private
isolation, restart persistence, and destroy.

Three additional fresh-member clone-plus-`true` measurements over the real
Android transport took 0.636, 0.700, and 0.757 seconds. Each member was
destroyed immediately after its run. This is the complete writable-image path,
not the old per-path broker or an overlay shortcut.

Scope remains frozen. The current HyperBEAM pin, portable Ouroboros package,
standalone `~andock@1.0` adapter, native adapter, template builder, and Android
service diffs contain no authentication, bearer, session, wallet, member-
identity, or credential-processing change. The expansive reviewer was stopped;
those concerns belong to the separate authentication effort.

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

# HyperBEAM fcdf LapEE/AndEE integration record

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
