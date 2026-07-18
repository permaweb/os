# Andock ARM64 final-release ledger

Updated: 2026-07-18 America/New_York

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
  `agent/andock-arm64-release`, current committed source checkpoint
  `d1eef33bf313159f7fd834ba624a3f73a8152cc6` plus the active runtime
  reproducibility repair recorded below.
- Ouroboros:
  `/Users/sam/.codex/worktrees/ouroboros-andock-backend`, branch
  `agent/ouroboros-andock-backend`, commit
  `58e2312c442b9a8056c4d298994179d106713c86`.
- HyperBEAM is a pinned substrate at exact edge
  `fcdf5867686c64a8abe79e04e10f3590fbd62b7f`; no upstream HyperBEAM worktree
  is edited by this task.
- The shared dirty `/Users/sam/src/lapee` and `/Users/sam/src/ouroboros`
  checkouts are never edited or reset.
- No push, merge to `main`, production change, or wallet spend has occurred.
  The five portable Ouroboros roots required by the Andock composition were
  published through the subsidized `up.arweave.net` bundler; the signer wallet
  balance remained zero before and after, so the authorized 5 AR budget is
  untouched. Exact ids are recorded in the Ouroboros `STATUS.md`.

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

## Failed emulator-candidate artifact identities

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

## Rejected image-5 emulator-candidate artifact identities

The rebuild from `3e3a16af` completed successfully and passed its clean-install
smoke, but the complete clean-member workload rejected it during the expanded
Linux syscall probe:

- Debug APK:
  `da1595a4aaf64a5609bff90e5d1774a1e79aa1e0fa4cacf4e2593ce6209c2616`
- Runtime ZIP:
  `0214bda8c3db865bae897df24881563c10c825e2c25a831dd86b3b29245d9eb7`
- Native Andock/PRoot:
  `3bb4c85c3fceaa405683c88f7f5135c94d67f8d946749eea2d5357b0305ae924`
- Native Andock launcher:
  `85f716390b1a9fb37e8b6a7830acb1272d1afc7c7af3a0eeed78ed2f2d5a6453`
- Native PRoot loader:
  `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`

The raw template, sparse template, and inventory remain the byte-identical
identities above. The runtime manifest records exact HyperBEAM `fcdf5867`,
native revision `andock-image-5`, and all template/native digests. Direct
manifest validation and the no-force image builder both pass.

The exact APK was uninstalled/reinstalled from a clean app state on
`emulator-5562`; `andock-emulator-smoke.py` completed with
`ANDOCK_EMULATOR_SMOKE_OK`. This specifically closes the image-4 launch
regression and proves the Android runtime denies read-only write, shared
writable `mmap`, and later writable `mprotect` upgrades. It is not the final
handoff APK because fake-root permission emulation subsequently masked an
Andock xattr denial.

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
Image 5 was uninstalled/reinstalled and passed `ANDOCK_EMULATOR_SMOKE_OK`.
Its clean-member workload then passed through APT, toolchains, system/venv
pip, native wheels, Node/node-gyp, 10,000 files, Git, SQLite/archives, IPC,
mmap, and Unix sockets before `linux-file-syscalls` failed: the engine denied
`security.andock` with `EPERM`, but PRoot's later `fake_id0` exit hook changed
that permission failure to success for the emulated root user. The attribute
was not stored, making the result a misleading success rather than a policy
escape. The exact failed workload JSON and console log are retained as
`image-5-workload` and `image-5-workload-log/console.log`.

The image-6 repair converts every negative Andock syscall-enter result into a
synthetic guest errno before a host syscall or `fake_id0` can observe it, and
similarly makes exit-time Andock failures final. Direct engine tests now deny
privileged set/remove operations, while the emulator workload covers both path
and descriptor xattr calls. The host engine, mapping, network-client, and
launcher suites pass after the repair. The image-6 native build, runtime
assembly, and APK build completed successfully. Its no-force native builder
recognized the pinned output as current and direct template validation passed.

Image-6 candidate identities:

- Debug APK:
  `4b058ade64c47325fd29a71752d02799383b2f65e62652e4e4be7fa7466425d0`
- Runtime ZIP:
  `7ef68f4543b5615acc1fef514f314c8bd2d5fafc0ef46f110ef6b233cc176208`
