# Andock isolated filesystem capability

Status: implementation plan; supersedes the per-path Binder filesystem design
in `agent/andock-1.0`.

## Objective

Provide a persistent Ubuntu-compatible execution environment to each Andock
member on an ordinary unrooted ARM64 Android device while preserving the real
Android security boundary and removing the synchronous host round trip from
guest filesystem operations.

The result must feel close to the Ouroboros Docker environment for package
managers, language runtimes, compilers, Git, and ordinary shell tools. Passing
functional smoke tests is not sufficient: metadata-heavy work must remain
usable after the member has installed a realistically large toolchain.

## Evidence forcing the redesign

The current prototype stores the immutable base and writable overlay as
app-private host directories. An isolated worker cannot traverse those paths,
so PRoot forwards guest path operations through a local socket, an isolated
service bridge, Binder, and the main-app Kotlin broker.

On the Pixel 10 Pro Fold, a cold ARM64 CPU PyTorch install took roughly twelve
minutes. The identical command completed in 12.014 seconds in a fresh native
ARM64 Ouroboros Docker container on the development laptop. After installation,
this command took roughly three minutes on the phone and 0.899 seconds in the
container:

```sh
python3 -c 'import torch; print(torch.__version__)' 2>&1
pip3 show torch 2>&1 | head -5
du -sh /root/.local 2>/dev/null
```

The phone spent more than two minutes in `du` over about 13,000 files. The
Android log buffer also contained 5,448 audited `TCGETS` denials against
brokered regular files. The denial storm is a concrete bug to remove, but the
per-path synchronous boundary is itself unacceptable.

## Security boundary

PRoot is not and must not be treated as the sandbox. The sandbox is the
kernel-enforced Android isolated UID plus its SELinux `isolated_app` domain.
Each active member receives a separate isolated process. That process has no
Android permissions and cannot traverse the AndEE app data directory.

PRoot, or a smaller replacement, supplies Linux ABI and pathname semantics:

- a conventional Ubuntu root;
- fake root identity where userland expects it;
- glibc executable and loader resolution;
- guest `/root`, `/usr`, `/etc`, `/var`, and `/tmp` behavior; and
- translation of guest pathname and metadata syscalls.

An Android application cannot rely on `chroot`, mount namespaces, unprivileged
user namespaces, or a FUSE mount on ordinary retail devices. Removing PRoot
without replacing those semantics would produce an Android/Bionic tool
environment, not the Docker-compatible Linux contract.

## Target capability model

The main app owns immutable assets and opaque mutable member files. At worker
creation it opens only the selected member's filesystem capabilities and
passes those descriptors once to the isolated service:

1. a read-only immutable base capability;
2. a read-write mutable member capability;
3. the bounded command transport; and
4. network capability state, with Internet sockets brokered separately only
   when policy permits them.

Filesystem parsing, pathname resolution, copy-up, and mutation then occur
inside the isolated worker. No guest filesystem operation sends a host path to
HyperBEAM or the main Android app. The main app does not parse mutable guest
filesystem structures.

The guest tracee must not inherit the raw filesystem descriptors. They remain
owned by the isolated supervisor, marked close-on-exec, and explicitly closed
in the tracee before its first guest instruction. The tracee interacts with
the filesystem only through the local syscall layer. Even if it escapes that
translation layer, the kernel still confines it to the isolated UID and
SELinux domain.

## Execution admission boundary

The isolated UID protects Android and HyperBEAM from guest code; it does not
authorize access to an existing member filesystem. A caller must not be able
to select a member ID, manufacture a `member-context`, and invoke
`~andock@1.0` directly.

- The public Andock route rejects execution without a verified AO/HyperBEAM
  authorization produced by the configured workspace authority.
- The authorization binds the exact member ID, allowed operation, network
  policy, request body, lifecycle generation, and measured Andock subject.
- Authorization is checked before allocating a worker or opening a member
  image. Admin bypass, where configured, is explicit and measured.
- A valid wallet signature proves identity only. It does not create workspace
  membership, grant tools, or make another member's image addressable.
- The design uses normal HyperBEAM signatures and committed AO messages. It
  does not introduce a bearer secret, caller-supplied trusted JSON, or an
  AndEE-only authentication protocol.

The parked prototype's `member-context` tool-list check is contract-shape
validation, not an authorization boundary. It may be retained only after the
request has crossed the verified admission boundary above.

