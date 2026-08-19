#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

MODEL="${MODEL:?set MODEL to a local .litertlm file}"
MODEL_ID="${MODEL_ID:-$(basename "$MODEL" .litertlm)}"
MODEL_CONTEXT_TOKENS="${MODEL_CONTEXT_TOKENS:-1024}"
EMULATOR_BACKEND="${EMULATOR_BACKEND:-cpu}"
ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to the emulator serial}"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28739}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-600}"
PACKAGE='org.permaweb.andee'
OUT="$BUILD_DIR/andee-inference-emulator"
RUN_STARTED="$(date '+%m-%d %H:%M:%S.000')"

require_tool adb
require_tool curl
require_tool jq
require_tool openssl
require_tool shasum
require_tool unzip

if [ "$(adb -s "$ADB_SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]; then
    echo "refusing to run emulator proof against non-emulator target $ADB_SERIAL" >&2
    exit 1
fi
if [ "$EMULATOR_BACKEND" != "cpu" ] && [ "$EMULATOR_BACKEND" != "gpu" ]; then
    echo "EMULATOR_BACKEND must be cpu or gpu" >&2
    exit 1
fi
if [[ ! "$MODEL_CONTEXT_TOKENS" =~ ^[0-9]+$ ]] || \
        [ "$MODEL_CONTEXT_TOKENS" -lt 128 ] || \
        [ "$MODEL_CONTEXT_TOKENS" -gt 32768 ]; then
    echo "MODEL_CONTEXT_TOKENS must be between 128 and 32768" >&2
    exit 1
fi
if [ ! -f "$APK" ]; then
    echo "APK missing: $APK" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cleanup() {
    adb -s "$ADB_SERIAL" forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "${KEEP_ANDEE_RUNNING:-0}" != "1" ]; then
        adb -s "$ADB_SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
capture_logs() {
    adb -s "$ADB_SERIAL" logcat -d -T "$RUN_STARTED" -v threadtime \
        AndeeInference:V LiteRT:V \
        AndroidRuntime:V DEBUG:V '*:S' > "$OUT/logcat.txt" 2>&1 || true
    adb -s "$ADB_SERIAL" logcat -b crash -d -T "$RUN_STARTED" -v threadtime \
        > "$OUT/logcat-crash.txt" 2>&1 || true
}
finish() {
    status=$?
    capture_logs
    cleanup
    exit "$status"
}
trap finish EXIT

adb -s "$ADB_SERIAL" install -r "$APK" > "$OUT/install.txt"
MODEL="$MODEL" MODEL_ID="$MODEL_ID" MODEL_BACKENDS="$EMULATOR_BACKEND" \
    ADB_SERIAL="$ADB_SERIAL" \
    "$ROOT/scripts/andee-inference-model-install.sh" | tee "$OUT/model-install.txt"

MODEL_FILE="$(basename "$MODEL")"
MODEL_DIGEST="$(openssl dgst -sha256 -binary "$MODEL" | \
    openssl base64 -A | tr '+/' '-_' | tr -d '=')"
APK_DIGEST="$(shasum -a 256 "$APK" | awk '{print $1}')"
EMBEDDED_JNI_DIGEST="$(
    unzip -p "$APK" 'lib/arm64-v8a/liblitertlm_jni.so' | \
        shasum -a 256 | awk '{print $1}'
)"
EMBEDDED_CONSTRAINT_PROVIDER_DIGEST="$(
    unzip -p "$APK" 'lib/arm64-v8a/libGemmaModelConstraintProvider.so' | \
        shasum -a 256 | awk '{print $1}'
)"
jq -n \
    --arg id "$MODEL_ID" \
    --arg file "$MODEL_FILE" \
    --arg digest "$MODEL_DIGEST" \
    --arg backend "$EMULATOR_BACKEND" \
    --argjson context "$MODEL_CONTEXT_TOKENS" \
    '{
      "andee-inference": {
        "backend": $backend,
        "models": [{
          "id": $id,
          "file": $file,
          "sha256": $digest,
          "backends": [$backend],
          "max-context-tokens": $context,
          "max-output-tokens": 128
        }]
      }
    }' > "$OUT/next.json"

adb -s "$ADB_SERIAL" shell am force-stop "$PACKAGE" >/dev/null
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" mkdir -p no_backup/boot-config no_backup/run
adb -s "$ADB_SERIAL" shell -T \
    "run-as $PACKAGE sh -c 'cat > no_backup/boot-config/next.json'" \
    < "$OUT/next.json"
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" rm -f \
    no_backup/boot-config/active.json \
    no_backup/boot-config/effective.json \
    no_backup/run/hyperbeam.stdout \
    no_backup/run/hyperbeam.stderr
adb -s "$ADB_SERIAL" shell am start -W -n "$PACKAGE/.OrnamentActivity" > "$OUT/activity.txt"

