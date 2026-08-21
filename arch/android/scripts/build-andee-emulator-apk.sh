#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
RUNTIME="$ROOT/android/app/src/main/assets/andee-runtime.zip"
JNI="$BUILD_DIR/litertlm-emulator/liblitertlm_jni.so"
CONSTRAINT_PROVIDER="$BUILD_DIR/litertlm-emulator/libGemmaModelConstraintProvider.so"
OUTPUT="$BUILD_DIR/app-debug-emulator.apk"
EVIDENCE="$BUILD_DIR/andee-inference-emulator-apk.json"
ZIPALIGN="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION/zipalign"
APKSIGNER="$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION/apksigner"
DEBUG_KEYSTORE="${ANDEE_DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"

require_tool jq
require_tool shasum
require_tool unzip
require_tool zip

"$ROOT/scripts/build-litertlm-emulator-jni.sh"
if [ ! -f "$APK" ] || [ ! -f "$RUNTIME" ]; then
    echo "build the verified release-shaped debug APK before the emulator override" >&2
    exit 1
fi
if [ ! -x "$ZIPALIGN" ] || [ ! -x "$APKSIGNER" ]; then
    echo "missing Android build-tools $BUILD_TOOLS_VERSION" >&2
    exit 1
fi
if [ ! -f "$DEBUG_KEYSTORE" ]; then
    echo "missing Android debug keystore: $DEBUG_KEYSTORE" >&2
    exit 1
fi

WORK="$(mktemp -d "$BUILD_DIR/andee-emulator-apk.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$APK" "$WORK/unsigned.apk"
zip -q -d "$WORK/unsigned.apk" \
    'lib/arm64-v8a/liblitertlm_jni.so' \
    'lib/arm64-v8a/libGemmaModelConstraintProvider.so' \
    'META-INF/*' || true
mkdir -p "$WORK/replacement/lib/arm64-v8a"
cp "$JNI" "$WORK/replacement/lib/arm64-v8a/liblitertlm_jni.so"
cp "$CONSTRAINT_PROVIDER" \
    "$WORK/replacement/lib/arm64-v8a/libGemmaModelConstraintProvider.so"
TZ=UTC touch -t 198001010000 \
    "$WORK/replacement/lib/arm64-v8a/liblitertlm_jni.so" \
    "$WORK/replacement/lib/arm64-v8a/libGemmaModelConstraintProvider.so"
(
    cd "$WORK/replacement"
    zip -q -X -0 "$WORK/unsigned.apk" \
        lib/arm64-v8a/liblitertlm_jni.so \
        lib/arm64-v8a/libGemmaModelConstraintProvider.so
)
"$ZIPALIGN" -f -p 4 "$WORK/unsigned.apk" "$WORK/aligned.apk"
"$APKSIGNER" sign \
    --ks "$DEBUG_KEYSTORE" \
    --ks-pass pass:android \
    --key-pass pass:android \
    --out "$OUTPUT" \
    "$WORK/aligned.apk"

JNI_SHA256="$(shasum -a 256 "$JNI" | awk '{print $1}')"
EMBEDDED_JNI_SHA256="$(
    unzip -p "$OUTPUT" 'lib/arm64-v8a/liblitertlm_jni.so' | shasum -a 256 | awk '{print $1}'
)"
if [ "$EMBEDDED_JNI_SHA256" != "$JNI_SHA256" ]; then
    echo "emulator APK JNI checksum mismatch: $OUTPUT" >&2
    exit 1
fi
CONSTRAINT_PROVIDER_SHA256="$(shasum -a 256 "$CONSTRAINT_PROVIDER" | awk '{print $1}')"
EMBEDDED_CONSTRAINT_PROVIDER_SHA256="$(
    unzip -p "$OUTPUT" 'lib/arm64-v8a/libGemmaModelConstraintProvider.so' | \
        shasum -a 256 | awk '{print $1}'
)"
if [ "$EMBEDDED_CONSTRAINT_PROVIDER_SHA256" != "$CONSTRAINT_PROVIDER_SHA256" ]; then
    echo "emulator APK constraint provider checksum mismatch: $OUTPUT" >&2
    exit 1
fi
APK_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
JAVA_HOME="$JAVA_HOME" "$ROOT/scripts/verify-generic-andee-artifact.py" \
    --apk "$OUTPUT" \
    --expected-runtime-sha256 "$(shasum -a 256 "$RUNTIME" | awk '{print $1}')" \
    --aapt2 "$ANDROID_SDK_ROOT/build-tools/$BUILD_TOOLS_VERSION/aapt2" \
    --apksigner "$APKSIGNER" \
    --evidence "$BUILD_DIR/andee-emulator-apk-composition.json" >/dev/null
jq -n \
    --arg apk "$OUTPUT" \
    --arg apkSha256 "$APK_SHA256" \
    --arg jniSha256 "$JNI_SHA256" \
    --arg embeddedJniSha256 "$EMBEDDED_JNI_SHA256" \
    --arg constraintProviderSha256 "$CONSTRAINT_PROVIDER_SHA256" \
    --arg embeddedConstraintProviderSha256 "$EMBEDDED_CONSTRAINT_PROVIDER_SHA256" \
    --arg litertLmRevision '924e79c91542761242244e4f1651851f822e4cbb' \
    --arg xnnpackRevision '53a1797ba4360cbde068f2a984652be0f0b7b6fe' \
    '{
      purpose: "Apple-ARM64-emulator-only SME-disabled LiteRT-LM JNI override",
      apk: $apk,
      apk_sha256: $apkSha256,
      source_liblitertlm_jni_sha256: $jniSha256,
      embedded_liblitertlm_jni_sha256: $embeddedJniSha256,
      embedded_jni_matches_source: ($embeddedJniSha256 == $jniSha256),
      source_constraint_provider_sha256: $constraintProviderSha256,
      embedded_constraint_provider_sha256: $embeddedConstraintProviderSha256,
      embedded_constraint_provider_matches_source: (
        $embeddedConstraintProviderSha256 == $constraintProviderSha256
      ),
      litert_lm_revision: $litertLmRevision,
      xnnpack_revision: $xnnpackRevision,
      hardware_release_artifact: false,
      generic_artifact_scan: "passed"
    }' | tee "$EVIDENCE"
