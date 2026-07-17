#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

TERMUX_PACKAGES_REF=98046d2726d50e29e721e3535da85640bc4b804b
TERMUX_PACKAGES_URL=https://github.com/termux/termux-packages.git
BUILDER_IMAGE=ghcr.io/termux/package-builder@sha256:fa23eb4238ef8eda877cd991a06152ce76e9f274d1cae0d42f28fee3e5cd6016
LWEXT4_REF=58bcf89a121b72d4fb66334f1693d3b30e4cb9c5
LWEXT4_SHA256=8f7cce20f5dad2719cb22982e64c75069af51741555c98d34a247a5d8f154890
LWEXT4_URL="https://codeload.github.com/gkostka/lwext4/tar.gz/$LWEXT4_REF"
SOURCE="$BUILD_DIR/termux-packages"
DOWNLOAD="$BUILD_DIR/downloads/lwext4-$LWEXT4_REF.tar.gz"
LWEXT4_SOURCE="$BUILD_DIR/sources/lwext4-$LWEXT4_REF"
OUT="$BUILD_DIR/proot-image-native/arm64"
CONTAINER=andock-proot-image-builder-$$
VOLUME=andock-proot-image-build-$$
CACHE_VOLUME=andock-proot-image-cache-$TERMUX_PACKAGES_REF

require_tool curl
require_tool docker
require_tool git
require_tool python3

mkdir -p "$(dirname "$DOWNLOAD")" "$(dirname "$LWEXT4_SOURCE")"
if [[ ! -f "$DOWNLOAD" ]]; then
    curl --fail --location --retry 3 --output "$DOWNLOAD" "$LWEXT4_URL"
fi
printf '%s  %s\n' "$LWEXT4_SHA256" "$DOWNLOAD" | shasum -a 256 -c -
if [[ ! -d "$LWEXT4_SOURCE/src" ]]; then
    rm -rf "$LWEXT4_SOURCE"
    tar -xzf "$DOWNLOAD" -C "$(dirname "$LWEXT4_SOURCE")"
fi
if ! grep -q 'sizeof(struct ext4_xattr_list_entry) + name_len + 1' \
    "$LWEXT4_SOURCE/src/ext4_xattr.c"; then
    patch -d "$LWEXT4_SOURCE" -p1 \
        < "$ROOT/native/andock-image-engine-probe/patches/0001-fix-xattr-list-size-ub.patch"
fi
if ! grep -q 'int ext4_fopen_inode' "$LWEXT4_SOURCE/src/ext4.c"; then
    patch -d "$LWEXT4_SOURCE" -p1 \
        < "$ROOT/execution/lwext4-open-inode.patch"
fi
if ! grep -q 'regular_source = ext4_inode_is_type' \
    "$LWEXT4_SOURCE/src/ext4.c"; then
    patch -d "$LWEXT4_SOURCE" -p1 \
        < "$ROOT/execution/lwext4-atomic-replace.patch"
fi

if ! git -C "$SOURCE" rev-parse --git-dir >/dev/null 2>&1; then
    rm -rf "$SOURCE"
    git clone --filter=blob:none "$TERMUX_PACKAGES_URL" "$SOURCE"
fi
if ! git -C "$SOURCE" cat-file -e "$TERMUX_PACKAGES_REF^{commit}"; then
    git -C "$SOURCE" fetch --depth 1 origin "$TERMUX_PACKAGES_REF"
fi
git -C "$SOURCE" checkout --detach --force "$TERMUX_PACKAGES_REF"
git -C "$SOURCE" clean -dffx
git -C "$SOURCE" apply "$ROOT/execution/termux-proot-prefix.patch"
cp "$ROOT/execution/andock-proot-image.patch" \
    "$SOURCE/packages/proot/andock-proot-image.patch"
mkdir -p "$SOURCE/packages/proot/andock-overlay/andock_image/lwext4/include/generated"
cp "$ROOT/execution/proot-overlay/src/extension/andock_image/"*.c \
    "$ROOT/execution/proot-overlay/src/extension/andock_image/"*.h \
    "$SOURCE/packages/proot/andock-overlay/andock_image/"