STARTED=0
for _ in $(seq 1 "$PROBE_TIMEOUT"); do
    adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        > "$OUT/hyperbeam.stdout" 2>/dev/null || true
    adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
        > "$OUT/hyperbeam.stderr" 2>/dev/null || true
    if grep -q 'AndEE HyperBEAM node started' "$OUT/hyperbeam.stdout"; then
        STARTED=1
        break
    fi
    sleep 1
done
if [ "$STARTED" != "1" ]; then
    echo "AndEE HyperBEAM did not start" >&2
    exit 1
fi

adb -s "$ADB_SERIAL" forward "tcp:$HOST_PORT" tcp:8734 > "$OUT/adb-forward.txt"
BASE_URL="http://127.0.0.1:$HOST_PORT"
curl -fsS --max-time "$PROBE_TIMEOUT" \
    -H 'Accept: application/json' \
    "$BASE_URL/~inference@1.0/health" \
    > "$OUT/health-before.json"
jq -n --arg model "local/$MODEL_ID" '{
  model: $model,
  messages: [{
    role: "user",
    content: "Call Send with body ANDEE-LOCAL-INFERENCE-OK"
  }],
  tools: [{
    type: "function",
    function: {
      name: "Send",
      description: "Send a message to the conversation",
      parameters: {
        type: "object",
        properties: {body: {type: "string"}},
        required: ["body"]
      }
    }
  }],
  tool_choice: {type: "function", function: {name: "Send"}},
  temperature: 0,
  max_tokens: 64,
  stream: false
}' > "$OUT/request.json"
COMPLETION_STATUS="$(curl -sS --max-time "$PROBE_TIMEOUT" \
    -o "$OUT/completion.json" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --data-binary @"$OUT/request.json" \
    "$BASE_URL/~inference@1.0/completions")"
jq '.max_tokens = 1' "$OUT/request.json" > "$OUT/length-request.json"
LENGTH_STATUS="$(curl -sS --max-time "$PROBE_TIMEOUT" \
    -o "$OUT/length-completion.json" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --data-binary @"$OUT/length-request.json" \
    "$BASE_URL/~inference@1.0/completions")"
curl -fsS --max-time "$PROBE_TIMEOUT" \
    -H 'Accept: application/json' \
    "$BASE_URL/~inference@1.0/health" \
    > "$OUT/health.json"

jq -n \
    --argjson health "$(cat "$OUT/health.json")" \
    --argjson completion "$(cat "$OUT/completion.json")" \
    --argjson lengthCompletion "$(cat "$OUT/length-completion.json")" \
    --arg completionStatus "$COMPLETION_STATUS" \
    --arg lengthStatus "$LENGTH_STATUS" \
    --arg emulatorBackend "$EMULATOR_BACKEND" \
    --arg expectedModel "$MODEL_ID" \
    --arg expectedDigest "$MODEL_DIGEST" \
    --arg apkSha256 "$APK_DIGEST" \
    --arg embeddedJniSha256 "$EMBEDDED_JNI_DIGEST" \
    --arg embeddedConstraintProviderSha256 "$EMBEDDED_CONSTRAINT_PROVIDER_DIGEST" \
    '{
      scenario: "andee-local-litert-lm-emulator",
      emulator_backend: $emulatorBackend,
      hardware_npu_claimed: false,
      apk_sha256: $apkSha256,
      embedded_liblitertlm_jni_sha256: $embeddedJniSha256,
      embedded_constraint_provider_sha256: $embeddedConstraintProviderSha256,
      model_ready: ($health.models[0].ready == true),
      completion_nonempty: (
        (($completion.choices[0].message.content // "") | length > 0) or
        (($completion.choices[0].message.tool_calls // []) | length > 0)
      ),
      tool_call: ($completion.choices[0].message.tool_calls[0] // null),
      requested_backend: $completion["andee-execution"]["requested-backend"],
      model: $completion.model,
      model_digest: $completion["andee-execution"]["model-sha256"],
      completion_status: $completionStatus,
      truncated_completion_status: $lengthStatus,
      truncated_finish_reason: $lengthCompletion.choices[0].finish_reason,
      passed: (
        $completionStatus == "200" and
        $lengthStatus == "200" and
        $lengthCompletion.choices[0].finish_reason == "length" and
        $health.backend == $emulatorBackend and
        $health.models[0].ready == true and
        $completion.model == $expectedModel and
        $completion["andee-execution"]["requested-backend"] == $emulatorBackend and
        $completion["andee-execution"]["model-sha256"] == $expectedDigest and
        (
          (($completion.choices[0].message.content // "") | length > 0) or
          (($completion.choices[0].message.tool_calls // []) | length > 0)
        )
      )
    }' | tee "$OUT/verdict.json"
jq -e '.passed == true' "$OUT/verdict.json" >/dev/null

echo "inference emulator evidence: $OUT"
