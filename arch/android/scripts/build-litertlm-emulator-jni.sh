#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

LITERT_LM_REVISION='924e79c91542761242244e4f1651851f822e4cbb'
XNNPACK_REVISION='53a1797ba4360cbde068f2a984652be0f0b7b6fe'
BAZELISK_VERSION='1.27.0'
BAZELISK_SHA256='8bf08c894ccc19ef37f286e58184c3942c58cb08da955e990522703526ddb720'
JNI_SHA256='281e551ceb06db69821ac02b2f288a40c9b2912f84e7b5b59a2fa5d068e0372e'
CONSTRAINT_PROVIDER_SHA256='d305460ed571ba0e527f9f75e34de4d8b13d5d6af906431c36d04795f14411ca'
SOURCE_ROOT="$BUILD_DIR/litertlm-emulator-source"
LITERT_LM_ROOT="$SOURCE_ROOT/litert-lm"
XNNPACK_ROOT="$SOURCE_ROOT/xnnpack"
BAZELISK="$BUILD_DIR/downloads/bazelisk-darwin-arm64-$BAZELISK_VERSION"
OUTPUT="$BUILD_DIR/litertlm-emulator/liblitertlm_jni.so"
CONSTRAINT_OUTPUT="$BUILD_DIR/litertlm-emulator/libGemmaModelConstraintProvider.so"
NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_SDK_ROOT/ndk/29.0.14206865}"

require_tool curl
require_tool git
require_tool git-lfs
require_tool plutil
require_tool shasum
require_tool xcrun

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "the SME-disabled JNI is only needed for Apple's ARM64 Android emulator" >&2
    exit 1
fi

mkdir -p "$(dirname "$BAZELISK")" "$SOURCE_ROOT" "$(dirname "$OUTPUT")"
if [ ! -f "$BAZELISK" ] || \
        [ "$(shasum -a 256 "$BAZELISK" | awk '{print $1}')" != "$BAZELISK_SHA256" ]; then
    rm -f "$BAZELISK"
    curl --fail --location --retry 3 \
        --output "$BAZELISK" \
        "https://github.com/bazelbuild/bazelisk/releases/download/v$BAZELISK_VERSION/bazelisk-darwin-arm64"
fi
if [ "$(shasum -a 256 "$BAZELISK" | awk '{print $1}')" != "$BAZELISK_SHA256" ]; then
    echo "Bazelisk checksum mismatch: $BAZELISK" >&2
    exit 1
fi
chmod 755 "$BAZELISK"
MACOS_SDK_VERSION="$(
    plutil -extract Version raw "$(xcrun --show-sdk-path --sdk macosx)/SDKSettings.plist"
)"

checkout_exact() {
    local directory="$1"
    local repository="$2"
    local revision="$3"
    if [ ! -d "$directory/.git" ]; then
        rm -rf "$directory"
        git clone --filter=blob:none --no-checkout "$repository" "$directory"
    fi
    git -C "$directory" fetch --depth 1 origin "$revision"
    git -C "$directory" checkout --detach --force "$revision"
    git -C "$directory" clean -dffx
    if [ "$(git -C "$directory" rev-parse HEAD)" != "$revision" ]; then
        echo "source checkout did not resolve to $revision: $directory" >&2
        exit 1
    fi
}

checkout_exact \
    "$LITERT_LM_ROOT" \
    'https://github.com/google-ai-edge/LiteRT-LM.git' \
    "$LITERT_LM_REVISION"
checkout_exact \
    "$XNNPACK_ROOT" \
    'https://github.com/google/XNNPACK.git' \
    "$XNNPACK_REVISION"
CONSTRAINT_PROVIDER="$LITERT_LM_ROOT/prebuilt/android_arm64/libGemmaModelConstraintProvider.so"
git -C "$LITERT_LM_ROOT" lfs install --local
git -C "$LITERT_LM_ROOT" lfs pull \
    --include='prebuilt/android_arm64/libGemmaModelConstraintProvider.so' \
    --exclude=''
git -C "$LITERT_LM_ROOT" lfs checkout \
    'prebuilt/android_arm64/libGemmaModelConstraintProvider.so'
if [ "$(shasum -a 256 "$CONSTRAINT_PROVIDER" | awk '{print $1}')" != \
        "$CONSTRAINT_PROVIDER_SHA256" ]; then
    echo "LiteRT-LM constraint provider checksum mismatch: $CONSTRAINT_PROVIDER" >&2
    exit 1
fi
git -C "$XNNPACK_ROOT" apply --check "$ROOT/scripts/xnnpack-emulator-disable-sme.patch"
git -C "$XNNPACK_ROOT" apply "$ROOT/scripts/xnnpack-emulator-disable-sme.patch"

(
    cd "$LITERT_LM_ROOT"
    ANDROID_HOME="$ANDROID_SDK_ROOT" \
    ANDROID_NDK_HOME="$NDK_ROOT" \
    "$BAZELISK" \
        --output_user_root="$BUILD_DIR/bazel-litertlm-emulator" \
        build \
        --config=android_arm64 \
        --macos_sdk_version="$MACOS_SDK_VERSION" \
        --override_repository="XNNPACK=$XNNPACK_ROOT" \
        --define=xnn_enable_arm_sme=false \
        --define=xnn_enable_arm_sme2=false \
        //kotlin/java/com/google/ai/edge/litertlm/jni:litertlm_jni
)

BUILT="$LITERT_LM_ROOT/bazel-bin/kotlin/java/com/google/ai/edge/litertlm/jni/liblitertlm_jni.so"
if [ "$(shasum -a 256 "$BUILT" | awk '{print $1}')" != "$JNI_SHA256" ]; then
    echo "unexpected SME-disabled LiteRT-LM JNI checksum: $BUILT" >&2
    exit 1
fi
cp "$BUILT" "$OUTPUT.tmp"
chmod 755 "$OUTPUT.tmp"
mv "$OUTPUT.tmp" "$OUTPUT"
cp "$CONSTRAINT_PROVIDER" "$CONSTRAINT_OUTPUT.tmp"
chmod 755 "$CONSTRAINT_OUTPUT.tmp"
mv "$CONSTRAINT_OUTPUT.tmp" "$CONSTRAINT_OUTPUT"

printf '%s\n' \
    "litert-lm-revision=$LITERT_LM_REVISION" \
    "xnnpack-revision=$XNNPACK_REVISION" \
    "liblitertlm-jni-sha256=$JNI_SHA256" \
    "output=$OUTPUT" \
    "constraint-provider-sha256=$CONSTRAINT_PROVIDER_SHA256" \
    "constraint-provider-output=$CONSTRAINT_OUTPUT"
