# Andock ARM64 release status

Updated: 2026-07-18, America/New_York

This is the authoritative unattended ledger. Re-read it after compaction and
update it after every material code, artifact, or validation change.

## Objective and stop condition

Deliver a least-surprising Linux execution environment for ordinary unrooted
ARM64 Android phones, with the same seven Ouroboros tools as `~docker@1.0`,
native-speed workloads, writable per-member filesystems, ordinary package
managers, persistence, stop/destroy, bounded resources, and real network
denial. Finish on one clean LapEE branch and one clean Ouroboros branch,
emulator-validated and ready for a real-phone gate. Do not claim full release
completion until that real ARM64-phone gate passes.

## Canonical repositories

- LapEE worktree: `/Users/sam/.codex/worktrees/lapee-andock-arm64-release`
- LapEE branch: `agent/andock-arm64-release`
- Final source parent: `27652312980bfb96e4c6ce890fe0fffbf49fb788`;
  the final release commit is the commit containing this ledger.
- Ouroboros worktree: `/Users/sam/.codex/worktrees/ouroboros-andock-backend`
- Ouroboros branch: `agent/ouroboros-andock-backend`
- HyperBEAM pin: `fcdf5867686c64a8abe79e04e10f3590fbd62b7f`

The shared dirty `/Users/sam/src/lapee` and `/Users/sam/src/ouroboros`
checkouts are untouched. No HyperBEAM source was changed. Parked QEMU, PRoot,
measurement, directory-capability, app-broker, and auth-divergent branches are
recovery history, not delivery branches. No remote branch was pushed.

## Accepted architecture

Android's isolated worker UID and SELinux domain are the sandbox. PRoot is the
Linux syscall/path adapter inside that boundary; it is not described as the
sandbox. Each worker receives only one member-specific writable ext4 image
descriptor, immutable execution artifacts, a command channel, and an outbound
network capability when the request explicitly enables networking.

The worker never receives the app root, another member image, node wallet,
provider credentials, effective node config, APK-private keys, crypto socket,
or arbitrary Android storage. Network-disabled workers have no brokered
network capability; denial is not command-string inspection. V1 makes a full
sparse copy of the base image per member because performance is more important
than storage deduplication. The accepted design is in
`decisions/andock-filesystem-capability.md`.

The implementation supplies:

- an Ubuntu 24.04 ARM64 base with normal `apt`, Python/venv/pip, Node/npm,
  native toolchains, Java, Ruby, Rust, Go, and common Unix tools;
- a complete mutable root filesystem for every member;
- a native lwext4 engine and PRoot syscall adapter with descriptor, inode,
  link, mapping, lock, xattr, timestamp, proc-fd, sparse-I/O, and Unix-socket
  behavior needed by modern toolchains;
- isolated-worker lifecycle, admission limits, per-member serialization,
  timeouts, cancellation, output clipping, stop, destroy, restart persistence,
  and orphan prevention; and
- brokered IPv4, IPv6, UDP, DNS, subprocess, copied-binary, listener, local-
  address, and Unix-socket policy.

The guest is fake-root rather than kernel root. `user.*` xattrs are supported;
privileged xattrs remain denied. Android application SELinux remains the
security boundary.

## Generic AndEE corrections in the final patch

These changes are generic HyperBEAM-on-Android behavior, not an
AndEE-Ouroboros server:

- Private configuration now follows normal HyperBEAM semantics. AndEE no
  longer strips `priv-key-location`, `priv-wallet`, `private-key`, or provider
  credentials from the private effective node message.
- When no identity path is configured, Android supplies an app-private
  `noBackupFilesDir/node-identity/hyperbeam-key.json` default. The node address
  therefore survives service and process restarts; the path and key bytes are
  not public facts and are not passed to Andock.
- The normal primary store is app-private stock `hb_store_lmdb`, outside the
  replaceable runtime directory, with an 8 GiB virtual map and batch size 100.
  Release claims are deliberately narrower than generic synchronous LMDB
  durability because the pinned backend acknowledges overlay writes before a
  batched transaction commits.
- Gateway-fetched device archives decode through the measured preloaded LMDB
  and are not redundantly materialized into the primary store. This removed a
  pathological archive decode/write path that consumed hundreds of millions
  of reductions and hundreds of MiB for a roughly 100 KiB device archive.

