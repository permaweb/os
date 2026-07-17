# Andock regular-file image engine spike

Status: build-complete feasibility evidence; Android runtime execution pending
the root integration harness.

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

## Build evidence

Host: Mac17,6, ARM64, macOS 26.4.1 (25E253).

```sh
arch/android/scripts/build-andock-image-engine-spike.sh
```

Exit: `0`. Gradle: `BUILD SUCCESSFUL`; 65 tasks. The command also ran the
normal and ASan/UBSan native suites to `host-native-probe=ok`.

Current ARM64 artifacts:

- native probe `.so` SHA-256:
  `0a234d9b1c25fc622bb1e3b439e984115df5d50acf2ae1921ef2d4a6740428a7`
- test app APK SHA-256:
  `ea3f0dcee34e636a0881b0dbc7470ed8167f258e008f04ab6d5a86fab3d635b9`
- instrumentation APK SHA-256:
  `dae354761ada35c78b4502110e60dc698bf14ad69cae27634bcbe2e3825e3639`

The unstripped ARM64 ELF is AArch64, has no foreign-architecture payload, and
has 143,160 bytes of text, 2,576 bytes of data, and 6,644 bytes of BSS. Its only
dynamic dependencies are Android `libdl.so` and `libc.so`.

The root Android harness can execute the built probe without rebuilding:

```sh
arch/android/scripts/run-andock-image-engine-spike.sh emulator-5562
```

The runtime acceptance line is `regular-file-image-capability=ok`, accompanied
by distinct owner/isolated UIDs, a changed service PID after the deliberate
crash, all native operation results, malformed rejection, and Android sparse
copy allocation/timing.

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