- Native Andock/PRoot:
  `d041ec1959ff4850cee452592d420e5a5b91d9963d1ba4e7ef09e7dc5ee6667f`
- Native Andock launcher:
  `85f716390b1a9fb37e8b6a7830acb1272d1afc7c7af3a0eeed78ed2f2d5a6453`
- Native PRoot loader:
  `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`
- Runtime manifest:
  `21b999e8dd8a555ab4220fb8db487c7406367658274de865a9688b92418cfac2`
- Native manifest:
  `a534bdd40c1a3a5ac7f32985bb8668f48f4ab42badde3cca6be3ac08a962b62c`

The runtime manifest records exact HyperBEAM `fcdf5867`, native revision
`andock-image-6`, and the unchanged deterministic template identities. A clean
install passed `ANDOCK_EMULATOR_SMOKE_OK`, and focused path and descriptor
privileged-xattr probes returned exact `EPERM`. The complete clean-member
workload passed through Unix sockets before rejecting the candidate at the
expanded xattr removal assertion: `removexattr("user.andock")` reported success
but the attribute remained visible. These hashes are therefore rejected
candidate identities, not frozen release identities.

The failure reduced to a one-syscall lwext4 defect. Its inline-xattr removal
branch passed `block_finder.s` to `ext4_xattr_set_entry` even though that
uninitialized finder is used only for external xattr blocks; the correct
inline state is `ibody_finder.s`. The image-7 patch corrects that pointer,
tests allowed removal in the direct engine, and asserts exact privileged
denial in parent, child, and grandchild guest processes. The repaired host
engine, mapping, network-client, and launcher suites all pass, including the
allowed-removal regression and sparse Blockcount 144 gate.

Image 7 rebuilt from the complete pinned source set and its no-force builder
and template validator both pass. Candidate identities are:

- Debug APK:
  `310f1cd0adc38acaafa3431b61f7f5845c9c9631fb7d7e312d8e60862ee68cf0`
- Runtime ZIP:
  `f9dabaccb42ace5b530def52e669068dc7b05003fa832886a7fea83bf05466ea`
- Native Andock/PRoot:
  `51dcc670e50c30635dbcece938448ad1980ca67d3b9b17a409fd06ce96a65eeb`
- Native Andock launcher:
  `85f716390b1a9fb37e8b6a7830acb1272d1afc7c7af3a0eeed78ed2f2d5a6453`
- Native PRoot loader:
  `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`
- Runtime manifest:
  `cadbcfc0a625a5d2b1f97e7985769df70888fcd544bbf03d21b7fa390c882f59`
- Native manifest:
  `cd65a1eb0b3bc70acfb639f9c98b195bde845507bfdfb10144fc746a4a7b8b2d`

The runtime records exact HyperBEAM `fcdf5867`, native revision
`andock-image-7`, and the unchanged deterministic template identities. Its
clean install, focused Linux-semantics probe, and two complete filesystem and
ML workload passes succeeded through xattr removal, inherited privileged
denials, package managers, toolchains, PyTorch, Transformers, and Hugging Face.
Both runs then failed the final combined public-network assertion after about
seven seconds. Splitting that assertion into independently reported probes
identified the deterministic cause: `dig` explicitly binds a UDP socket to a
wildcard ephemeral address before sending, while image 7 denied every Internet
socket `bind(2)`. HTTPS, redirects, copied curl, subprocess curl, and 20/20
fresh HTTPS plus direct-IPv4 repetitions all pass. Image 7 is therefore a
rejected candidate despite its otherwise green workload.

Image 8 permits only UDP wildcard port-zero client binds on brokered Internet
sockets. Concrete local addresses, fixed ports, TCP binds, and all listeners
remain denied; network-disabled workers still cannot create Internet sockets.
The direct syscall regression covers IPv4 and IPv6 ephemeral UDP binds and
assigned ports, IPv4 and IPv6 non-wildcard/fixed-port rejection, TCP bind
rejection, and listener rejection. Public-network workload probes are split so
HTTPS, redirects, copied binaries, subprocesses, and raw UDP DNS each produce
independent evidence.

The pinned image-8 ARM64 native rebuild, no-force manifest check, runtime
assembly, and APK build pass. Candidate identities are:

- Debug APK:
  `c9a548f8acf4b643c464f1623d8d251bdd99baeb414d1ed9cc039f3fe2f8a3fc`;