cp -R "$LWEXT4_SOURCE/include" "$LWEXT4_SOURCE/src" \
    "$SOURCE/packages/proot/andock-overlay/andock_image/lwext4/"
cp "$ROOT/native/andock-image-engine-probe/include/generated/ext4_config.h" \
    "$SOURCE/packages/proot/andock-overlay/andock_image/lwext4/include/generated/ext4_config.h"

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker volume rm "$VOLUME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker volume create "$VOLUME" >/dev/null
docker volume create "$CACHE_VOLUME" >/dev/null
docker run --detach --init --name "$CONTAINER" --platform linux/amd64 \
    --privileged --volume "$VOLUME:/home/builder/termux-packages" \
    --volume "$CACHE_VOLUME:/home/builder/.termux-build" \
    --tty "$BUILDER_IMAGE" >/dev/null
docker cp "$SOURCE/." "$CONTAINER:/home/builder/termux-packages"
docker exec --user root "$CONTAINER" \
    chown -R builder:builder \
        /home/builder/termux-packages \
        /home/builder/.termux-build

# Rosetta's amd64 Linux path lacks the openat2 calls used by GNU tar.
docker exec --user root "$CONTAINER" mv /usr/bin/tar /usr/bin/gtar
docker cp "$ROOT/execution/termux-tar-wrapper" "$CONTAINER:/usr/bin/tar"
docker exec --user root "$CONTAINER" chmod 0755 /usr/bin/tar

docker exec --user builder --workdir /home/builder/termux-packages \
    "$CONTAINER" ./build-package.sh -a aarch64 proot

docker exec --user root "$CONTAINER" sh -euxc '
    rm -rf /tmp/andock-proot
    mkdir -p /tmp/andock-proot
    for package in /home/builder/termux-packages/output/*.deb; do
        dpkg-deb -x "$package" /tmp/andock-proot
    done
    root=/tmp/andock-proot/data/data/org.permaweb.andee/files/usr
    test -x "$root/bin/proot"
    test -x "$root/libexec/proot/loader"
'

rm -rf "$OUT"
mkdir -p "$OUT/usr"
docker cp \
    "$CONTAINER:/tmp/andock-proot/data/data/org.permaweb.andee/files/usr/." \
    "$OUT/usr"

python3 - "$OUT" "$ROOT" "$TERMUX_PACKAGES_REF" "$BUILDER_IMAGE" \
    "$LWEXT4_REF" <<'PY'
import hashlib
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
inputs = [
    root / "execution/termux-proot-prefix.patch",
    root / "execution/termux-tar-wrapper",
    root / "execution/andock-proot-image.patch",
    root / "execution/lwext4-open-inode.patch",
    root / "execution/lwext4-atomic-replace.patch",
    root / "native/andock-image-engine-probe/include/generated/ext4_config.h",
    root / "native/andock-image-engine-probe/patches/0001-fix-xattr-list-size-ub.patch",
    *sorted((root / "execution/proot-overlay/src/extension/andock_image").glob("*")),
]
selected = [out / "usr/bin/proot", out / "usr/libexec/proot/loader"]
manifest = {
    "architecture": "arm64",
    "proot-version": "5.1.107.84",
    "proot-source-sha256": "a44ddbf18bc72c9780d56948b03aeda6d285392503ece0cae17cfc02e7bc7928",
    "termux-packages-revision": sys.argv[3],
    "termux-builder-image": sys.argv[4],
    "lwext4-revision": sys.argv[5],
    "toolchain-revision": f"termux-{sys.argv[3]}+andock-image-1",
    "android-package-prefix": "/data/data/org.permaweb.andee/files/usr",
    "files": {
        str(path.relative_to(out)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in selected
    },
    "inputs": {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in inputs
    },
}
(out / "manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n"
)
PY

echo "Andock image-backed PRoot native root: $OUT"
cat "$OUT/manifest.json"
