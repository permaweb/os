#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_DIR:-$ROOT/build}/andock-image-engine-spike"
PROBE="$BUILD_ROOT/host/andock-image-engine-probe"
ROOTFS="${1:?usage: $0 ROOTFS [OUTPUT_IMAGE]}"
OUTPUT="${2:-$BUILD_ROOT/populated/andock-ubuntu-arm64.ext4}"
EXPECTED_TREE_SHA256=c1652db388f6c7bf0b5e37d43a52a7cc2fd4fe78d0731ea50b6f5729b1d7484f
SOURCE_DATE_EPOCH=1735689600
IMAGE_BYTES=2147483648
IMAGE_UUID=4b7e4af2-25cd-4ae5-a14d-8f8628b88f5d
MKE2FS="${MKE2FS:-/opt/homebrew/bin/mke2fs}"
EXPECTED_MKE2FS_SHA256=e1cb9ae14ce0cee376e9237e9134387adea7e8c5f13d957752bbe18039d830b8
FEATURES='has_journal,ext_attr,dir_index,filetype,extent,sparse_super,large_file,^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file,^flex_bg,^huge_file,^dir_nlink,^extra_isize,^resize_inode,^sparse_super2,^project,^quota,^encrypt,^casefold,^verity,^ea_inode,^inline_data,^bigalloc,^mmp,^uninit_bg'

if [[ ! -d "$ROOTFS" ]]; then
    printf 'rootfs not found: %s\n' "$ROOTFS" >&2
    exit 1
fi
if [[ ! -x "$MKE2FS" ]]; then
    printf 'mke2fs not found: %s\n' "$MKE2FS" >&2
    exit 1
fi
MKE2FS_VERSION="$($MKE2FS -V 2>&1 | head -1)"
if [[ "$MKE2FS_VERSION" != "mke2fs 1.47.2 (1-Jan-2025)" ]]; then
    printf 'expected mke2fs 1.47.2, found: %s\n' "$MKE2FS_VERSION" >&2
    exit 1
fi
MKE2FS_SHA256="$(shasum -a 256 "$MKE2FS" | awk '{print $1}')"
if [[ "$MKE2FS_SHA256" != "$EXPECTED_MKE2FS_SHA256" ]]; then
    printf 'mke2fs checksum mismatch: expected %s, found %s\n' \
        "$EXPECTED_MKE2FS_SHA256" "$MKE2FS_SHA256" >&2
    exit 1
fi

ACTUAL_TREE_SHA256="$(python3 - "$ROOTFS" <<'PY'
import hashlib
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    info = path.lstat()
    mode = 0o777 if path.is_symlink() else stat.S_IMODE(info.st_mode)
    digest.update(relative.encode() + b"\0")
    digest.update(f"{mode:o}\0".encode())
    if path.is_symlink():
        digest.update(b"l\0" + os.readlink(path).encode() + b"\0")
    elif stat.S_ISREG(info.st_mode):
        digest.update(b"f\0" + str(info.st_size).encode() + b"\0")
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    elif path.is_dir():
        digest.update(b"d\0")
print(digest.hexdigest())
PY
)"
if [[ "$ACTUAL_TREE_SHA256" != "$EXPECTED_TREE_SHA256" ]]; then
    printf 'rootfs tree mismatch: expected %s, found %s\n' \
        "$EXPECTED_TREE_SHA256" "$ACTUAL_TREE_SHA256" >&2
    exit 1
fi

"$ROOT/scripts/build-andock-image-engine-spike.sh" --native-only >/dev/null

mkdir -p "$(dirname "$OUTPUT")"
TMP="$OUTPUT.tmp.$$"
COPY="$OUTPUT.member-copy"
trap 'rm -f "$TMP"' EXIT
truncate -s "$IMAGE_BYTES" "$TMP"

now_ns() {
    python3 -c 'import time; print(time.time_ns())'
}

BUILD_STARTED="$(now_ns)"
E2FSPROGS_FAKE_TIME="$SOURCE_DATE_EPOCH" "$MKE2FS" \
    -q -F -t ext4 -b 4096 -I 256 -m 0 \
    -L andock-ubuntu -U "$IMAGE_UUID" \
    -O "$FEATURES" \
    -E "root_owner=0:0,hash_seed=$IMAGE_UUID" \
    -d "$ROOTFS" "$TMP"
BUILD_FINISHED="$(now_ns)"
mv -f "$TMP" "$OUTPUT"
trap - EXIT

BLOCKS="$(stat -f %b "$OUTPUT")"
printf 'rootfs-tree-sha256=%s\n' "$ACTUAL_TREE_SHA256"
printf 'mke2fs-version=%s\n' "$MKE2FS_VERSION"
printf 'mke2fs-sha256=%s\n' "$MKE2FS_SHA256"
printf 'image-build-nanoseconds=%s\n' "$((BUILD_FINISHED - BUILD_STARTED))"
printf 'image-logical-bytes=%s\n' "$(stat -f %z "$OUTPUT")"
printf 'image-allocated-bytes=%s\n' "$((BLOCKS * 512))"
printf 'image-sha256=%s\n' "$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"

for RUN in 1 2 3; do
    printf 'copy-run=%s\n' "$RUN"
    "$PROBE" --sparse-copy "$OUTPUT" "$COPY"
    cmp -s "$OUTPUT" "$COPY"
    printf 'copy-byte-identical=ok\n'
done
printf 'copy-sha256=%s\n' "$(shasum -a 256 "$COPY" | awk '{print $1}')"
"$PROBE" --normalize-populated-owners "$COPY"
"$PROBE" --inspect-populated "$COPY"
"$PROBE" --verify-populated "$COPY"
printf 'populated-image-gate=ok\n'