- Runtime ZIP:
  `86164ea3ab017248c9b88a9de57282d2540a2954cbb4d374cef5e43e07ec551c`;
- Native Andock/PRoot:
  `6e1b9dbbd6753cacd1b48c3eb9647b2210cdc130b1544cc9a4cdc9b5b4d8964b`;
- Native Andock launcher:
  `85f716390b1a9fb37e8b6a7830acb1272d1afc7c7af3a0eeed78ed2f2d5a6453`;
- Native PRoot loader:
  `44ef39c1e1a18c09f6e4c4b5d6f8bba82d30596598bd155ec162d05c5122ff04`;
- Runtime manifest:
  `74e2c19631c2d5db83eb1ac9bba16d4c9b39ec9fc47d784160076d77b6d26fcb`;
- Native manifest:
  `6e38f39dc4ff136d966d44597afcb87019b989c6e9116526c8b7fd19be60294d`.

The runtime records exact HyperBEAM `fcdf5867`, native revision
`andock-image-8`, and deterministic template image
`e468693573fcf162ddbe6d0e8ffdf3ff2e07992a3e2f7387017b342f6df9423c`.
A clean install on the owned ARM64 API-36 emulator passed
`ANDOCK_EMULATOR_SMOKE_OK`. The focused network gate then installed BIND,
completed real `dig` UDP DNS, allowed only a UDP wildcard port-zero bind,
denied TCP bind, and proved a network-disabled process could not create the
UDP socket. The first complete clean-member run passed through APT, all
toolchains, Python installs, Node/node-gyp, 10,000 files, Git, SQLite/archives,
IPC/mmap, Unix sockets, and file syscall semantics before stopping on a test-
only compile error in the newly expanded TCP-bind assertion. The helper name
was corrected to a direct `socket(AF_INET, SOCK_STREAM, 0)` call. The retained
member then compiled and passed the exact expanded native boundary with
`ANDOCK_NETWORK_SYSCALLS_OK`, including the loopback race check. A complete
from-zero rerun then passed all 36 stages in 930.395 seconds with
`ANDOCK_EMULATOR_WORKLOADS_OK`. It included APT, C/C++/CMake/Go/Rust/Java,
system/venv/native-wheel Python, npm/node-gyp, 10,000 files, Git,
SQLite/archives, IPC/mmap, Unix sockets, Linux file semantics, the expanded
network syscall boundary, CPU-only PyTorch, Transformers, a downloaded
Hugging Face model, five independent public-network probes, local/disabled
denial, Android force-stop, and complete member persistence. Exact final-run
observations were APT 344.173 seconds, PyTorch install 88.999, Transformers
66.225, warm ML 16.944/16.649/16.145, and raw UDP DNS 0.533. Evidence hashes:

- result JSON:
  `ad60f00e9c83d4abb5ec3b96e4342eaae004f01f8afafd6c7921970537c4cbbd`;
- console log:
  `d887a5406d844b182c8c8c428ff74661e0f0c5b3ebed8aa6907cb3ef740ad73b`.

The retained member remains available only for the following measurement and
destroy checks. The ordinary AndEE release ladder is now in progress.

Current evidence root:
`arch/android/build/evidence/final-unattended/`.

## Runtime reproducibility repair

The first rebuild after committing image 8 produced different APK and runtime
ZIP hashes even though every Andock native/template input was unchanged. A
complete nested-entry comparison proved that the APK differed only in
`assets/andee-runtime.zip`; inside the runtime, 983 entries differed only in
ZIP timestamps and one entry differed in content:
`_build/preloaded-store/data.mdb`. The preload index changed from
`lFJng7...` to `jJmlTbl...`, while both stores were signed by the same
committer `tcgmDOKu8j31GZyrAXnsFCUEz0R3tpLDs9WfZMmVT3U`.

The semantic cause is Forge's RSA-PSS preload signature: PSS salts are random,
so the same wallet and source correctly produce different commitment IDs.
Using a deterministic Ed25519 build identity made every specification,
implementation, and index ID stable. LMDB's asynchronous insertion schedule
still produced different page layouts, although `mdb_dump` proved the key/value
sets byte-identical. A sorted semantic dump/reload through the exact pinned
`lmdb-sys 0.8.0` source made the database byte-identical as well.

