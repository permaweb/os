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
MODEL_ID="${MODEL_ID:?set MODEL_ID to the 43-character Arweave model id}"
MODEL_NAME="${MODEL_NAME:-$(basename "${MODEL%.*}")}"
MODEL_CONTEXT_TOKENS="${MODEL_CONTEXT_TOKENS:-1024}"
EMULATOR_BACKEND="${EMULATOR_BACKEND:-cpu}"
MODEL_GATEWAY="${MODEL_GATEWAY:-}"
MATERIALIZE_FROM_GATEWAY="${MATERIALIZE_FROM_GATEWAY:-0}"
ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to the emulator serial}"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28739}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-600}"
COMPLETION_REPETITIONS="${COMPLETION_REPETITIONS:-1}"
COLD_REBOOT_AFTER_INSTALL="${COLD_REBOOT_AFTER_INSTALL:-0}"
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
if [[ ! "$COMPLETION_REPETITIONS" =~ ^[1-3]$ ]]; then
    echo "COMPLETION_REPETITIONS must be between 1 and 3" >&2
    exit 1
fi
if [ "$COLD_REBOOT_AFTER_INSTALL" != '0' ] && [ "$COLD_REBOOT_AFTER_INSTALL" != '1' ]; then
    echo "COLD_REBOOT_AFTER_INSTALL must be 0 or 1" >&2
    exit 1
fi
if [ "$MATERIALIZE_FROM_GATEWAY" != '0' ] && \
        [ "$MATERIALIZE_FROM_GATEWAY" != '1' ]; then
    echo "MATERIALIZE_FROM_GATEWAY must be 0 or 1" >&2
    exit 1
