#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

WORK="${1:?missing runtime work directory}"
JNI_DIR="${2:?missing Android JNI directory}"
TEMPLATE_MANIFEST="$ROOT/execution/andock-ubuntu-arm64.ext4.manifest.json"
NATIVE_DIR="$BUILD_DIR/proot-image-native/arm64"
RUNTIME_DIR="$WORK/execution/andock"

"$ROOT/scripts/validate-andock-manifest.py" "$TEMPLATE_MANIFEST"
"$ROOT/scripts/build-andock-proot-image.sh"

mkdir -p "$RUNTIME_DIR" "$JNI_DIR/arm64-v8a"
cp "$TEMPLATE_MANIFEST" \
    "$RUNTIME_DIR/andock-ubuntu-arm64.ext4.manifest.json"
cp "$NATIVE_DIR/manifest.json" "$RUNTIME_DIR/andock-proot-arm64.manifest.json"
install -m 0755 "$NATIVE_DIR/usr/bin/proot" \
    "$JNI_DIR/arm64-v8a/libandee_proot.so"
install -m 0755 "$NATIVE_DIR/usr/libexec/andock/proot-launcher" \
    "$JNI_DIR/arm64-v8a/libandee_andock_launcher.so"
install -m 0755 "$NATIVE_DIR/usr/libexec/proot/loader" \
    "$JNI_DIR/arm64-v8a/libandee_proot_loader.so"