The active packaging repair therefore:

- derives a documented public Ed25519 preload-only build key from a fixed seed;
- asserts signer `cbfIwVIoLq4Q2F9dzmgh66z4ri_KT-Re2CGoqH0DKHk`;
- canonicalizes the LMDB through pinned semantic dump/load tools;
- records the signer, algorithm, canonical format, LMDB crate checksum, and
  store digest in the runtime manifest; and
- normalizes runtime file timestamps and ZIP entry order/metadata.

The build identity is not an authorization root and is never packaged. Trust
remains the measured APK/runtime. The new standalone regression built two
preloads from identical inputs and passed with byte-identical SHA-256
`33141c89a87b593ff9b620b7aad7847f1af0041012a71a2e00be37b428b6599c`.
Two complete runtime/APK builds then passed byte-for-byte comparison:

- APK: `a41742675818087db0c479c9142d40b403bd3c5ddd42d478bda752395547a681`;
- runtime ZIP:
  `cdc6db974c01927c3fb7006815aa0866d11734b7b072a0f58f8478ad221ca152`;
- runtime manifest:
  `bea677bfcb1f0b9fafafd2d5ca038c1f868949b25b7c12743f9db9685d2146a9`.

The final cleanup made the timestamp conversion portable and made the
standalone target always restage its inputs. Repeat the exact-artifact build
after committing that cleanup, then clean-install it for emulator validation.

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
- `9b5c3817` plus `3e3a16af`: narrowed Linux carrier access modes, logically
  enforced Android open modes and immutable mapping write permission, plus
  fail-closed legacy AIO and ancillary descriptor transfer; and
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
revision to `andock-image-4`. The first replacement exposed Android's intended
SELinux denial of `/proc/self/fd` reopen; `3e3a16af` corrected that design and
bumped the revision to `andock-image-5`. Its replacement build passed, its
manifest validated, and its no-force native-image build correctly recognized
the artifacts as current.

The emulator Linux-syscall workload specifies `user.*` xattr
set/get/list/remove behavior, privileged-xattr rejection, and the documented
fake-root ownership semantics. Image 5 exposed that its privileged rejection
was masked; image 6 must pass this probe before those semantics are claimed.

The decision record was reduced from the stale feasibility plan to the actual
accepted architecture. It now states fake-root and `user.*` xattr limits, the
network-enabled adapter trust, host reserve, sparse writeback, current emulator
thresholds, and the real-phone IPv6/NAT64 gate. README/specification text now
matches that contract.

## Portable Ouroboros state

`agent/ouroboros-andock-backend@58e2312` directly contains the clean pre-auth
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

The five transitively required roots were published from the exact scoped
branch through `up.arweave.net` with signer
`1tAG04TLl8Wg2GXPm4gvqexkBqnem0_o44Q0OUtWdow`. All ten specification and
implementation ids returned HTTP 200 from `arweave.net`; publication logs and
the authoritative resolver ids are in the Ouroboros worktree under
`.run-data/final-publication-5/` and in its `STATUS.md`. Docker, QEMU, and
standalone WeaveMail were deliberately not published because the selected
composition does not require them.

## Remaining acceptance gates

1. Prove two complete runtime/APK builds are byte-identical after the active
   preload and ZIP reproducibility repair.
2. Clean-install that exact final APK and rerun the complete image-8 workload,
   including raw UDP DNS through the narrowly permitted client bind.
3. Run the complete AndEE release ladder on `emulator-5562`:
   config invariants, Android build, smoke, scenarios, Android zone storage,
   root Android smoke, and mixed smoke with real measurement peer preflight.
4. Run the recursive deep-clean/adversarial security review and repeat every
   affected gate after any code change.
5. Validate the portable Ouroboros packages and `~andock@1.0` on the frozen
   AndEE runtime, including a real provider-backed agent flow and browser UI
   when locally possible without public publication.
6. Confirm both canonical worktrees are clean and commit coherent final
   checkpoints.
7. Freeze the APK, config, evidence bundle, exact phone commands, and expected
   URLs for real unrooted ARM64-phone acceptance in the morning.

Do not declare release completion until the real phone passes. The unattended
stop condition is instead a clean, fully emulator-validated, one-branch-per-
repo handoff ready for that phone gate.
