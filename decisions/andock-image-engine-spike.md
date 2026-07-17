# Andock regular-file image engine spike

Status: regular-file image capability proven on the owned ARM64 Android
emulator and the pinned Ubuntu tree proven in a host-built ext4 image; Android
population performance and PRoot integration remain.

## Decision

Use `lwext4` for the first regular-file image capability probe. It is the
smallest credible way to test whether a filesystem parser inside an Android
isolated process can operate on a single `ParcelFileDescriptor`. This is a
spike selection, not approval of `lwext4` as the production engine.

The v1 storage shape should be one complete writable filesystem image per
member, sparse-copied from the measured immutable template. It does not depend
on reflinks, a base/member overlay, or deduplication. The immutable template is
measured; mutable member copies and their allocation state are not.

## Why this route is now first

The API 36 directory-capability probe failed at the production-shaped
translation boundary with `translate fd failed`. Passing an open app-private
directory therefore does not make that directory usable by the isolated
worker. The same target returned `EOPNOTSUPP` for `cp --reflink=always` on
app-private files. A separate Android emulator probe created a 1 GiB sparse
file with one 4 KiB extent: app-private storage preserved it as 16 512-byte
blocks (8 KiB), while Toybox `cp` materialized 2,097,168 blocks
(1,073,750,016 bytes). Neither a directory FD, reflink cloning, nor platform
`cp` is a retail baseline.

A regular app-private file FD remains viable: Binder transfers the open file
description, while the isolated process never receives an Android pathname or
a descriptor for the containing app directory. The disposable test APK passes
only that image FD to its `isolatedProcess` service.

## Library comparison

| Concern | `lwext4` | `libext2fs` |
|---|---|---|
| First-probe API | POSIX-shaped pathname operations for files, directories, links, modes, timestamps, xattrs, journaling, and recovery | Canonical ext-family block/inode manipulation APIs; higher-level pathname mutation and runtime-handle semantics would need more adapter code |
| Android build surface | 21 C sources, 17,616 lines in the selected `src/`, standard C plus a six-function block-device adapter | Part of e2fsprogs; a credible Android port must select and patch its portability, `com_err`, UUID, and supporting library surface deliberately |
| Checker/recovery | Journal recovery, but no production-grade equivalent of `e2fsck` | The natural route to full e2fsprogs checker coverage |
| License | Full selected build is GPLv2 because xattrs and extents pull GPLv2 source | GPLv2 |
| Probe result | Cross-build and host behavior proven below | Not built because it is not the smallest way to answer the FD-capability question |

`libext2fs` remains a serious candidate for an offline consistency checker or
for the final engine if fault injection exposes gaps in `lwext4`. The spike
does not replace that production decision.

## Pinned input

- Repository: `https://github.com/gkostka/lwext4`
- Revision: `58bcf89a121b72d4fb66334f1693d3b30e4cb9c5`
- Archive URL:
  `https://codeload.github.com/gkostka/lwext4/tar.gz/58bcf89a121b72d4fb66334f1693d3b30e4cb9c5`
- Archive SHA-256:
  `8f7cce20f5dad2719cb22982e64c75069af51741555c98d34a247a5d8f154890`

The build verifies the archive before extraction. It applies one local,
reviewable UB fix to two identical xattr list-size calculations. Upstream uses
pointer arithmetic from null to compute `sizeof(struct
ext4_xattr_list_entry)`; UBSan rejected it. The patch substitutes the literal
`sizeof` expression. The build also disables `CONFIG_UNALIGNED_ACCESS`; the
upstream fast path performs unaligned typed loads that UBSan correctly flags
as C undefined behavior even on CPUs that tolerate the instruction.

## Proven operations

The native probe uses `pread`/`pwrite` against the passed descriptor and checks
every block range against the descriptor length. It creates a journaled 64 MiB
ext4 filesystem and proves:

- mkfs, superblock validation, mount, enumeration, unmount, and reopen;
- directory and regular-file create, read, write, truncate, unlink, and rename;
- hard links with identical inode numbers;
- relative symlink creation and readback;
- mode and access/change/modification timestamp persistence;
- `user.andock` xattr set, get, and list;
- process-crash reopen after `_exit(86)` without journal stop or unmount; and
- rejection of zeroed superblocks, bad magic, truncated images, and an
  unsupported incompatible-feature bit.

