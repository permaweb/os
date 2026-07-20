#!/usr/bin/env bash
set -euo pipefail

: "${ANDEE_OUTPUT_BASENAME:?missing output basename}"
: "${ANDEE_SOURCE_DATE_EPOCH:?missing source date epoch}"
: "${ANDEE_IMAGE_UUID:?missing image UUID}"
: "${ANDEE_IMAGE_BYTES:?missing image size}"
: "${ANDEE_UBUNTU_IMAGE:?missing Ubuntu image}"
: "${ANDEE_UBUNTU_SNAPSHOT:?missing Ubuntu snapshot}"
: "${ANDEE_NODE_VERSION:?missing Node.js version}"
: "${ANDEE_NODE_SHA256:?missing Node.js digest}"
: "${ANDEE_PERMAGIT_VERSION:?missing permagit version}"
: "${ANDEE_PERMAGIT_SHA256:?missing permagit digest}"
: "${ANDEE_PROVISION_REVISION:?missing provision revision}"
: "${ANDEE_PACKAGE_LOCK_SHA256:?missing package-lock digest}"
: "${ANDEE_PROVISIONER_SHA256:?missing provisioner digest}"
: "${ANDEE_TEMPLATE_BUILDER_SHA256:?missing template-builder digest}"
: "${ANDEE_INVENTORY_SCRIPT_SHA256:?missing inventory-script digest}"
: "${ANDEE_XATTR_REPLAYER_SHA256:?missing xattr-replayer digest}"
: "${ANDEE_SPARSE_CONVERTER_SHA256:?missing sparse-converter digest}"

IMAGE_BYTES="$ANDEE_IMAGE_BYTES"
IMAGE_INODES=524288
FEATURES='has_journal,ext_attr,dir_index,filetype,extent,sparse_super,large_file,^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file,^flex_bg,^huge_file,^dir_nlink,^extra_isize,^resize_inode,^sparse_super2,^project,^quota,^encrypt,^casefold,^verity,^ea_inode,^inline_data,^bigalloc,^mmp,^uninit_bg'
WORK=/build/andock-template
ROOTFS="$WORK/rootfs"
MOUNTED="$WORK/mounted"
FIXTURE="$WORK/fixture"
INVENTORY="$WORK/tools/andock-metadata-inventory.py"
XATTR_REPLAYER="$WORK/tools/andock-replay-xattrs.py"
SPARSE_CONVERTER="$WORK/tools/andock-android-sparse.py"
OUTPUT="/output/$ANDEE_OUTPUT_BASENAME"
OUTPUT_SIMG="$OUTPUT.simg"
TMP_IMAGE="$OUTPUT.tmp"
TMP_SIMG="$OUTPUT_SIMG.tmp"

cleanup() {
    if mountpoint -q "$MOUNTED"; then
        umount "$MOUNTED" || true
    fi
    if mountpoint -q "$FIXTURE/mounted"; then
        umount "$FIXTURE/mounted" || true
    fi
    rm -f "$TMP_IMAGE" "$TMP_SIMG"
}
trap cleanup EXIT

normalize_ext4_inode_times() {
    local image="$1"
    local mount_dir="$2"
    local inode_list="$3"
    local debugfs_batch="$4"

    mount -t ext4 -o loop,ro,noload,noatime "$image" "$mount_dir"
    find "$mount_dir" -xdev -printf '%i\n' | LC_ALL=C sort -nu >"$inode_list"
    umount "$mount_dir"
    python3 - "$inode_list" "$debugfs_batch" "$ANDEE_SOURCE_DATE_EPOCH" <<'PY'
import pathlib
import sys

inodes = pathlib.Path(sys.argv[1]).read_text().splitlines()
epoch = sys.argv[3]
with pathlib.Path(sys.argv[2]).open("w") as batch:
    for inode in inodes:
        for field in ("atime", "ctime", "mtime", "crtime"):
            batch.write(f"sif <{inode}> {field} @{epoch}\n")
PY
    debugfs -w -f "$debugfs_batch" "$image" >/dev/null
}

mkdir -p "$WORK/tools" "$ROOTFS" "$MOUNTED" "$FIXTURE"
cp /tmp/andock-metadata-inventory.py "$INVENTORY"
cp /tmp/andock-replay-xattrs.py "$XATTR_REPLAYER"
cp /tmp/andock-android-sparse.py "$SPARSE_CONVERTER"
cp /tmp/andock-packages.txt "$OUTPUT.packages.txt"
rm -f \
    /tmp/andock-metadata-inventory.py \
    /tmp/andock-replay-xattrs.py \
    /tmp/andock-android-sparse.py \
    /tmp/andock-packages.lock \
    /tmp/andock-packages.txt \
    /tmp/andock-provision-base \
    /tmp/andock-build-template-inner \
    /tmp/node.tar.xz \
    /tmp/permagit.tar.gz

