#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to an Android emulator serial}"
OUT="$BUILD_DIR/andee-smoke"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28734}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-240}"
PACKAGE="org.permaweb.andee"
RUN_STARTED="$(date '+%m-%d %H:%M:%S.000')"

require_tool curl
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
"$ADB" -s "$ADB_SERIAL" install "$APK" | tee "$OUT/install.txt"
"$ADB" -s "$ADB_SERIAL" shell am start -W -n "$PACKAGE/.OrnamentActivity" \
    > "$OUT/activity.txt"
"$ADB" -s "$ADB_SERIAL" forward "tcp:$HOST_PORT" tcp:8734 \
    > "$OUT/adb-forward.txt"

STATUS=000
for _ in $(seq 1 "$PROBE_TIMEOUT"); do
    STATUS="$(curl -sS --max-time 2 -H 'Accept: application/json' \
        -o "$OUT/meta.body.tmp" -w '%{http_code}' \
        "http://127.0.0.1:$HOST_PORT/~meta@1.0/info" 2>/dev/null || true)"
    if [ "$STATUS" = "200" ]; then
        mv "$OUT/meta.body.tmp" "$OUT/meta.body"
        break
    fi
    sleep 1
done
rm -f "$OUT/meta.body.tmp"

"$ADB" -s "$ADB_SERIAL" shell dumpsys activity services "$PACKAGE" \
    > "$OUT/services.txt" || true
"$ADB" -s "$ADB_SERIAL" logcat -d -T "$RUN_STARTED" -v threadtime \
    AndeeService:V RuntimeExtractor:V HyperbeamRuntime:V AndeeCryptoAgent:V '*:S' \
    > "$OUT/logcat.txt" 2>&1 || true

python3 - <<'PY' "$OUT" "$STATUS"
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
status = sys.argv[2]
services = (out / "services.txt").read_text(errors="ignore")
logs = (out / "logcat.txt").read_text(errors="ignore")
verdict = {
    "scenario": "fresh-emulator-public-http-smoke",
    "fresh_install": True,
    "service_seen": "AndeeService" in services,
    "runtime_started": "HyperBEAM native launcher started" in logs,
    "meta_status": status,
    "meta_bytes": (out / "meta.body").stat().st_size if (out / "meta.body").is_file() else 0,
    "private_store_mutation": False,
}
verdict["passed"] = all((
    verdict["service_seen"],
    verdict["runtime_started"],
    verdict["meta_status"] == "200",
    verdict["meta_bytes"] > 0,
))
(out / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
if not verdict["passed"]:
    raise SystemExit(1)
PY

echo "smoke evidence: $OUT"