## Path safety invariants

The filesystem engine resolves guest paths by filesystem inode, never by
concatenating guest strings with an Android host path.

- `/` is a virtual root inode. `..` at that inode cannot move above it.
- Relative paths begin at an engine-owned directory handle representing the
  guest working directory.
- Absolute symlink targets restart at the virtual root, not the Android root.
- Relative symlink targets restart at the containing virtual directory.
- Symlink depth, component count, component length, and total path length are
  bounded before allocation or traversal.
- Embedded NUL, malformed encoding at protocol boundaries, invalid member
  identifiers, and unsupported inode types fail closed.
- Rename, link, unlink, and copy-up operate on parent inode handles. A path is
  revalidated at the mutation point rather than trusted from an earlier
  string-based check.
- Immutable-base inodes cannot be mutated. A write first produces a member
  copy-up or whiteout inside the mutable capability.
- Device nodes, host sockets, raw block access, and arbitrary descriptor import
  are not representable in the guest filesystem.
- `/proc` is synthetic and exposes no supervisor, image, command-transport,
  crypto-agent, or main-app descriptor.
- The worker receives no descriptor for the app data directory, another
  member, the effective node config, the node wallet, provider keys, the
  crypto-agent socket, APK-private state, or Android credential storage.

These invariants make a guest path traversal a lookup inside an opaque member
filesystem. There is no corresponding HyperBEAM-host path for `../` to reach.

## Feasibility sequence

Implementation begins with small evidence-producing spikes. None may weaken
the isolated UID or make app-private directories broadly accessible.

### 1. Directory-descriptor probe

Pass an `O_PATH` member-root directory descriptor to a minimal isolated native
helper and test `openat2`, create, rename, hard link, xattr, and unlink beneath
it. This determines exactly which operations Android SELinux and DAC permit on
a received app-data directory FD.

Accept this route only if all required mutations work without world-writable
host paths, policy changes, privileged grants, or access to a sibling
descriptor. Use `RESOLVE_IN_ROOT`, `RESOLVE_BENEATH`, `RESOLVE_NO_MAGICLINKS`,
and `RESOLVE_NO_XDEV` where the Android kernel supports them. A directory FD
fast path would be substantially smaller than a filesystem-image engine, so it
must be disproved before adding that machinery.

### 2. Local image-descriptor probe

If the directory-descriptor route fails, create a small filesystem image under
app-private storage, open it in the main UID, and pass only its FD to an
isolated helper. Cross-build candidate userspace filesystem libraries for
ARM64 Android and prove, inside the isolated process:

- superblock open and validation;
- directory lookup and enumeration;
- file create/read/write/truncate;
- rename, link, symlink, timestamps, modes, and `user.*` xattrs;
- crash, reopen, and consistency checking; and
- rejection of malformed or adversarial image metadata.

Compare `libext2fs`, `lwext4`, and any smaller maintained alternative on API
coverage, crash behavior, licensing, source maintenance, code size, and
measured performance. Do not select a library merely because it can read a
happy-path image.

### 3. Base-plus-member storage probe

Evaluate these representations in order:

1. filesystem-level clone/reflink of a raw immutable base, if `FICLONE` is
   available and reliable on both the emulator and representative retail
   storage;
2. a read-only base filesystem plus a writable userspace overlay; and
3. a bounded block-level copy-on-write layer below one filesystem engine.

A reflink-only implementation cannot be the general retail baseline unless a
clean unsupported-device failure or a tested portable fallback exists. A
custom copy-on-write format must include versioning, checksums, deterministic
recovery, bounded allocation, and fault-injection tests; a naive sparse-file
bitmap is not sufficient.

The spike ends with a short decision record containing cold creation time,
10,000-file traversal time, random and sequential I/O, image growth, restart
behavior, corruption handling, and exact device/kernel/filesystem facts.

## Implementation phases

### Phase 0: freeze and profile the prototype

- Keep `agent/andock-1.0` as evidence; do not build the redesign on its large
  broker commit.
- Add a reproducible performance workload containing 10,000-file `stat`,
  `find`, `du`, Python import, Node resolution, Git status, local wheel unpack,
  and sequential I/O.
- Add counters and latency histograms for PRoot stops, resolve/open/list,
  Binder transactions, FD transfers, copy-up, xattrs, and audited denials.
