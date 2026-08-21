#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

MODEL="${MODEL:?set MODEL to a local .litertlm or .gguf file}"
case "$MODEL" in
    *.litertlm) INFERRED_RUNTIME='litert-lm' ;;
    *.gguf) INFERRED_RUNTIME='llama-cpp' ;;
    *) INFERRED_RUNTIME='' ;;
esac
MODEL_RUNTIME="${MODEL_RUNTIME:-$INFERRED_RUNTIME}"
MODEL_ID="${MODEL_ID:?set MODEL_ID to the model's 43-character Arweave id}"
MODEL_NAME="${MODEL_NAME:-$(basename "${MODEL%.*}")}"
MODEL_BACKEND="${MODEL_BACKEND:-cpu}"
ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to the exact Android target serial}"
PACKAGE='org.permaweb.andee'

require_tool adb
require_tool openssl
require_tool shasum

if [ ! -f "$MODEL" ] || [ -z "$MODEL_RUNTIME" ]; then
    echo "MODEL must name a local .litertlm or .gguf file: $MODEL" >&2
    exit 1
fi
if { [ "$MODEL_RUNTIME" = "litert-lm" ] && [[ "$MODEL" != *.litertlm ]]; } ||
        { [ "$MODEL_RUNTIME" = "llama-cpp" ] && [[ "$MODEL" != *.gguf ]]; } ||
        { [ "$MODEL_RUNTIME" != "litert-lm" ] && [ "$MODEL_RUNTIME" != "llama-cpp" ]; }; then
    echo "MODEL_RUNTIME does not match MODEL: $MODEL_RUNTIME / $MODEL" >&2
    exit 1
fi
if [[ ! "$MODEL_ID" =~ ^[A-Za-z0-9_-]{43}$ ]]; then
    echo "MODEL_ID must be a 43-character Arweave id: $MODEL_ID" >&2
    exit 1
fi
if [[ ! "$MODEL_NAME" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    echo "invalid MODEL_NAME: $MODEL_NAME" >&2
    exit 1
fi
if [[ ! "$MODEL_BACKEND" =~ ^(cpu|gpu|npu)$ ]]; then
    echo "MODEL_BACKEND must be cpu, gpu, or npu" >&2
    exit 1
fi
if [ "$MODEL_RUNTIME" = 'llama-cpp' ] && [ "$MODEL_BACKEND" != 'cpu' ]; then
    echo "llama-cpp models require MODEL_BACKEND=cpu" >&2
    exit 1
fi
if [ "$(adb -s "$ADB_SERIAL" get-state 2>/dev/null)" != "device" ]; then
    echo "Android target is not available: $ADB_SERIAL" >&2
    exit 1
fi
if [ "$(adb -s "$ADB_SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ] && \
        [ "${ANDEE_ALLOW_PHYSICAL_INFERENCE_INSTALL:-0}" != "1" ]; then
    echo "refusing physical-device model installation without ANDEE_ALLOW_PHYSICAL_INFERENCE_INSTALL=1" >&2
    exit 1
fi
if ! adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" true >/dev/null 2>&1; then
    echo "the debuggable AndEE APK is not installed on $ADB_SERIAL" >&2
    exit 1
fi

case "$MODEL_RUNTIME" in
    litert-lm) FILENAME="$MODEL_ID.litertlm" ;;
    llama-cpp) FILENAME="$MODEL_ID.gguf" ;;
esac
REMOTE="no_backup/inference-models/$FILENAME"
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" mkdir -p no_backup/inference-models
LOCAL_BYTES="$(wc -c < "$MODEL" | tr -d ' ')"
REMOTE_AVAILABLE_KB="$(adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" \
    df -k no_backup/inference-models | awk 'NR == 2 {print $(NF - 2)}' | tr -d '\r')"
if [[ ! "$REMOTE_AVAILABLE_KB" =~ ^[0-9]+$ ]] || \
        [ "$((REMOTE_AVAILABLE_KB * 1024))" -lt "$LOCAL_BYTES" ]; then
    echo "insufficient app-private storage for model: bytes=$LOCAL_BYTES available-kb=${REMOTE_AVAILABLE_KB:-unknown}" >&2
    exit 1
fi
adb -s "$ADB_SERIAL" shell -T \
    "run-as $PACKAGE sh -c 'cat > $REMOTE.tmp'" < "$MODEL"
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" mv "$REMOTE.tmp" "$REMOTE"
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" chmod 400 "$REMOTE"
REMOTE_BYTES="$(adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" wc -c "$REMOTE" | \
    awk '{print $1}' | tr -d '\r')"
if [ "$REMOTE_BYTES" != "$LOCAL_BYTES" ]; then
    echo "model copy size mismatch: local=$LOCAL_BYTES remote=$REMOTE_BYTES" >&2
    exit 1
fi

SHA256_HEX="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
REMOTE_SHA256_HEX="$(adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" \
    sha256sum "$REMOTE" | awk '{print $1}' | tr -d '\r')"
if [ "$REMOTE_SHA256_HEX" != "$SHA256_HEX" ]; then
    echo "model copy digest mismatch: local=$SHA256_HEX remote=$REMOTE_SHA256_HEX" >&2
    exit 1
fi
SHA256_BASE64URL="$(openssl dgst -sha256 -binary "$MODEL" | \
    openssl base64 -A | tr '+/' '-_' | tr -d '=')"

printf '%s\n' \
    "model-id=$MODEL_ID" \
    "model-name=$MODEL_NAME" \
    "model-bytes=$LOCAL_BYTES" \
    "model-sha256-hex=$SHA256_HEX" \
    "model-sha256-base64url=$SHA256_BASE64URL" \
    "model-runtime=$MODEL_RUNTIME" \
    "model-backend=$MODEL_BACKEND" \
    "adb-serial=$ADB_SERIAL"