# Copy while still root on Linux so numeric owners, hardlinks, and Linux xattrs
# never cross a macOS filesystem boundary.
tar \
    --create --file=- --one-file-system --numeric-owner --sort=name \
    --acls --xattrs --xattrs-include='*' \
    --exclude='./build' --exclude='./output' \
    --exclude='./dev/*' --exclude='./proc/*' --exclude='./run/*' \
    --exclude='./sys/*' \
    --directory=/ . | tar \
        --extract --file=- --numeric-owner --same-owner --same-permissions \
        --acls --xattrs --xattrs-include='*' --directory="$ROOTFS"

mkdir -p \
    "$ROOTFS/dev/pts" "$ROOTFS/dev/shm" "$ROOTFS/proc" "$ROOTFS/root" \
    "$ROOTFS/run" "$ROOTFS/sys" "$ROOTFS/tmp" "$ROOTFS/var/tmp"
printf '127.0.0.1 localhost\n::1 localhost\n' >"$ROOTFS/etc/hosts"
: >"$ROOTFS/etc/hostname"
: >"$ROOTFS/etc/resolv.conf"
: >"$ROOTFS/etc/machine-id"
chown 0:0 \
    "$ROOTFS/etc/hosts" "$ROOTFS/etc/hostname" \
    "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/machine-id"
chmod 0644 \
    "$ROOTFS/etc/hosts" "$ROOTFS/etc/hostname" \
    "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/machine-id"
chmod 0700 "$ROOTFS/root"
chmod 1777 "$ROOTFS/tmp" "$ROOTFS/var/tmp"
find "$ROOTFS" -xdev -exec \
    touch -h -d "@$ANDEE_SOURCE_DATE_EPOCH" {} +

python3 "$INVENTORY" \
    "$ROOTFS" "$OUTPUT.source.inventory.ndjson" "$OUTPUT.source.summary.json" \
    --source-date-epoch "$ANDEE_SOURCE_DATE_EPOCH"
python3 - "$OUTPUT.source.summary.json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
if summary["fixed-mtime-violations"]:
    raise SystemExit("source tree contains non-deterministic mtimes")
if summary["total-entries"] < 25000:
    raise SystemExit("source tree is unexpectedly small")
if not any(owner != "0:0" for owner in summary["owners"]):
    raise SystemExit("source tree lost all non-root ownership")
shadow = summary["representatives"].get("etc/shadow", {})
if shadow.get("uid") != 0 or shadow.get("gid") in (None, 0):
    raise SystemExit("/etc/shadow lost its shadow-group ownership")
partial = summary["representatives"].get("var/cache/apt/archives/partial", {})
if partial.get("uid") in (None, 0):
    raise SystemExit("APT partial directory lost its service-account owner")
PY

# Exercise the exact directory-to-ext4 metadata path with deliberately
# non-trivial metadata without adding a test fixture to the production image.
mkdir -p "$FIXTURE/source" "$FIXTURE/mounted"
cp --preserve=all /usr/bin/true "$FIXTURE/source/executable"
ln "$FIXTURE/source/executable" "$FIXTURE/source/executable.hardlink"
ln -s executable "$FIXTURE/source/executable.symlink"
chown "$(id -u _apt):$(getent group shadow | cut -d: -f3)" \
    "$FIXTURE/source/executable"
chmod 4750 "$FIXTURE/source/executable"
python3 - "$FIXTURE/source" "$FIXTURE/source/executable" <<'PY'
import os
import sys
os.setxattr(sys.argv[1], b"user.andock.root", b"root-metadata-fixture")
os.setxattr(sys.argv[2], b"user.andock", b"metadata-fixture")
PY
setcap cap_net_raw=ep "$FIXTURE/source/executable"
find "$FIXTURE/source" -xdev -exec \
    touch -h -d "@$ANDEE_SOURCE_DATE_EPOCH" {} +
python3 "$INVENTORY" \
    "$FIXTURE/source" "$FIXTURE/source.ndjson" "$FIXTURE/source.json" \
    --source-date-epoch "$ANDEE_SOURCE_DATE_EPOCH"
truncate -s 67108864 "$FIXTURE/metadata.ext4"
E2FSPROGS_FAKE_TIME="$ANDEE_SOURCE_DATE_EPOCH" mke2fs \
    -q -F -t ext4 -b 4096 -I 256 -N 4096 -m 0 \
    -L andock-fixture -U "$ANDEE_IMAGE_UUID" \
    -O "$FEATURES" \
    -E "lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0,hash_seed=$ANDEE_IMAGE_UUID" \
    -d "$FIXTURE/source" "$FIXTURE/metadata.ext4"
