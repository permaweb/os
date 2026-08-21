#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to an Android emulator serial}"
APK="${APK:-$BUILD_DIR/app-debug-emulator.apk}"
MODEL_NAME="${MODEL_NAME:-functiongemma-mobile-actions}"
HOST_PORT="${HOST_PORT:-28739}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-600}"
PACKAGE="org.permaweb.andee"
OUT="$BUILD_DIR/andee-inference-emulator"
RUN_STARTED="$(date '+%m-%d %H:%M:%S.000')"

require_tool curl
require_tool jq
test -f "$APK"
if [ "$("$ADB" -s "$ADB_SERIAL" shell getprop ro.kernel.qemu | tr -d '\r')" != "1" ]; then
    echo "refusing to alter non-emulator target $ADB_SERIAL" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
cleanup() {
    "$ADB" -s "$ADB_SERIAL" forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "${KEEP_ANDEE_RUNNING:-0}" != "1" ]; then
        "$ADB" -s "$ADB_SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

"$ADB" -s "$ADB_SERIAL" uninstall "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" -s "$ADB_SERIAL" install "$APK" > "$OUT/install.txt"
"$ADB" -s "$ADB_SERIAL" shell am start -W -n "$PACKAGE/.OrnamentActivity" \
    > "$OUT/activity.txt"
"$ADB" -s "$ADB_SERIAL" forward "tcp:$HOST_PORT" tcp:8734 \
    > "$OUT/adb-forward.txt"
BASE_URL="http://127.0.0.1:$HOST_PORT"

for _ in $(seq 1 "$PROBE_TIMEOUT"); do
    if curl -fsS --max-time 2 -H 'Accept: application/json' \
        "$BASE_URL/~andee-inference@1.0/health" > "$OUT/health-before.json" 2>/dev/null; then
        break
    fi
    sleep 1
done
test -s "$OUT/health-before.json"

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
curl -fsS --max-time 30 -H 'Accept: application/json' \
    "$BASE_URL/~andee-inference@1.0/health" > "$OUT/health.json"
"$ADB" -s "$ADB_SERIAL" logcat -d -T "$RUN_STARTED" -v threadtime \
    AndeeInference:V LiteRT:V HyperbeamRuntime:V '*:S' \
    > "$OUT/logcat.txt" 2>&1 || true

jq -n \
    --arg status "$COMPLETION_STATUS" \
    --arg model "$MODEL_NAME" \
    --argjson completion "$(cat "$OUT/completion.json")" \
    --argjson health "$(cat "$OUT/health.json")" \
    '{
      scenario: "fresh-emulator-network-materialized-local-inference",
      model: $model,
      completion_status: $status,
      completion: $completion,
      health: $health,
      private_store_mutation: false,
      passed: (
        $status == "200" and
        $completion.model == $model and
        (
          (($completion.choices[0].message.content // "") | length) > 0 or
          (($completion.choices[0].message.tool_calls // []) | length) > 0
        )
      )
    }' > "$OUT/evidence.json"
jq -e '.passed == true' "$OUT/evidence.json" >/dev/null

echo "inference evidence: $OUT/evidence.json"