No `~measurement@1.0`, `~andee@1.0`, or `~system@1.0` change is required.
Existing measurement already commits the APK set, signing certificate,
runtime ZIP, native libraries, effective public node configuration, and the
immutable Andock/template artifacts they contain. Mutable member images and
private credential values are correctly excluded. See
`decisions/andock-measurement.md`.

## Frozen ARM64 artifacts

- Andock/PRoot native binary:
  `d79f6f33a47fea2031d608c8b95086f09648eb202e20ba8c73819f4755cba74c`
- Native manifest:
  `74814bdfcfb0c08769798d311fc47fab15ed9f6fda45a3fdf1e0cfe832a92da4`
- Ubuntu template:
  `e468693573fcf162ddbe6d0e8ffdf3ff2e07992a3e2f7387017b342f6df9423c`
- Canonical preloaded LMDB:
  `d2f0765b94e84f77ef90b24030453aedcd91a0130df21acbfdc5802c51421182`
- Final debug APK:
  `f76be14a1c5671a107b785115c95ce9f5e076e4c228ed36669e95b72aa029f18`
- Final runtime ZIP:
  `920c3eebd72540932eea6116010d5ee6f0cb64c6699b799cc998c87a7959cff3`
- Final runtime manifest:
  `4d7fbc126ef271dc3685043fb4f66c2523b9d0664b7bba7c211b3251d6d2a988`

Two complete assemblies reproduced the final APK and runtime ZIP byte for
byte. The private emulator configuration is mode 0600 under
`arch/android/build/evidence/final-unattended/image-13-final-acceptance/private/`.
It contains the user-supplied provider keys and must never be printed or
committed.

## Linux workload acceptance

The clean-member emulator workload passed all 36 stages in 926.494 seconds
with `ANDOCK_EMULATOR_WORKLOADS_OK`. It covered APT, system and virtualenv pip,
Python, Node/npm/node-gyp, compiled native extensions, Java, Ruby, Rust, Go,
CPU-only PyTorch, Transformers, warm ML imports, files, links, xattrs, sparse
I/O, locks, mmap, sockets, DNS, disabled-network denial, output clipping,
timeouts, cancellation, serialization, concurrent members, force-stop,
persistence, and destroy. Key timings were APT 346.096 s, PyTorch install
87.589 s, Transformers 65.850 s, warm ML 17.121/16.733/17.035 s, and raw UDP
DNS 0.531 s.

- Result JSON SHA-256:
  `d8d5d2cb930ce1be4cef602d6e6af7b5813f53341154baef9812616b40c733f9`
- Console log SHA-256:
  `c1b036c1fe2afd6ec0f3d854e987107702773a86d498e5b860f4b5d9316610a5`

A mutable workspace write left every unsigned boot-measurement field
byte-identical; the commitment-free response SHA-256 before and after was
`7720a84ac22bf1b72257a5882970ac2a57d546c6c02d8094b6ce3bebef722303`.
Destroy removed the exact member image and passed
`ANDOCK_DESTROY_DELETION_OK`.

## Final direct-manifest and restart acceptance

Owned test device: `emulator-5562`, ARM64 API 36, AVD
`codex-handee-4g`, enforcing SELinux. `emulator-5554` belongs to another task
and is never touched.

From a clean install of the frozen APK, AndEE served the published Ouroboros
application directly at `GET /rB2YuIuE8FKzhvjJ2bjB3Iea0tH3LxdA6wkTFk530b8`.
The manifest returned HTTP 200 in 2.264 s and the JavaScript returned HTTP 200
in 1.484 s with the exact published SHA-256
`80f1216fb67ecd12b90693f8aeb8fb97567f069cbae1c163e7ddabd505cea468`.
No developer Python application server was in this request path.

The provider-backed browser flow passed generated-key, JSON-key, and browser-
wallet login; profile/config import; workspace and nested-space creation; Team
Lead; an exact real Andock Bash result; thoughts; file browse/download;
nested-channel participation; unassisted Alpha-to-Beta-to-Alpha telephone;
invite redemption; and browser-wallet-signed authoritative workspace deletion.

Android immediately force-stopped the app. After unchanged restart, the node
address remained `4vJvw5hDiSstQz8PxaknHkZ-rs7pj1MCdIQ8NDPwLqo` and the root
process remained `uwX_tHFcchCxxaNh5UJ1OWVl4tdgDH9uDMao5mwEg68`. Recovery
proved workspace, nested channel, Shell history, telephone history, member
route, and a new exact Bash result survived. The deleted workspace remained
absent by both id and name. The recovered root reports exactly the configured
operator `1tAG04TLl8Wg2GXPm4gvqexkBqnem0_o44Q0OUtWdow` and the node address as
its registration authorities; evidence SHA-256 is
`aea0b0d0ca3a5e322d0fe96f57d8eaba32d33371c9c71f4fd131c9b6f0ec5295`.