E2FSPROGS_FAKE_TIME="$ANDEE_SOURCE_DATE_EPOCH" python3 "$XATTR_REPLAYER" \
    "$FIXTURE/source" "$FIXTURE/metadata.ext4" "$FIXTURE/xattrs"
normalize_ext4_inode_times \
    "$FIXTURE/metadata.ext4" "$FIXTURE/mounted" \
    "$FIXTURE/inodes" "$FIXTURE/normalize.debugfs"
mount -t ext4 -o loop,ro,noload "$FIXTURE/metadata.ext4" "$FIXTURE/mounted"
python3 "$INVENTORY" \
    "$FIXTURE/mounted" "$FIXTURE/image.ndjson" "$FIXTURE/image.json" \
    --source-date-epoch "$ANDEE_SOURCE_DATE_EPOCH" --exclude-top lost+found
cmp "$FIXTURE/source.ndjson" "$FIXTURE/image.ndjson"
python3 - "$FIXTURE/image.json" <<'PY'
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[1]).read_text())
if summary["capability-paths"] != ["executable", "executable.hardlink"]:
    raise SystemExit("security.capability did not survive ext4 population")
if summary["hardlink-groups"] != [["executable", "executable.hardlink"]]:
    raise SystemExit("hardlink identity did not survive ext4 population")
if summary["xattr-paths"] != [".", "executable", "executable.hardlink"]:
    raise SystemExit("root or file xattrs did not survive ext4 population")
if summary["counts"].get("symlink") != 1:
    raise SystemExit("symlink did not survive ext4 population")
if summary["representatives"]:
    raise SystemExit("unexpected production representatives in fixture")
PY
umount "$FIXTURE/mounted"

MKE2FS_VERSION="$(mke2fs -V 2>&1 | head -1)"
MKE2FS_LIBRARY_VERSION="$(mke2fs -V 2>&1 | tail -1 | sed 's/^[[:space:]]*//')"
MKE2FS_SHA256="$(sha256sum "$(command -v mke2fs)" | awk '{print $1}')"
E2FSPROGS_VERSION="$(dpkg-query -W -f='${Version}' e2fsprogs)"
PACKAGES_SHA256="$(sha256sum "$OUTPUT.packages.txt" | awk '{print $1}')"
BUILD_STARTED="$(date +%s%N)"
truncate -s "$IMAGE_BYTES" "$TMP_IMAGE"
E2FSPROGS_FAKE_TIME="$ANDEE_SOURCE_DATE_EPOCH" mke2fs \
    -q -F -t ext4 -b 4096 -I 256 -N "$IMAGE_INODES" -m 0 \
    -L andock-ubuntu -U "$ANDEE_IMAGE_UUID" \
    -O "$FEATURES" \
    -E "lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0,hash_seed=$ANDEE_IMAGE_UUID" \
    -d "$ROOTFS" "$TMP_IMAGE"
E2FSPROGS_FAKE_TIME="$ANDEE_SOURCE_DATE_EPOCH" python3 "$XATTR_REPLAYER" \
    "$ROOTFS" "$TMP_IMAGE" "$WORK/xattrs"
normalize_ext4_inode_times \
    "$TMP_IMAGE" "$MOUNTED" "$WORK/inodes" "$WORK/normalize.debugfs"
sync -f "$TMP_IMAGE"
BUILD_FINISHED="$(date +%s%N)"

mount -t ext4 -o loop,ro,noload "$TMP_IMAGE" "$MOUNTED"
python3 "$INVENTORY" \
    "$MOUNTED" "$OUTPUT.image.inventory.ndjson" "$OUTPUT.image.summary.json" \
    --source-date-epoch "$ANDEE_SOURCE_DATE_EPOCH" --exclude-top lost+found
cmp "$OUTPUT.source.inventory.ndjson" "$OUTPUT.image.inventory.ndjson"
umount "$MOUNTED"

