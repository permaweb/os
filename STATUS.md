# Andock ARM64 final-release ledger

Updated: 2026-07-17 America/New_York

This file is the authoritative state reminder for unattended work. Re-read it
after every compaction and update it after every material validation or design
change.

## Commander's intent

Finish a maintainable, least-surprising Linux execution environment for
ordinary unrooted ARM64 Android phones, validate it on the owned ARM64
emulator, consolidate each repository to one canonical delivery branch, and
leave the frozen build ready for real-phone acceptance.

The guest experience must remain interchangeable with Ouroboros
`~docker@1.0`: the seven `read`, `write`, `append`, `edit`, `glob`, `grep`, and
`bash` tools, a mutable root filesystem, normal package managers, native
toolchains, Python/venv/pip, Node/npm/node-gyp, persistence, stop, destroy,
timeouts, output clipping, serialization, and host-controlled network policy.

Performance is imperative. Storage deduplication is optional. V1 therefore
gives each member one complete writable sparse ext4 image rather than an
overlay or per-path Binder filesystem.

## Canonical branches and scope

- LapEE/AndEE:
  `/Users/sam/.codex/worktrees/lapee-andock-arm64-release`, branch
  `agent/andock-arm64-release`, current reviewed source checkpoint
  `ebbae846` plus this status-ledger update.
- Ouroboros:
  `/Users/sam/.codex/worktrees/ouroboros-andock-backend`, branch
  `agent/ouroboros-andock-backend`, commit
  `a4c3b874178e30e0c1df028f069913c579bb22f4`.
- HyperBEAM is a pinned substrate at exact edge
  `fcdf5867686c64a8abe79e04e10f3590fbd62b7f`; no upstream HyperBEAM worktree
  is edited by this task.
- The shared dirty `/Users/sam/src/lapee` and `/Users/sam/src/ouroboros`
  checkouts are never edited or reset.
- No push, merge to `main`, Arweave publication, production change, or wallet
  spend has occurred.

Read-only ancestry reconciliation proved the two canonical branches already
contain the desired component work. Do not merge the parked measurement,
directory-capability, app-broker, old QEMU/PRoot, or auth-divergent histories.
Keep parked branches/worktrees as recovery evidence until real-phone
acceptance; they are not competing delivery branches.

Authentication, bearer/session policy, wallet identity, provider policy, and
member authorization redesign are explicitly outside this filesystem/runtime
port. Normal private HyperBEAM configuration is passed through unchanged.

## Security and architecture contract

The security boundary is Android's isolated worker UID, SELinux domain, and
explicitly brokered Binder/file capabilities. PRoot supplies Linux path and
syscall compatibility inside that boundary; PRoot itself is not claimed as a
sandbox.

Each worker receives only:

- one member-specific writable ext4 image descriptor;
- the immutable native/runtime artifacts needed to execute it;
- a command channel; and
- an outbound network capability only when the request enables networking.

The guest must not receive the application root, another member image, the
node wallet, provider credentials, effective node config, APK-private keys,
crypto-agent socket, or arbitrary Android storage. Network denial is enforced
by withholding the brokered network capability, never by inspecting command
strings.

The selected V1 architecture is documented in
`decisions/andock-filesystem-capability.md`. Rejected approaches are the old
per-path Binder filesystem, app-broker PRoot prototype, directory-FD pseudo-
chroot, desktop QEMU/TCG for production phone workloads, and AVF as a retail
baseline.

## Implemented release surface

- Deterministic pinned Ubuntu 24.04 ARM64 template with the same general
  operator/tool expectations as the Ouroboros Docker base.
- Complete writable member images created by sparse extent-preserving copy.
- In-process lwext4 engine with open-description/inode identity, metadata,
  xattrs, directory operations, links, locks, mmap, sync, sparse I/O, and Unix
  socket semantics.
- PRoot syscall adapter with synthetic bounded `/proc`, `/dev`, `/sys`, and
  proc-fd identity behavior needed by modern native tools.