- Remove the repeated regular-file `TCGETS` attempt and remeasure so the design
  is not based on an avoidable logging pathology.

### Phase 1: isolated capability bootstrap

- Enforce the execution admission boundary before opening any filesystem
  capability; add direct-device, forged-context, replay, expired-generation,
  and cross-member denial tests.
- Define a minimal versioned Binder bootstrap used once per worker.
- Bind every capability to the exact member identifier, isolated UID, worker
  token, network policy, and lifecycle generation.
- Pass descriptors rather than paths or caller-controlled descriptor numbers.
- Make replay, cross-member reuse, stale-generation reuse, and duplicate active
  binding fail closed.
- Close every unrelated inherited descriptor before guest execution.
- Kill the complete process tree when the service, binder peer, app process,
  timeout, or command transport dies.

### Phase 2: local filesystem engine

- Implement inode-based lookup beneath the selected base and member
  capabilities.
- Implement complete regular file, directory, symlink, hard-link, rename,
  truncate, mode, timestamp, `statfs`, and `user.*` xattr semantics.
- Implement immutable-base fallback, copy-up, opaque directory/whiteout
  behavior, and atomic replacement without exposing internal overlay metadata
  in the guest.
- Preserve sparse files and bounded filesystem capacity.
- Serialize operations for one member while allowing independent member
  workers to overlap.
- Keep the mutable-image parser and all guest-controlled metadata inside the
  isolated process.

### Phase 3: PRoot integration and deletion of the host broker

- Retain only the PRoot syscall translation needed for Ubuntu compatibility.
- Dispatch filesystem operations directly to the local engine.
- Preserve executable loading, dynamic loader behavior, shebangs, `/proc`,
  pathname UNIX sockets, signals, process trees, and real timeouts.
- Delete the per-operation AIDL transaction, Kotlin path resolver, isolated
  socket-to-Binder bridge, host overlay-path translation, and corresponding
  frame protocol once parity is proven.
- Keep lifecycle and optional Internet socket brokerage as small, separate
  Android capabilities.

### Phase 4: package-manager parity

- Build the immutable filesystem from the same pinned declarative provisioner
  as the Ouroboros Docker base.
- Ensure `/usr`, `/etc`, `/var`, `/tmp`, and `/root` are writable through the
  member layer so `apt`, `pip`, npm, compilers, and source builds behave as
  root-oriented agents expect.
- Preserve standard Python behavior: system install policy, venvs, `--user`,
  local wheels, atomic rename, bytecode caches, native extensions, and normal
  `sys.path` discovery.
- Preserve Node package installation, executable shims, native addons, and
  module resolution without Andock-specific environment hacks.
- Do not preinstall PyTorch or add package-specific shortcuts to pass tests.

### Phase 5: lifecycle, capacity, and recovery

- Give each member a separately bounded mutable allocation and report that
  capacity through guest `statfs`.
- Reserve host free-space headroom so one guest cannot exhaust AndEE storage.
- Make stop preserve state, restart reopen the same member capability, and
  destroy remove only that member after all worker references are gone.
- Exercise app kill, service kill, low-memory kill, power-loss fault points,
  partial copy-up, incomplete rename, and full-storage behavior.
- Run consistency checking and deterministic recovery without parsing the
  mutable filesystem in the HyperBEAM process.

### Phase 6: measurement after the design stabilizes

Do not merge the current `agent/andock-measurement` projection: it names the
old `android-app-broker@1` design.

After the storage format and runtime are frozen, expose only verifier-relevant
immutable facts: device version, architecture, syscall layer digest, filesystem
engine/version, immutable base digest, provisioner revision, network policy,
and resource policy. Existing APK/runtime/config commitments remain primary.
Mutable member images, allocation state, and workspace contents remain outside
the boot measurement.

## Validation matrix

### Native and path correctness

- Table-driven and property tests for absolute/relative paths, repeated `/`,
  `.`, `..`, maximum lengths, Unicode, invalid byte sequences, and NUL.
- Symlink chains, cycles, dangling targets, absolute targets, relative targets,
  and rename races.
- Hard links, rename-over-existing, cross-directory rename, unlink-open files,
  sparse files, xattrs, timestamps, modes, and atomic replace.
- Mutation fault injection at every persistent write and recovery after
  process death.
- Fuzz filesystem images and syscall frames under ASan/UBSan on the host and
  the Android HWASan environment where available.

