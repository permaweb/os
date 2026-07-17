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
creation it opens only the selected member's complete writable filesystem
image and passes that descriptor once to the isolated service:

1. one read-write member filesystem-image capability;
2. the bounded command transport; and
3. network capability state, with Internet sockets brokered separately only
   when policy permits them.

The immutable measured template is used only when the main app creates a new
member image; it is never on the worker's hot path. Filesystem parsing,
pathname resolution, and mutation then occur inside the isolated worker. No
guest filesystem operation sends a host path to HyperBEAM or the main Android
app. The main app does not parse mutable guest filesystem structures.

Each member therefore sees one ordinary writable Linux filesystem. `/usr`,
`/etc`, `/var`, `/tmp`, and `/root` require no overlay semantics and may be
modified freely. The storage cost of duplicating the provisioned template is
accepted for v1 because execution latency and conventional Linux behavior are
more important than deduplication. Sparse copying is required to avoid
materializing unused filesystem capacity; reflink may be an optional creation
fast path, but no runtime behavior may depend on it.

The guest tracee must not inherit the raw filesystem descriptors. They remain
owned by the isolated supervisor, marked close-on-exec, and explicitly closed
in the tracee before its first guest instruction. The tracee interacts with
the filesystem only through the local syscall layer. Even if it escapes that
translation layer, the kernel still confines it to the isolated UID and
SELinux domain.

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
- Rename, link, and unlink operate on parent inode handles. A path is
  revalidated at the mutation point rather than trusted from an earlier
  string-based check.
- Device nodes, host sockets, raw block access, and arbitrary descriptor import
  are not representable in the guest filesystem. The syscall layer supplies
  only the conventional safe synthetic devices required by userland, including
  `/dev/null`, `/dev/zero`, `/dev/urandom`, and `/dev/fd`.
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

### 3. Per-member image creation probe

Create each member as a complete writable filesystem image copied from the
measured immutable template. Evaluate creation methods in this order:

1. filesystem-level clone/reflink of the raw immutable template, if `FICLONE`
   is available and reliable on both the emulator and representative retail
   storage;
2. a sparse extent-preserving copy with bounded temporary storage; and
3. a fully allocated copy only on storage where neither optimization exists.

A reflink-only implementation cannot be the general retail baseline. The
sparse-copy fallback must preserve holes, fail atomically when space is
insufficient, and never expose a partially initialized image as a member.
Userspace overlay, whiteout, copy-up, and custom block-COW formats are excluded
from v1. They may return only as optional optimizations after they outperform
the full-image baseline without changing guest semantics or the trusted
runtime.

The spike ends with a short decision record containing cold creation time,
10,000-file traversal time, random and sequential I/O, image growth, restart
behavior, corruption handling, and exact device/kernel/filesystem facts.

## Packaging and member creation

The build produces one deterministic raw ext4 template with a fixed logical
capacity and an explicitly lwext4-compatible feature set. It is generated from
the pinned Ubuntu provisioner, package manifest, Node.js archive, and permagit
archive; its raw bytes and input manifest are hashed before APK assembly. Image
population runs as root inside the pinned Linux builder and consumes the
numeric-owner OCI export directly. A host-extracted tree on macOS is not an
acceptable input because it collapses service-account ownership and Linux
xattrs/capabilities to host-user metadata.

The raw template is a compressed entry in `andee-runtime.zip`. Extraction must
not materialize its zero ranges: `RuntimeExtractor` hashes the full logical
byte stream while seeking over all-zero blocks in the destination and sets the
final logical length explicitly. Startup verifies the extracted raw digest
before enabling Andock. The existing runtime-ZIP and APK-set digests therefore
continue to commit to the same bytes.

Member creation occurs only in the main app UID:

1. open the verified template read-only;
2. create a same-directory, owner-only temporary image;
3. copy data extents with `SEEK_DATA`/`SEEK_HOLE`, falling back to bounded
   zero scanning;
4. set the exact logical length, `fsync` the destination, and close it;
5. atomically rename it to the opaque member filename and `fsync` the
   containing directory; and
6. open only that completed member image and transfer its descriptor to the
   selected isolated worker.

An interrupted temporary image is never addressable as a member and is
removed during startup recovery. The immutable template descriptor is not
passed to a worker. Member deletion first stops and unbinds the worker, waits
for all descriptors to close, and then removes only that member image.

## Implementation phases

### Phase 0: freeze and profile the prototype

- Keep `agent/andock-1.0` as evidence; do not build the redesign on its large
  broker commit.
- Add a reproducible performance workload containing 10,000-file `stat`,
  `find`, `du`, Python import, Node resolution, Git status, local wheel unpack,
  and sequential I/O.
- Add counters and latency histograms for PRoot stops, resolve/open/list,
  Binder transactions, FD transfers, xattrs, and audited denials.
- Remove the repeated regular-file `TCGETS` attempt and remeasure so the design
  is not based on an avoidable logging pathology.

### Phase 1: isolated capability bootstrap

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

- Implement inode-based lookup inside the selected member image.
- Implement complete regular file, directory, symlink, hard-link, rename,
  truncate, mode, timestamp, `statfs`, and `user.*` xattr semantics.
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
- Retain PRoot's own-tracee `/proc` virtualization without making the image FD,
  PRoot supervisor, HyperBEAM process, or unrelated Android processes visible.
- Materialize a regular inode into a kernel-backed descriptor at most once per
  worker cache generation. Repeated opens duplicate the coherent descriptor;
  they must not recopy the complete file from ext4. Writable descriptors and
  shared mappings become dirty at mutation time and write back on `fsync`,
  `msync`, last close, and worker teardown. Open descriptors and mappings must
  observe ordinary shared-file semantics.
- Delete the per-operation AIDL transaction, Kotlin path resolver, isolated
  socket-to-Binder bridge, host overlay-path translation, and corresponding
  frame protocol once parity is proven.
- Keep lifecycle and optional Internet socket brokerage as small, separate
  Android capabilities.

### Phase 4: package-manager parity

- Build the immutable filesystem from the same pinned declarative provisioner
  as the Ouroboros Docker base.
- Ensure `/usr`, `/etc`, `/var`, `/tmp`, and `/root` are ordinarily writable in
  the member filesystem so `apt`, `pip`, npm, compilers, and source builds
  behave as root-oriented agents expect.
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
  incomplete rename, and full-storage behavior.
- Run consistency checking and deterministic recovery without parsing the
  mutable filesystem in the HyperBEAM process.

### Phase 6: measurement after the design stabilizes

Do not merge the current `agent/andock-measurement` projection: it names the
old `android-app-broker@1` design.

After the storage format and runtime are frozen, expose only verifier-relevant
immutable facts: device version, architecture, syscall layer digest, filesystem
engine/version, immutable template digest, provisioner revision, network policy,
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
- Repeated opens of large ELF and data files, visibility between simultaneous
  descriptors, writable `MAP_SHARED`, `msync`, close-before-`munmap`, and dirty
  teardown recovery.
- Mutation fault injection at every persistent write and recovery after
  process death.
- Fuzz filesystem images and syscall frames under ASan/UBSan on the host and
  the Android HWASan environment where available.

### Isolation and adversarial escape

From a real guest process, attempt to read or modify:

- the raw member-image descriptor through `/proc/self/fd` and inherited FDs;
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