- Correct seccomp acceleration with synthetic-result state scoped per syscall.
- Android isolated-worker lifecycle, admission limits, per-member
  serialization, stop, destroy, restart persistence, and orphan prevention.
- External network capability broker covering IPv4, IPv6, UDP, DNS,
  subprocesses, copied binaries, local addresses, listeners, and Unix sockets.
- Generic local transport consumed by portable Ouroboros `~andock@1.0`.

The latest hardening checkpoint adds cached-inode lifetime correctness,
descriptor-exhaustion prevention, executable mapping safety, virtual mode and
timestamp handling, `fchmodat2`, durable close/fsync/fdatasync/munmap behavior,
Unix datagram source detranslation, ADB shell quoting, deterministic template
metadata, and expanded emulator workloads.

## Measurement decision

Do not change `~measurement@1.0`, `~andee@1.0`, or `~system@1.0` for Andock.
Existing measured facts already commit the APK set, signing certificate,
runtime ZIP, native-library set, and ordinary node configuration selecting the
execution device. The immutable template and manifests are inside the runtime
ZIP; native PRoot/launcher artifacts are inside the measured native-library
set. Mutable member images are correctly outside measurement.

The rejected `agent/andock-measurement` branch describes the obsolete app
broker and must not be merged. See `decisions/andock-measurement.md`.

## Frozen emulator-candidate artifact identities

These hashes describe the replacement build from `ebbae846`, including the
closed native-input manifest and `andock-image-4` toolchain revision. The
clean-install smoke rejected this candidate before `/usr/bin/env` could start:
carrier memfd duplication returned `EACCES`. Keep the identities as failed
candidate evidence; they are not the real-phone handoff artifacts.

- Debug APK:
  `b80c740ba436f040a52d729a24d20edcb2d9605da8b0ec022a3bf9d3bf166c51`
- Runtime ZIP:
  `7bdf69571db48d9771911d9a665003726ec0abd47961d56f9c2e45ed96dab15f`
- Native Andock/PRoot:
  `60dbfc507e6846630120b493248ae1426739292c4289cfe9dc8804e622648b3a`
- Native Andock launcher:
  `85f716390b1a9fb37e8b6a7830acb1272d1afc7c7af3a0eeed78ed2f2d5a6453`
- Native PRoot loader:
  `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`
- Raw template:
  `e468693573fcf162ddbe6d0e8ffdf3ff2e07992a3e2f7387017b342f6df9423c`
- Android sparse template:
  `6f45382bd8c1c383860c75e92c801864832c1be680fc6ab04c969f21c4dbddb6`
- Metadata inventory:
  `4bb273ba4f81618fd8bcf99819770d633e11bddd43df704bea6a015b43cb5049`
- Inventory: 26,960 entries; raw/sparse allocated bytes:
  893,861,888 / 893,384,196.

Independent template builds produced byte-identical raw images, sparse
images, manifests, and inventories.

The runtime manifest records exact HyperBEAM
`fcdf5867686c64a8abe79e04e10f3590fbd62b7f`, toolchain revision
`termux-98046d2726d50e29e721e3535da85640bc4b804b+andock-image-4`, and the
template identities above. The source manifest contains
`execution/lwext4-data-extents.patch`; direct validation and the no-force
image builder both return success without rebuilding.

Clean-install result on `emulator-5562`: `andock-emulator-smoke.py` failed at
its first environment probe with
`materialize /usr/bin/env: memfd duplicate failed: Permission denied (-13)`.
This is a newly exposed carrier-access hardening regression and invalidates
the replacement candidate until fixed, rebuilt, and rerun.

The repair keeps per-open access in the tracked Linux description on Android,
where SELinux intentionally denies `/proc/self/fd` reopening, and adds an
immutable write-permission bit to every shared mapping so `mprotect` cannot
upgrade a read-only description. Linux hosts retain narrowed kernel-mode
carriers. The replacement native revision is `andock-image-5`.

## Validated evidence

Completed before the current continuation:

- final-source host image-engine suite: passed;
- `make -C arch/android android-build`: passed;
- clean-install `ANDOCK_EMULATOR_SMOKE_OK`: passed;
- deterministic template reproducibility/manifest validation: passed;
- alternating GCC/G++ loader regression: 20 consecutive cycles passed;
- compiled Unix/network boundary and Linux file-syscall probes: passed;
- persistence across graceful stop/restart and abrupt force-stop: passed;
- exact HyperBEAM fcdf common/Android device tests and Android/Linux packaging
  gates: passed; and
- static Python, shell, credential, architecture, dependency, and
  `git diff --check` audits: passed.

Final-candidate workload evidence passed APT/toolchains, system and venv pip,
native Python wheels, Node/node-gyp, 10,000-file create/traversal, Git,
SQLite/archives, IPC/mmap, Unix sockets, file syscalls, network denial,
CPU-only PyTorch, Transformers, tensor operations, and offline loading of
`hf-internal-testing/tiny-random-bert`.

Observed performance:

- warm commands: about 0.23 seconds;
- CPU-only PyTorch install: 86.497 seconds after the durable-close fix,
  versus 101.511 seconds before it;
- Transformers install: 69.629 seconds;
- warm ML composite: 16.6--16.9 seconds;
- isolated member clone plus first `true`: 0.636, 0.700, and 0.757 seconds.

The workload gates are 95 seconds for CPU-only PyTorch install and 20 seconds
for the composite. A tested 16 MiB lwext4 cache and session writeback did not
improve extraction and were removed rather than retained as complexity.

## Current unattended execution

Owned target: `emulator-5562`, AVD `codex-handee-4g`, ARM64, Android 16/API
36, enforcing SELinux, 4 GiB RAM. The unrelated `emulator-5554` and its node
belong to another agent and must not be touched.

The owned emulator was cold-started after the laptop connection recovered.
The frozen APK was uninstalled/reinstalled and passed
`ANDOCK_EMULATOR_SMOKE_OK`. Host access to PyPI and the official PyTorch CPU
index is healthy. The complete clean-member workload passed every filesystem,
package-manager, compiler, Python, Node, ML, and Hugging Face stage. It stopped
at the public-network probe after IPv4 DNS resolution when the first HTTPS
request transiently returned exit 1. Immediate isolated reruns of both direct
HTTPS and HTTP-to-HTTPS redirect requests against the same member passed. This
is recorded as a real incomplete gate, not a product pass; the public-network
probe will be repeated with stage-labelled output on the rebuilt candidate.

Current evidence root:
`arch/android/build/evidence/final-unattended/`.

Latest complete-run observations include APT 334.069 seconds, toolchains
25.738, system pip 11.634, venv 14.874, native wheel 15.950, Node addon
68.106, 10,000-file create 17.750, traversal 1.838, Git 43.915, SQLite and
archives 66.194, PyTorch 87.189, Transformers 64.988, and warm ML composite
16.628/16.844/16.841 seconds.

## Current hardening audit and repair

The recursive adversarial review found no demonstrated escape from the
isolated Android UID/SELinux/Binder boundary, but it did find release blockers
inside the guest compatibility layer:

- materialized memfds were always reopened read-write, so requested access
  modes were not enforced at the kernel descriptor boundary;
- legacy asynchronous I/O and `SCM_RIGHTS` could bypass mutation/accounting
  unless denied or mediated;
- writable-mapping lifetime was a one-way boolean and retained one memfd for
  every inode ever mapped in a command;
- sparse guest files were materialized and written back proportional to their
  logical size;
- member creation and image writeback lacked an explicit Android-host free
  space reserve;
- `listxattr` filtering and fake-root ownership limitations need exact tests
  and documentation; and
- public IPv6/NAT64 behavior remains a real-phone acceptance item.

All known code-level hardening blockers are now integrated on the canonical
branch:

- `b910b845`: extent/range-aware sparse materialization and writeback, a
  512 MiB Android-host free-space reserve, and filtered `user.*` xattr tests;
- `9b5c3817`: kernel-enforced carrier access modes plus fail-closed legacy AIO
  and ancillary descriptor transfer; and
