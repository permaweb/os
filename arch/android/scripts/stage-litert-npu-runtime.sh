#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

JNI_DIR="${1:?usage: $0 JNI_DIR}"
LITERT_VERSION='2.2.0'
LITERT_NPU_SHA256='b4c8380df3e9652677dbb93a5aad4499eb756a9b7d9651a9baacb122faadbf0d'
LITERT_NPU_URL="https://github.com/google-ai-edge/LiteRT/releases/download/v${LITERT_VERSION}/litert_npu_runtime_libraries.zip"
CACHE_DIR="$BUILD_DIR/downloads"
ARCHIVE="$CACHE_DIR/litert-npu-runtime-libraries-${LITERT_VERSION}.zip"
ENTRY='google_tensor_runtime/src/main/jni/arm64-v8a/libLiteRtDispatch_GoogleTensor.so'
OUTPUT="$JNI_DIR/arm64-v8a/libLiteRtDispatch_GoogleTensor.so"

require_tool curl
require_tool shasum
require_tool unzip

mkdir -p "$CACHE_DIR" "$(dirname "$OUTPUT")"
if [ ! -f "$ARCHIVE" ] || \
        [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$LITERT_NPU_SHA256" ]; then
    rm -f "$ARCHIVE"
    curl --fail --location --retry 3 --output "$ARCHIVE" "$LITERT_NPU_URL"
fi
if [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$LITERT_NPU_SHA256" ]; then
    echo "LiteRT NPU runtime checksum mismatch: $ARCHIVE" >&2
    exit 1
fi

TMP="$(mktemp "$OUTPUT.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
unzip -p "$ARCHIVE" "$ENTRY" > "$TMP"
if [ "$(wc -c < "$TMP" | tr -d ' ')" -ne 314624 ]; then
    echo "unexpected Google Tensor LiteRT dispatch runtime size" >&2
    exit 1
fi
chmod 755 "$TMP"
mv "$TMP" "$OUTPUT"
trap - EXIT

echo "LiteRT Google Tensor NPU dispatch: $OUTPUT"