fi
if [ "$MATERIALIZE_FROM_GATEWAY" = '1' ] && \
        [[ ! "$MODEL_GATEWAY" =~ ^https?://[^/?#]+(:[0-9]+)?$ ]]; then
    echo "MODEL_GATEWAY must be an HTTP(S) origin" >&2
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
if [ "$MATERIALIZE_FROM_GATEWAY" = '1' ]; then
    printf 'model materialization delegated to %s/%s\n' \
        "$MODEL_GATEWAY" "$MODEL_ID" | tee "$OUT/model-install.txt"
else
    MODEL="$MODEL" MODEL_ID="$MODEL_ID" MODEL_RUNTIME="$MODEL_RUNTIME" \
        MODEL_NAME="$MODEL_NAME" MODEL_BACKEND="$EMULATOR_BACKEND" \
        ADB_SERIAL="$ADB_SERIAL" \
        "$ROOT/scripts/andee-inference-model-install.sh" | tee "$OUT/model-install.txt"
fi
if [ "$COLD_REBOOT_AFTER_INSTALL" = '1' ]; then
    adb -s "$ADB_SERIAL" reboot
    adb -s "$ADB_SERIAL" wait-for-device
    BOOTED=0
    for _ in $(seq 1 240); do
        if [ "$(adb -s "$ADB_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = '1' ]; then
            BOOTED=1
            break
        fi
        sleep 1
    done
    if [ "$BOOTED" != '1' ]; then
        echo "Android did not reboot after model installation" >&2
        exit 1
    fi
fi
adb -s "$ADB_SERIAL" shell cat /proc/meminfo > "$OUT/meminfo-prestart.txt"

MODEL_BYTES="$(wc -c < "$MODEL" | tr -d ' ')"
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
    --arg name "$MODEL_NAME" \
    --arg digest "$MODEL_DIGEST" \
    --arg backend "$EMULATOR_BACKEND" \
    --arg runtime "$MODEL_RUNTIME" \
    --arg gateway "$MODEL_GATEWAY" \
    --argjson bytes "$MODEL_BYTES" \
    --argjson context "$MODEL_CONTEXT_TOKENS" \
    '(if $gateway == "" then {} else {gateway: $gateway} end) * {
      "inference-providers": {
        "local-andee": {
          "inference-device": "andee-inference@1.0",
          "default-model": $name,
          "models": [{
            "id": $name,
            "model-id": $id,
            "bytes": $bytes,
            "sha256": $digest,
            "runtime": $runtime,
            "backend": $backend,
            "max-context-tokens": $context,
            "max-output-tokens": 128
          }]
        }
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
    "$BASE_URL/~andee-inference@1.0/health" \
    > "$OUT/health-before.json"
adb -s "$ADB_SERIAL" shell cat /proc/meminfo > "$OUT/meminfo-before.txt"
jq -n --arg model "$MODEL_NAME" '{
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
    "$BASE_URL/~andee-inference@1.0/completions")"
printf '%s\n' "$COMPLETION_STATUS" > "$OUT/completion-status.txt"
if [ "$COMPLETION_REPETITIONS" -gt 1 ]; then
    for repetition in $(seq 2 "$COMPLETION_REPETITIONS"); do
        curl -sS --max-time "$PROBE_TIMEOUT" \
            -o "$OUT/completion-$repetition.json" \
            -w '%{http_code}\n' \
            -H 'Accept: application/json' \
            -H 'Content-Type: application/json' \
            --data-binary @"$OUT/request.json" \
            "$BASE_URL/~andee-inference@1.0/completions" \
            > "$OUT/completion-$repetition-status.txt"
    done
fi
CONTINUATION_STATUS='not-run'
if [ "$MODEL_RUNTIME" = 'llama-cpp' ] && [ "$COMPLETION_STATUS" = '200' ]; then
    jq -n \
        --arg model "$MODEL_NAME" \
        --argjson first "$(cat "$OUT/completion.json")" \
        --argjson original "$(cat "$OUT/request.json")" \
        '{
          model: $model,
          messages: (
            $original.messages +
            [$first.choices[0].message] +
            [{
              role: "tool",
              tool_call_id: $first.choices[0].message.tool_calls[0].id,
              content: "delivered"
            }]
          ),
          tools: $original.tools,
          tool_choice: "none",
          temperature: 0,
          max_tokens: 64,
          stream: false
        }' > "$OUT/continuation-request.json"
    CONTINUATION_STATUS="$(curl -sS --max-time "$PROBE_TIMEOUT" \
        -o "$OUT/continuation.json" -w '%{http_code}' \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        --data-binary @"$OUT/continuation-request.json" \
        "$BASE_URL/~andee-inference@1.0/completions")"
fi
if [ ! -f "$OUT/continuation.json" ]; then
    printf '%s\n' '{}' > "$OUT/continuation.json"
fi
if [ "$MODEL_RUNTIME" = 'llama-cpp' ]; then
    jq '{
      model,
      messages: [{role: "user", content: "Reply with exactly two words"}],
      temperature: 0,
      max_tokens: 1,
      stream: false
    }' "$OUT/request.json" > "$OUT/length-request.json"
else
    jq '.max_tokens = 1' "$OUT/request.json" > "$OUT/length-request.json"
fi
LENGTH_STATUS="$(curl -sS --max-time "$PROBE_TIMEOUT" \
    -o "$OUT/length-completion.json" -w '%{http_code}' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --data-binary @"$OUT/length-request.json" \
    "$BASE_URL/~andee-inference@1.0/completions")"
curl -fsS --max-time "$PROBE_TIMEOUT" \
    -H 'Accept: application/json' \
    "$BASE_URL/~andee-inference@1.0/health" \
    > "$OUT/health.json"
adb -s "$ADB_SERIAL" shell cat /proc/meminfo > "$OUT/meminfo-after.txt"
adb -s "$ADB_SERIAL" shell ps -A -o PID,PPID,RSS,VSZ,NAME,ARGS > "$OUT/ps-after.txt"
adb -s "$ADB_SERIAL" shell dumpsys meminfo "$PACKAGE" > "$OUT/app-meminfo-after.txt"
adb -s "$ADB_SERIAL" shell run-as "$PACKAGE" cat no_backup/llama-cpp/server.stderr \
    > "$OUT/llama-server.stderr" 2>/dev/null || true
