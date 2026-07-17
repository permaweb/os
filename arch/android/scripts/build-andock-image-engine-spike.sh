#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_ROOT="$ROOT/android"
NATIVE_ROOT="$ROOT/native/andock-image-engine-probe"
BUILD_ROOT="${BUILD_DIR:-$ROOT/build}/andock-image-engine-spike"
DOWNLOAD_ROOT="$BUILD_ROOT/downloads"
SOURCE_ROOT="$BUILD_ROOT/sources"
JNI_ROOT="$BUILD_ROOT/jniLibs/arm64-v8a"

LWEXT4_REVISION="58bcf89a121b72d4fb66334f1693d3b30e4cb9c5"
LWEXT4_ARCHIVE_SHA256="8f7cce20f5dad2719cb22982e64c75069af51741555c98d34a247a5d8f154890"
LWEXT4_ARCHIVE="$DOWNLOAD_ROOT/lwext4-$LWEXT4_REVISION.tar.gz"
LWEXT4_SOURCE="$SOURCE_ROOT/lwext4-$LWEXT4_REVISION"
LWEXT4_URL="https://codeload.github.com/gkostka/lwext4/tar.gz/$LWEXT4_REVISION"

ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_SDK_ROOT/ndk/29.0.14206865}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"

mkdir -p "$DOWNLOAD_ROOT" "$SOURCE_ROOT" "$JNI_ROOT" "$BUILD_ROOT/host"
if [[ ! -f "$LWEXT4_ARCHIVE" ]]; then
    curl --fail --location --retry 3 --output "$LWEXT4_ARCHIVE" "$LWEXT4_URL"
fi
printf '%s  %s\n' "$LWEXT4_ARCHIVE_SHA256" "$LWEXT4_ARCHIVE" | shasum -a 256 -c -
tar -xzf "$LWEXT4_ARCHIVE" -C "$SOURCE_ROOT"
LWEXT4_XATTR="$LWEXT4_SOURCE/src/ext4_xattr.c"
patch -d "$LWEXT4_SOURCE" -p1 \
    < "$NATIVE_ROOT/patches/0001-fix-xattr-list-size-ub.patch"
if ! grep -q 'sizeof(struct ext4_xattr_list_entry) + name_len + 1' "$LWEXT4_XATTR"; then
    printf 'lwext4 xattr UB patch was not applied cleanly\n' >&2
    exit 1
fi

LWEXT4_SOURCES=("$LWEXT4_SOURCE"/src/*.c)
COMMON_FLAGS=(
    -std=c11
    -O2
    -g
    -fno-omit-frame-pointer
    -DCONFIG_USE_DEFAULT_CFG=0
    -I"$NATIVE_ROOT/include"
    -I"$LWEXT4_SOURCE/include"
    -Wall
    -Wextra
    -Werror
    -Wno-unused-function
    -Wno-unused-parameter
    -Wno-unused-but-set-variable
)

HOST_CC="${HOST_CC:-clang}"
"$HOST_CC" "${COMMON_FLAGS[@]}" \
    "$NATIVE_ROOT/andock_image_engine_probe.c" \
    "${LWEXT4_SOURCES[@]}" \
    -o "$BUILD_ROOT/host/andock-image-engine-probe"

HOST_IMAGE="$BUILD_ROOT/host/member.ext4"
"$BUILD_ROOT/host/andock-image-engine-probe" "$HOST_IMAGE" \
    | tee "$BUILD_ROOT/host/native-probe.txt"

"$HOST_CC" "${COMMON_FLAGS[@]}" \
    -O1 -fsanitize=address,undefined \
    "$NATIVE_ROOT/andock_image_engine_probe.c" \
    "${LWEXT4_SOURCES[@]}" \
    -o "$BUILD_ROOT/host/andock-image-engine-probe-sanitized"
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
    "$BUILD_ROOT/host/andock-image-engine-probe-sanitized" \
    "$BUILD_ROOT/host/member-sanitized.ext4" \
    > "$BUILD_ROOT/host/native-probe-sanitized.txt"

HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
TOOLCHAIN="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG"
if [[ ! -d "$TOOLCHAIN" ]]; then
    TOOLCHAINS=("$ANDROID_NDK_ROOT"/toolchains/llvm/prebuilt/*)
    if [[ ${#TOOLCHAINS[@]} -ne 1 || ! -d "${TOOLCHAINS[0]}" ]]; then
        printf 'Android NDK toolchain not found beneath: %s\n' \
            "$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt" >&2
        exit 1
    fi
    TOOLCHAIN="${TOOLCHAINS[0]}"
fi
ANDROID_CC="$TOOLCHAIN/bin/aarch64-linux-android29-clang"
"$ANDROID_CC" "${COMMON_FLAGS[@]}" \
    -shared -fPIC \
    "$NATIVE_ROOT/andock_image_engine_probe.c" \
    "${LWEXT4_SOURCES[@]}" \
    -Wl,--build-id=sha1 \
    -o "$JNI_ROOT/libandock_image_engine_probe.so"

if [[ "${1:-}" != "--native-only" ]]; then
    (
        cd "$ANDROID_ROOT"
        ANDROID_HOME="$ANDROID_SDK_ROOT" \
        ANDROID_SDK_ROOT="$ANDROID_SDK_ROOT" \
        JAVA_HOME="$JAVA_HOME" \
            ./gradlew \
                :andock-image-engine-spike:assembleDebug \
                :andock-image-engine-spike:assembleAndroidTest
    )
fi

shasum -a 256 \
    "$LWEXT4_ARCHIVE" \
    "$BUILD_ROOT/host/andock-image-engine-probe" \
    "$BUILD_ROOT/host/andock-image-engine-probe-sanitized" \
    "$JNI_ROOT/libandock_image_engine_probe.so"

if [[ "${1:-}" != "--native-only" ]]; then
    shasum -a 256 \
        "$ANDROID_ROOT/andock-image-engine-spike/build/outputs/apk/debug/andock-image-engine-spike-debug.apk" \
        "$ANDROID_ROOT/andock-image-engine-spike/build/outputs/apk/androidTest/debug/andock-image-engine-spike-debug-androidTest.apk"
fi