- `0a238e9a`: range/refcount tracking across mmap, munmap, mprotect, mremap,
  fork/CLONE_VM, exec, and exit.

The combined host image-engine, mapping-interval, network-client, launcher,
and Android unit suites pass. The image regression proves a 512 MiB logical
sparse file persists with ext4 Blockcount 144 (gate at most 192) after restart.
The combined mapping tracker also passes Linux ASan+UBSan with leak detection.
The integrated ARM64 PRoot and APK build passed from clean pinned sources.
Its deep-clean manifest audit found that the new sparse extent visitor patch
was not enumerated in the reproducibility manifest. The manifest now hashes
all `lwext4-*.patch` inputs by construction and bumps the native toolchain
revision to `andock-image-4`. The replacement build passed, its manifest
validated, and its no-force native-image build correctly recognized the
artifacts as current.

The emulator Linux-syscall workload now also proves `user.*` xattr
set/get/list/remove behavior, rejects privileged xattr writes, and records the
documented fake-root ownership semantics.

The decision record was reduced from the stale feasibility plan to the actual
accepted architecture. It now states fake-root and `user.*` xattr limits, the
network-enabled adapter trust, host reserve, sparse writeback, current emulator
thresholds, and the real-phone IPv6/NAT64 gate. README/specification text now
matches that contract.

## Portable Ouroboros state

`agent/ouroboros-andock-backend@a4c3b87` directly contains the clean pre-auth
portable branch `agent/ouroboros-portable-scoped@20b2930` plus one standalone
`~andock@1.0` commit. The device delegates the seven tools, file browsing,
validation, clipping, serialization, and errors to the existing shared
`lib_ouroboros_execution` contract. Its only private mechanic is the
fail-closed local Android transport.

Do not merge `origin/main`, `agent/ouroboros-portable-audit`,
`agent/ouroboros-portable-devices`, or
`agent/ouroboros-portable-integrated`; they diverge at the clean pre-auth base
and include authority/router publication work reserved for the separate auth
effort.

Independent final validation passed `npm ci`, static typecheck/router/build,
HyperBEAM compile, 14/14 focused unit tests, eight package archives, 253/253
packaged-device tests, and 433/433 combined tests. Commit `a4c3b87` also makes
the main archive fail if it accidentally embeds Andock and records the current
archive/test counts. Current package hashes are:

- `ouroboros@1.0`:
  `40eafaa3fb9fda14cb04d219067e2805b7d928731e648ebb13959a39fb17aa6e`;
- `andock@1.0`:
  `6be0ca08e0ff5fb893e8bd039954aa5cd0eeda70d9cf8e6f22dffc40dd0178b5`.

No current Arweave publication is required for code validation. If a real upload becomes
strictly necessary, `/Users/sam/src/hyperbeam-key.json` is authorized with a
hard cumulative ceiling below 5 AR; spending and transaction IDs must be
recorded here.

## Remaining acceptance gates

1. Fix the clean-install carrier duplication regression, rebuild, and repeat
   the complete workload on the new frozen build, including
   the labelled public network stage, and record its JSON/log evidence.
2. Run the complete AndEE release ladder on `emulator-5562`:
   config invariants, Android build, smoke, scenarios, Android zone storage,
   root Android smoke, and mixed smoke with real measurement peer preflight.
3. Run the recursive deep-clean/adversarial security review and repeat every
   affected gate after any code change.
4. Validate the portable Ouroboros packages and `~andock@1.0` on the frozen
   AndEE runtime, including a real provider-backed agent flow and browser UI
   when locally possible without public publication.
5. Confirm both canonical worktrees are clean and commit coherent final
   checkpoints.
7. Freeze the APK, config, evidence bundle, exact phone commands, and expected
   URLs for real unrooted ARM64-phone acceptance in the morning.

Do not declare release completion until the real phone passes. The unattended
stop condition is instead a clean, fully emulator-validated, one-branch-per-
repo handoff ready for that phone gate.
