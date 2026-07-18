# Deterministic Andock ARM64 template builder

## Decision

Build the Andock Ubuntu filesystem entirely as root inside a pinned ARM64
Linux builder. Publish two local build artifacts under `arch/android/build/`:

- an 8 GiB sparse raw ext4 image for verification and operator caches; and
- an Android sparse-image v1 (`.simg`) representation packaged in the AndEE
  runtime ZIP.

Images and inventories remain ignored build outputs. APK assembly validates
the pinned manifest and sparse-image digest. `RuntimeExtractor` expands the
packaged `.simg` into an app-private sparse raw image, verifies the full raw
digest and logical size, and fsyncs it before Andock can start. The runtime-ZIP
measurement therefore commits to the immutable template; mutable per-member
copies are stored separately and are not measured.

## Pinned inputs

- Builder OCI image:
  `ubuntu@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b`
- Ubuntu snapshot: `20260714T000000Z`
- Node.js 22.23.1 archive SHA-256:
  `0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1`
- Permagit 0.11.3 archive SHA-256:
  `6cc1763c3af3072e102ef0d09aaba29fe8c6dd996329d1050c0491dec73d7854`
- Source date epoch: `1735689600`
- ext4 UUID and directory hash seed:
  `4b7e4af2-25cd-4ae5-a14d-8f8628b88f5d`

The snapshot pins package versions; the generated package inventory and every
builder script digest are recorded in the manifest.

## Construction and metadata contract

The provisioned filesystem never crosses macOS before image construction.
GNU tar copies it inside the root-owned Linux builder with numeric owners,
modes, symlinks, hardlinks, ACLs, and all Linux xattrs preserved. The builder
fixes mtimes, creates ext4 with fixed geometry/features/UUID/hash seed/time,
replays xattrs offline with pinned `debugfs`, and normalizes inode atime,
ctime, mtime, and creation time.

`mke2fs -d` is not sufficient by itself. The metadata fixture proved that it
silently omitted `security.capability`, and two independent builds proved that
it leaked wall-clock inode ctime/atime even with `E2FSPROGS_FAKE_TIME` set.
Offline xattr replay and inode-time normalization correct those two causes.

Before accepting the image, the builder mounts it read-only with `noload` and
compares a complete deterministic inventory against the source. The inventory
includes the root directory and every descendant's path, type, numeric
UID/GID, mode, mtime, link target, hardlink identity, device number, xattrs,
size, and file SHA-256. A build-only fixture additionally proves non-root
ownership, setuid mode, hardlinks, symlinks, root/file xattrs, and
`security.capability`; it is not present in the production image.

Representative production metadata includes `/etc/shadow` as `0:42` mode
0640, `/var/cache/apt/archives/partial` as `42:0` mode 0700, and
`/usr/bin/passwd` as `0:0` mode 4755. The inventory contains multiple other
non-root owner pairs, so the builder cannot regress to all-root normalization.

## Android sparse image

`andock-android-sparse.py` emits the standard Android sparse-image v1 format
using 4 KiB RAW and DONT_CARE chunks selected only from file content. It does
not depend on host sparse-extent allocation. Each build expands the `.simg`
again and byte-compares it with the raw ext4 image. Ubuntu's pinned
`simg2img` 34.0.4 independently expanded the artifact to the same bytes.

## Reproducibility and compatibility evidence

Two clean pinned containers produced byte-identical artifacts:

- raw ext4 SHA-256:
  `e468693573fcf162ddbe6d0e8ffdf3ff2e07992a3e2f7387017b342f6df9423c`
- raw logical size: 8,589,934,592 bytes
- raw allocated size: 893,861,888 bytes in the builder
- Android sparse-image SHA-256:
  `6f45382bd8c1c383860c75e92c801864832c1be680fc6ab04c969f21c4dbddb6`
- Android sparse-image size: 893,384,196 bytes

Both 26,960-entry source inventories were byte-identical to their mounted-image
inventories. Expanding either Android sparse artifact reproduced the raw image
byte for byte. Runtime compatibility is exercised separately by the native
engine test and Android emulator workload gates, rather than by the retired
development probe.

The ignored evidence log is
`arch/android/build/andock-template/reproducibility-gate-simg.txt`.