Final browser evidence is under the Ouroboros worktree at
`.run-data/final-secure-v2/`:

- acceptance log: `1adeb1b61871acbd57f356e5b774e479952d246c6803d68e6768c7c4c829d1bd`
- private state: `4811786c162dc9b3db5ed1168948b49f71546752eb73beaf45f0d04c3ad1ce91`
- acceptance screenshot: `7a66bbd6ceb8cae2fe742f778a93e3653c9a725365356404047f4bb8f501fd51`
- recovery log: `f27a7035259b542eeb2bcaa48b159d4508ac9a9489cf766761735f107118e8ca`
- recovery screenshot: `36dcca44ffc91d07d1dbf3586b1d9cb136fb3c3e7a65ffa78e4a98298765926f`

## Final validation ladder

Passed on the exact frozen APK:

- `make -C arch/android verify-config-invariants`
- `make -C arch/android preloaded-store-reproducibility`
- Android unit tests and lint
- `make -C arch/android android-build`
- `ANDROID_SERIAL=emulator-5562 make -C arch/android smoke`
- `ANDROID_SERIAL=emulator-5562 make -C arch/android scenarios`
- `ANDROID_SERIAL=emulator-5562 make -C arch/android android-zone-storage-smoke`
- `ANDROID_SERIAL=emulator-5562 ./scripts/smoke.sh android`
- dedicated tunnel smoke using the peer's live trusted tunnel implementation
  `w1nxNAXJy0i-5ZZixUlzj0R2a99y_r8O8z3bFuGBxe8`; all local/public address,
  info, and status probes returned HTTP 200 on their first attempt. Transcript
  SHA-256: `674455576081a8f5cf03bc66b885eb771d097bccb6e342feb3760f0472f434ad`.
- `ANDROID_SERIAL=emulator-5562 BUILDROOT_VOLUME=lapee-andock-arm64-release-buildroot
  BUILDROOT_CONTAINER=lapee-andock-arm64-release-buildroot-build TIMEOUT=3600
  ./scripts/smoke.sh mixed` — exit 0. Two x86_64 LapEE QEMU nodes booted from
  a clean dedicated Buildroot image, QEMU node 1 performed the real
  `~measurement@1.0/verify-peer` preflight, AndEE joined through QEMU node 1,
  and all three members produced ring-signed membership proofs. Ring address:
  `FqYFEvtSADieRpNYdFQSLE-fc1LghmDolMqo7_QF9-0`. Transcript SHA-256:
  `2f3396ce3520ac1f06cbc8cf3a9f2822b8f81779fb33d8f544907121174f1648`;
  summary SHA-256:
  `11f12a42672e28e2977b179b2370c1ada5a78f5e959fffa03f101f7c4be2ae0e`.

The first exact invocation exposed that the checked-in external fixture was
stale; a second diagnostic that changed only the expected remote pin reached
the public path but paired it with the old local archive and returned an
incomplete public info document. The accepted run selected the one current
implementation at both trust boundaries. The script defaults now match that
live trusted id, without importing unrelated tunnel source. The diagnostic
attempts and passing output are frozen under
`arch/android/build/evidence/final-unattended/image-13-final-gates/`.

## Scope and remaining work

The recursive deep-clean/security audit removed an insecure temporary browser
DELETE route from the Ouroboros patch; unsigned identity hints can no longer
trigger a node-wallet-signed destructive action. Authentication redesign and
the pre-existing invite wallet-hint authorization behavior are explicitly
deferred to the separate auth effort.

Every emulator and mixed-platform gate is green. The final diff, secret,
branch, exact-artifact, and status audits are green, and the release commit is
the commit containing this ledger. Exact install/config/forward, Andock
workload, browser-acceptance, force-stop, and recovery commands for the real
phone are frozen in
`arch/android/build/evidence/final-unattended/REAL-PHONE-HANDOFF.md`.
The only external release gate is that real unrooted ARM64-phone run.

No publication consumed AR. All required portable-device/UI uploads used the
subsidized `up.arweave.net` bundler; the authorized wallet balance remained
exactly zero before and after, so 0 of the 5 AR ceiling was spent.