The malformed-image run exposed a real wrapper requirement: `lwext4` alone
accepted a 2 KiB truncation that retained its primary superblock. The adapter
now rejects any image whose advertised block geometry exceeds the actual file
length before journaling or file operations begin.

ASan plus UBSan runs the complete host lifecycle, crash/reopen, sparse-copy,
and malformed-image suite with `halt_on_error=1`.

## Full per-member copy evidence

The probe includes a non-reflink sparse copy primitive suitable for making a
complete member image from an immutable template. It uses
`SEEK_DATA`/`SEEK_HOLE` when the backing filesystem implements them and falls
back to a 4 KiB zero-scanning copy otherwise. Both paths write an independent
destination file and `fsync` it. The copied image is reopened through `lwext4`
and the complete fixture, including crash-recovered state, is verified again.

Production member creation must apply that primitive to a same-directory
temporary image, `fsync` the image, atomically rename it to the member's final
name, and `fsync` the containing directory. The spike proves the copy primitive
and sparse allocation, not atomic publication after app or device power loss.

On the local APFS control host, the journaled image was 67,108,864 logical
bytes and 5,308,416 allocated bytes after the fixture. Three warm independent
sparse copies took:

| Run | Nanoseconds | Physical bytes | Mode |
|---:|---:|---:|---|
| 1 | 1,226,000 | 5,308,416 | `seek-data-hole` |
| 2 | 1,346,000 | 5,308,416 | `seek-data-hole` |
| 3 | 1,316,000 | 5,308,416 | `seek-data-hole` |

Median: 1.316 ms. This is a warm macOS control, not an Android performance
claim. The APK instrumentation reports the selected copy mode, elapsed
nanoseconds, logical bytes, and physical `st_blocks * 512` bytes on the target
emulator or phone.

## Pinned Ubuntu population gate

The host-only population gate consumes the existing ARM64 Ubuntu 24.04 tree
whose manifest commits to tree SHA-256
`c1652db388f6c7bf0b5e37d43a52a7cc2fd4fe78d0731ea50b6f5729b1d7484f`.
The source occupies 842,332 KiB and contains 26,930 entries below its root:
22,483 regular files, 3,484 directories, and 963 symlinks. `mke2fs` adds
`lost+found`, yielding the 26,931 entries enumerated through `lwext4`.

The gate uses explicit ext4 features, a fixed UUID and directory-hash seed,
`SOURCE_DATE_EPOCH=1735689600`, and a pinned host builder:

- `mke2fs 1.47.2 (1-Jan-2025)`, Android platform ext2fs library
  `android-platform-15.0.0_r5-314-ga1f793f6b`;
- builder SHA-256
  `e1cb9ae14ce0cee376e9237e9134387adea7e8c5f13d957752bbe18039d830b8`;
- output UUID `4b7e4af2-25cd-4ae5-a14d-8f8628b88f5d`; and
- output label `andock-ubuntu`.

Three independent clean-template builds were byte-for-byte identical at
SHA-256
`1935843759cb448ebfb95115021d210a908b5595a89dab4e10ca9e1567df42f9`.
Each image is 2,147,483,648 logical bytes and 938,082,304 physically allocated
bytes on APFS. The first cold-ish `mke2fs -d` observation was 3.65 seconds;
the final warm clean-template population took 1,365,688,000 ns. A separately
measured owner-normalization pass on a disposable member copy took 0.25
seconds. These are host build observations, not Android startup latency.

The pinned `lwext4` build opened the populated image, enumerated the exact
counts, and read representative AArch64 ELF payloads with their exact sizes:
glibc, Python 3.12, and Node 22. It also verified the usr-merge symlinks,
`/etc/os-release`, and the setuid mode on `/usr/bin/passwd`. The source tree has
no hardlinked regular files and its Mac staging representation contains no
Linux xattrs. The post-population mutation suite therefore adds and persists a
hard link and `user.andock` xattr, alongside the existing file, link, mode,
timestamp, reopen, and deliberate-crash recovery checks.

Three byte-identical copies of the complete clean template used the explicit
`SEEK_DATA`/`SEEK_HOLE` copier and retained 938,082,304 allocated bytes:

| Run | Nanoseconds |
|---:|---:|
| 1 | 149,034,000 |
| 2 | 109,940,000 |
| 3 | 123,512,000 |

Median: 123.512 ms. The copied image was then reopened, inspected, mutated,
closed, reopened, deliberately process-crashed after a committed rename, and
journal-recovered successfully.

The ownership result is a build-pipeline finding, not an accepted production
policy. The current macOS extractor discarded the OCI numeric owners, so
`mke2fs -d` faithfully imported host owner `501:20`. The clean immutable
template retains that evidence. The spike normalized all 26,932 inodes in a
disposable member copy to `0:0` solely to prove that `lwext4` can operate on
the provisioned content. That is not Docker parity: service-account ownership
and Linux security xattrs or capabilities must not be flattened. A production
template must be generated inside the root-owned build container, or imported
directly from the numeric-owner OCI export, and must verify representative
system-account owners and Linux xattrs before it can replace the Docker base.

The complete reproducible host command is:

```sh
arch/android/scripts/test-andock-populated-image.sh \
  /path/to/pinned/arm64/rootfs
```

## Build evidence

Host: Mac17,6, ARM64, macOS 26.4.1 (25E253).

```sh
arch/android/scripts/build-andock-image-engine-spike.sh
```

Exit: `0`. Gradle: `BUILD SUCCESSFUL`; 65 tasks. The command also ran the
normal and ASan/UBSan native suites to `host-native-probe=ok`.

Current ARM64 artifacts:

- native probe `.so` SHA-256:
  `8d34c20306883910f1cb5240bde8d0632d41e887bb123f90902e9de3921d0ddf`
- test app APK SHA-256:
  `5ad1b8cfa3833149b4141626e4e48694752def93ddde8818ed3bf083c6811fa2`
- instrumentation APK SHA-256:
  `f0fa4e6bfe90b74096643bd3085e37ca0ace9bce821c1fd6da75e2b80de6b99a`

The unstripped ARM64 ELF is AArch64, has no foreign-architecture payload, and
has 143,224 bytes of text, 2,576 bytes of data, and 6,580 bytes of BSS. Its only
dynamic dependencies are Android `libdl.so` and `libc.so`.

The root Android harness can execute the built probe without rebuilding:

```sh
arch/android/scripts/run-andock-image-engine-spike.sh emulator-5562
```

## Android runtime evidence

Target: `emulator-5562`, AVD `codex-handee-4g`, ARM64, Android 16/API 36,
kernel `6.12.38-android16-5-gbb9513914902-ab13996879-4k`, SELinux enforcing,
4 GiB RAM.

The first runtime attempt exposed an invalid hyphenated
`bindIsolatedService` instance name before service creation. The fixed probe
uses an Android-valid underscore name; it does not weaken the isolated-service
boundary.

Three independent clean instrumentation runs exited 0 with
`regular-file-image-capability=ok`. The application UID was 10252 and the
isolated UIDs differed on each run (99048, 99050, and 99052). In the full first
run the deliberate crash changed the isolated service PID from 17996 to 18008,
then journal recovery, complete semantic verification, sparse-copy reopen,
and all four malformed-image rejection classes passed. No matching SELinux
denial was present in logcat.

All three Android copies selected `seek-data-hole`, preserved the 64 MiB
logical length in 1,409,024 physical bytes, and took:

| Run | Nanoseconds |
|---:|---:|
| 1 | 1,858,834 |
| 2 | 2,094,792 |
| 3 | 1,741,250 |

Median: 1.859 ms. These are small-fixture capability timings, not a prediction
for the 823 MiB provisioned Ubuntu template.

## Limits and next decision

This evidence proves a regular-file FD can host an ext4 engine and survive an
isolated-process crash. It does not yet prove power-loss/torn-write recovery,
full-image fsck, adversarial fuzzing, performance on Android storage, or the
Linux syscall integration required by PRoot.

The integration problem is material: `lwext4` returns userspace file handles,
not kernel file descriptors. A dynamic loader needs executable `mmap`, and
writable shared mappings require coherent writeback semantics. Read-only
executables can be materialized into sealed memfds, but the production design
must not pretend that arbitrary writable `mmap` is solved by this probe. The
next gate is Android runtime evidence followed by a small PRoot path/read/write
adapter and an explicit `mmap` compatibility decision before adopting the
engine.