IMAGE_SHA256="$(sha256sum "$TMP_IMAGE" | awk '{print $1}')"
IMAGE_LOGICAL_BYTES="$(stat -c %s "$TMP_IMAGE")"
IMAGE_ALLOCATED_BYTES="$(( $(stat -c %b "$TMP_IMAGE") * 512 ))"
SPARSE_STARTED="$(date +%s%N)"
python3 "$SPARSE_CONVERTER" encode "$TMP_IMAGE" "$TMP_SIMG"
python3 "$SPARSE_CONVERTER" expand "$TMP_SIMG" "$WORK/roundtrip.ext4"
cmp "$TMP_IMAGE" "$WORK/roundtrip.ext4"
rm -f "$WORK/roundtrip.ext4"
SPARSE_FINISHED="$(date +%s%N)"
SPARSE_SHA256="$(sha256sum "$TMP_SIMG" | awk '{print $1}')"
SPARSE_BYTES="$(stat -c %s "$TMP_SIMG")"
SPARSE_ALLOCATED_BYTES="$(( $(stat -c %b "$TMP_SIMG") * 512 ))"
mv -f "$TMP_IMAGE" "$OUTPUT"
mv -f "$TMP_SIMG" "$OUTPUT_SIMG"
sync -f /output

python3 - \
    "$OUTPUT.manifest.json" "$OUTPUT.source.summary.json" \
    "$ANDEE_UBUNTU_IMAGE" "$ANDEE_UBUNTU_SNAPSHOT" \
    "$ANDEE_NODE_VERSION" "$ANDEE_NODE_SHA256" \
    "$ANDEE_PERMAGIT_VERSION" "$ANDEE_PERMAGIT_SHA256" \
    "$ANDEE_PROVISION_REVISION" "$ANDEE_SOURCE_DATE_EPOCH" \
    "$ANDEE_IMAGE_UUID" "$IMAGE_SHA256" "$IMAGE_LOGICAL_BYTES" \
    "$IMAGE_ALLOCATED_BYTES" "$((BUILD_FINISHED - BUILD_STARTED))" \
    "$E2FSPROGS_VERSION" "$MKE2FS_VERSION" "$MKE2FS_LIBRARY_VERSION" \
    "$MKE2FS_SHA256" "$ANDEE_PACKAGE_LOCK_SHA256" \
    "$ANDEE_PROVISIONER_SHA256" "$ANDEE_TEMPLATE_BUILDER_SHA256" \
    "$ANDEE_INVENTORY_SCRIPT_SHA256" "$PACKAGES_SHA256" \
    "$ANDEE_XATTR_REPLAYER_SHA256" "$ANDEE_SPARSE_CONVERTER_SHA256" \
    "$SPARSE_SHA256" "$SPARSE_BYTES" \
    "$((SPARSE_FINISHED - SPARSE_STARTED))" "$SPARSE_ALLOCATED_BYTES" <<'PY'
import hashlib
import json
import pathlib
import sys

summary = json.loads(pathlib.Path(sys.argv[2]).read_text())
manifest = {
    "architecture": "arm64",
    "e2fsprogs-version": sys.argv[16],
    "image-logical-bytes": int(sys.argv[13]),
    "image-sha256": sys.argv[12],
    "image-uuid": sys.argv[11],
    "metadata-inventory-sha256": summary["inventory-sha256"],
    "mke2fs-library-version": sys.argv[18],
    "mke2fs-sha256": sys.argv[19],
    "mke2fs-version": sys.argv[17],
    "node-sha256": sys.argv[6],
    "node-version": sys.argv[5],
    "package-lock-sha256": sys.argv[20],
    "packages-sha256": sys.argv[24],
    "permagit-sha256": sys.argv[8],
    "permagit-version": sys.argv[7],
    "provision-revision": sys.argv[9],
    "provisioner-sha256": sys.argv[21],
    "source-date-epoch": int(sys.argv[10]),
    "sparse-converter-sha256": sys.argv[26],
    "sparse-image-bytes": int(sys.argv[28]),
    "sparse-image-format": "android-sparse-v1",
    "sparse-image-sha256": sys.argv[27],
    "ubuntu-builder-image": sys.argv[3],
    "ubuntu-snapshot": sys.argv[4],
    "template-builder-sha256": sys.argv[22],
    "inventory-script-sha256": sys.argv[23],
    "xattr-replayer-sha256": sys.argv[25],
}
pathlib.Path(sys.argv[1]).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n"
)
PY

cat "$OUTPUT.manifest.json"
printf 'raw-image-allocated-bytes-in-builder=%s\n' "$IMAGE_ALLOCATED_BYTES"
printf 'raw-image-build-nanoseconds=%s\n' "$((BUILD_FINISHED - BUILD_STARTED))"
printf 'sparse-image-allocated-bytes-in-builder=%s\n' \
    "$SPARSE_ALLOCATED_BYTES"
printf 'sparse-image-build-nanoseconds=%s\n' \
    "$((SPARSE_FINISHED - SPARSE_STARTED))"
printf 'template-metadata-parity=ok\n'