SWAP_FREE_BEFORE_KB="$(awk '$1 == "SwapFree:" {print $2}' "$OUT/meminfo-before.txt")"
SWAP_FREE_AFTER_KB="$(awk '$1 == "SwapFree:" {print $2}' "$OUT/meminfo-after.txt")"
SWAP_FREE_PRESTART_KB="$(awk '$1 == "SwapFree:" {print $2}' "$OUT/meminfo-prestart.txt")"
SWAP_USED_DELTA_KB="$((SWAP_FREE_BEFORE_KB - SWAP_FREE_AFTER_KB))"
SWAP_USED_TOTAL_KB="$((SWAP_FREE_PRESTART_KB - SWAP_FREE_AFTER_KB))"
LLAMA_RSS_KB="$(awk '$5 == "libandee_llama_server.so" {print $3}' "$OUT/ps-after.txt")"
LLAMA_RSS_KB="${LLAMA_RSS_KB:-0}"

jq -n \
    --argjson health "$(cat "$OUT/health.json")" \
    --argjson completion "$(cat "$OUT/completion.json")" \
    --argjson lengthCompletion "$(cat "$OUT/length-completion.json")" \
    --argjson continuation "$(cat "$OUT/continuation.json")" \
    --arg completionStatus "$COMPLETION_STATUS" \
    --arg lengthStatus "$LENGTH_STATUS" \
    --arg continuationStatus "$CONTINUATION_STATUS" \
    --arg emulatorBackend "$EMULATOR_BACKEND" \
    --arg modelRuntime "$MODEL_RUNTIME" \
    --arg expectedModel "$MODEL_NAME" \
    --arg expectedModelId "$MODEL_ID" \
    --arg expectedDigest "$MODEL_DIGEST" \
    --arg modelGateway "$MODEL_GATEWAY" \
    --argjson materializedFromGateway "$MATERIALIZE_FROM_GATEWAY" \
    --arg apkSha256 "$APK_DIGEST" \
    --arg embeddedJniSha256 "$EMBEDDED_JNI_DIGEST" \
    --arg embeddedConstraintProviderSha256 "$EMBEDDED_CONSTRAINT_PROVIDER_DIGEST" \
    --argjson swapUsedDeltaKb "$SWAP_USED_DELTA_KB" \
    --argjson swapUsedTotalKb "$SWAP_USED_TOTAL_KB" \
    --argjson llamaRssKb "$LLAMA_RSS_KB" \
    '{
      scenario: "andee-local-inference-emulator",
      emulator_backend: $emulatorBackend,
      model_runtime: $modelRuntime,
      materialized_from_gateway: ($materializedFromGateway == 1),
      model_gateway: (if $modelGateway == "" then null else $modelGateway end),
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
      measured_runtime: ($completion["andee-execution"].runtime // "litert-lm"),
      model: $completion.model,
      model_id: $completion["andee-execution"]["model-id"],
      model_digest: $completion["andee-execution"]["model-sha256"],
      completion_status: $completionStatus,
      continuation_status: $continuationStatus,
      continuation_nonempty: (
        if $modelRuntime == "llama-cpp" then
          (($continuation.choices[0].message.content // "") | length > 0)
        else true end
      ),
      truncated_completion_status: $lengthStatus,
      truncated_finish_reason: $lengthCompletion.choices[0].finish_reason,
      memory: {
        swap_used_since_prestart_kb: $swapUsedTotalKb,
        swap_used_delta_kb: $swapUsedDeltaKb,
        llama_server_rss_kb: $llamaRssKb
      },
      passed: (
        $completionStatus == "200" and
        $lengthStatus == "200" and
        $lengthCompletion.choices[0].finish_reason == "length" and
        $health.models[0].backend == $emulatorBackend and
        $health.models[0].ready == true and
        $completion.model == $expectedModel and
        $completion["andee-execution"]["model-id"] == $expectedModelId and
        $completion["andee-execution"]["requested-backend"] == $emulatorBackend and
        ($completion["andee-execution"].runtime // "litert-lm") == $modelRuntime and
        $completion["andee-execution"]["model-sha256"] == $expectedDigest and
        (
          $modelRuntime != "llama-cpp" or
          ($continuationStatus == "200" and
            (($continuation.choices[0].message.content // "") | length > 0))
        ) and
        (
          (($completion.choices[0].message.content // "") | length > 0) or
          (($completion.choices[0].message.tool_calls // []) | length > 0)
        )
      )
    }' | tee "$OUT/verdict.json"
jq -e '.passed == true' "$OUT/verdict.json" >/dev/null

echo "inference emulator evidence: $OUT"