### Isolation and adversarial escape

From a real guest process, attempt to read or modify:

- the raw base/member descriptors through `/proc/self/fd` and inherited FDs;
- the parent or sibling Android app-data paths;
- another member's filesystem;
- the effective node configuration and imported private options;
- the node wallet and Android Keystore material;
- the crypto-agent socket;
- APK/runtime internals not intentionally present in the guest;
- `/proc/<hyperbeam-pid>`, `/proc/<other-worker-pid>`, and process memory; and
- arbitrary Android application data.

Repeat with `openat`, `openat2`, symlinks, hard links, rename, copied static
binaries, direct syscalls, subprocesses, SCM_RIGHTS, UNIX sockets, and malformed
filesystem metadata. Assertions must prove kernel denial, not merely absence
from a friendly path resolver.

### Network policy

With networking disabled, test IPv4, IPv6, TCP, UDP, DNS, redirects, Python
sockets, Node sockets, copied binaries, subprocesses, raw sockets, and descriptor
passing. With networking enabled, prove the same standard clients work. A
member cannot change its worker capability or receive another member's socket.

### Linux workload parity

Run from clean member filesystems and again after stop/restart:

- all seven execution operations and representative errors;
- `apt update` and pinned package installation;
- system pip, `--user`, venv, local wheel, native extension, and atomic install;
- pinned CPU PyTorch install, import, `pip show`, and filesystem traversal;
- Transformers/tokenizers installation and import;
- Node/npm, a large dependency tree, and a native addon;
- C/C++, Rust, and Go compile-and-run workloads where present in the shared
  Docker provisioner;
- Git clone/status/diff over a repository with thousands of files;
- SQLite, archives, audio file generation, binary and multi-megabyte files;
- concurrent different members and serialized operations for one member; and
- file browsing, attachments, archive creation, and download through normal AO
  and Ouroboros routes.

### Performance gates

Benchmark three clean runs and three warm runs on both the ARM64 emulator and a
real unrooted ARM64 phone. Record wall time, CPU time, RSS/PSS, bytes written,
filesystem growth, process state, syscall counts, and broker/capability counts.
Run native ARM64 Docker controls on the development laptop and keep package
downloads separate from local installation measurements.

Initial hard gates, subject only to tightening after the feasibility spike:

- ordinary warm command median no worse than 500 ms;
- 10,000-file metadata traversal no worse than 5 seconds;
- the post-install PyTorch import/show/`du` workload no worse than 10 seconds;
- local cached PyTorch wheel installation no worse than 60 seconds;
- no filesystem workload more than 5x its same-device local-engine control;
- no repeated SELinux denial/audit stream during a successful workload; and
- performance must not degrade materially after restart or as unrelated
  members accumulate state.

A test that merely raises the timeout is a failure. Package-specific
preinstallation, command detection, hidden host execution, or weakened
isolation cannot satisfy these gates.

### Android and AO integration

- Clean APK install and first boot on emulator and physical phone.
- Existing AndEE config invariants, Android build, smoke, scenarios, zone
  storage, Android smoke, and mixed smoke.
- `~andock@1.0` package closure and Forge verification.
- Normal AO resolution with configurable execution device; no AndEE-specific
  Ouroboros server or source staging.
- Full browser flow: load the immutable UI manifest, create a workspace and two
  members, execute tools, browse/download files, restart AndEE, reload the
  workspace, and prove persistence.
- Capture exact HTTP/device responses, measurements, logcat, process/UID/SELinux
  evidence, screenshots, and benchmark JSON under `arch/android/build/`.

## Merge strategy

This work starts from `agent/hb-edge-e445`. The old Andock prototype remains a
separate evidence branch. Transplant only independently useful public device
contract tests and provisioning inputs; do not carry the per-path broker
forward and then preserve it as accidental compatibility.

The implementation should land as reviewable commits in this order:

1. reproducible performance and isolation baselines;
2. isolated capability feasibility evidence;
3. local filesystem engine plus native tests;
4. PRoot integration and removal of the host filesystem broker;
5. Android lifecycle/network integration;
6. seven-operation and package-manager parity;
7. measurement facts and verifier policy; and
8. full portable Ouroboros end-to-end evidence.

No branch is complete until the real-phone performance, isolation, persistence,
and browser gates pass together.
