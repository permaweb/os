#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

WORK="${1:?missing runtime work directory}"
JNI_DIR="${2:?missing Android JNI directory}"
TEMPLATE_DIR="$BUILD_DIR/andock-template/runtime"
TEMPLATE="$TEMPLATE_DIR/andock-ubuntu-arm64.ext4"
NATIVE_DIR="$BUILD_DIR/proot-image-native/arm64"
RUNTIME_DIR="$WORK/execution/andock"

if ! "$ROOT/scripts/validate-andock-template.py" "$TEMPLATE_DIR"; then
    mkdir -p "$TEMPLATE_DIR"
    "$ROOT/scripts/build-andock-template.sh" "$TEMPLATE"
    "$ROOT/scripts/validate-andock-template.py" "$TEMPLATE_DIR"
fi
"$ROOT/scripts/build-andock-proot-image.sh"

mkdir -p "$RUNTIME_DIR" "$JNI_DIR/arm64-v8a"
cp "$TEMPLATE_DIR/andock-ubuntu-arm64.ext4.simg" \
    "$RUNTIME_DIR/andock-ubuntu-arm64.ext4.simg"
cp "$TEMPLATE_DIR/andock-ubuntu-arm64.ext4.manifest.json" \
    "$RUNTIME_DIR/andock-ubuntu-arm64.ext4.manifest.json"
cp "$NATIVE_DIR/manifest.json" "$RUNTIME_DIR/andock-proot-arm64.manifest.json"
install -m 0755 "$NATIVE_DIR/usr/bin/proot" \
    "$JNI_DIR/arm64-v8a/libandee_proot.so"
install -m 0755 "$NATIVE_DIR/usr/libexec/andock/proot-launcher" \
    "$JNI_DIR/arm64-v8a/libandee_andock_launcher.so"
install -m 0755 "$NATIVE_DIR/usr/libexec/proot/loader" \
    "$JNI_DIR/arm64-v8a/libandee_proot_loader.so"
