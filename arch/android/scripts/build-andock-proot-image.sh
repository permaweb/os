#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"
source "$ROOT/scripts/andock-lwext4-source.sh"

TERMUX_PACKAGES_REF=98046d2726d50e29e721e3535da85640bc4b804b
TERMUX_PACKAGES_URL=https://github.com/termux/termux-packages.git
BUILDER_IMAGE=ghcr.io/termux/package-builder@sha256:fa23eb4238ef8eda877cd991a06152ce76e9f274d1cae0d42f28fee3e5cd6016
SOURCE="$BUILD_DIR/termux-packages"
OUT="$BUILD_DIR/proot-image-native/arm64"
CONTAINER=andock-proot-image-builder-$$
VOLUME=andock-proot-image-build-$$
CACHE_VOLUME=andock-proot-image-cache-$TERMUX_PACKAGES_REF

force_rebuild=0
if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--force") ]]; then
    echo "Usage: $0 [--force]" >&2
    exit 2
fi
if [[ ${1:-} == "--force" ]]; then
    force_rebuild=1
fi

require_tool python3

if [[ $force_rebuild == 0 ]] && python3 \
    "$ROOT/scripts/andock-proot-manifest.py" validate \
    "$OUT" "$ROOT" "$TERMUX_PACKAGES_REF" "$BUILDER_IMAGE" "$LWEXT4_REF"
then
    echo "Andock image-backed PRoot already matches pinned inputs: $OUT"
    cat "$OUT/manifest.json"
    exit 0
fi

require_tool docker
require_tool git

prepare_andock_lwext4

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
git -C "$SOURCE" apply "$ROOT/execution/termux-proot-launcher.patch"
cp "$ROOT/execution/andock-proot-image.patch" \
    "$SOURCE/packages/proot/andock-proot-image.patch"
mkdir -p "$SOURCE/packages/proot/andock-overlay/andock_image/lwext4/include/generated"
cp "$ROOT/runtime-src/andock_proot_launcher.c" \
    "$SOURCE/packages/proot/andock-overlay/andock_proot_launcher.c"
cp "$ROOT/execution/proot-overlay/src/extension/andock_image/"*.c \
    "$ROOT/execution/proot-overlay/src/extension/andock_image/"*.h \
    "$SOURCE/packages/proot/andock-overlay/andock_image/"
cp -R "$LWEXT4_SOURCE/include" "$LWEXT4_SOURCE/src" \
    "$SOURCE/packages/proot/andock-overlay/andock_image/lwext4/"
cp "$ROOT/execution/lwext4/include/generated/ext4_config.h" \
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
    "$CONTAINER" ./build-package.sh -f -a aarch64 proot

docker exec --user root "$CONTAINER" sh -euxc '
    rm -rf /tmp/andock-proot
    mkdir -p /tmp/andock-proot
    for package in /home/builder/termux-packages/output/*.deb; do
        dpkg-deb -x "$package" /tmp/andock-proot
    done
    root=/tmp/andock-proot/data/data/org.permaweb.andee/files/usr
    test -x "$root/bin/proot"
    test -x "$root/libexec/andock/proot-launcher"
    test -x "$root/libexec/proot/loader"
'

rm -rf "$OUT"
mkdir -p "$OUT/usr"
docker cp \
    "$CONTAINER:/tmp/andock-proot/data/data/org.permaweb.andee/files/usr/." \
    "$OUT/usr"

python3 "$ROOT/scripts/andock-proot-manifest.py" write \
    "$OUT" "$ROOT" "$TERMUX_PACKAGES_REF" "$BUILDER_IMAGE" "$LWEXT4_REF"

echo "Andock image-backed PRoot native root: $OUT"
cat "$OUT/manifest.json"
