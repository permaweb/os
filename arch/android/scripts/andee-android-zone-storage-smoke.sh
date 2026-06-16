#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andee-android-zone-storage"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28737}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-240}"
PACKAGE="org.permaweb.andee"
REMOTE_CONFIG="/data/local/tmp/andee-android-zone-storage.json"
RESET_APP_DATA="${RESET_APP_DATA:-1}"
MARKER="andee-android-zone-storage-$(date +%Y%m%d%H%M%S)"
ZONE_NAME="android-storage-$MARKER"

rm -rf "$OUT"
mkdir -p "$OUT"

cleanup() {
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    if [ "$RESET_APP_DATA" = "1" ]; then
        adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [ ! -f "$APK" ]; then
    echo "APK missing: $APK" >&2
    exit 1
fi

cat > "$OUT/next-boot-config.json" <<JSON
{
  "public-url": "http://10.0.2.15:8734/$MARKER",
  "zone-self-url": "http://10.0.2.15:8734/$MARKER",
  "andee-test-marker": "$MARKER",
  "zone-init-allow": true,
  "encrypted-volumes": true
}
JSON

adb shell "run-as $PACKAGE sh -c 'kill \$(pidof beam.smp 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof erlexec 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof libandee_hyperbeam.so 2>/dev/null) 2>/dev/null || true'" \
    >/dev/null 2>&1 || true
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
if [ "$RESET_APP_DATA" = "1" ]; then
    adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
fi

if ! adb install -r "$APK" > "$OUT/install.txt" 2>&1; then
    adb uninstall "$PACKAGE" >> "$OUT/install.txt" 2>&1 || true
    adb install -r "$APK" >> "$OUT/install.txt" 2>&1
fi
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb push "$OUT/next-boot-config.json" "$REMOTE_CONFIG" > "$OUT/push.txt"
adb shell "run-as $PACKAGE sh -c 'mkdir -p no_backup/boot-config; \
    cp $REMOTE_CONFIG no_backup/boot-config/next.json; \
    rm -f no_backup/boot-config/active.json no_backup/boot-config/effective.json; \
    rm -rf no_backup/encrypted-zones; \
    rm -f no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr'" \
    > "$OUT/stage.txt"
adb shell rm -f "$REMOTE_CONFIG" >/dev/null 2>&1 || true

adb shell am start -W -n "$PACKAGE/.OrnamentActivity" > "$OUT/activity.txt"
adb shell am start-foreground-service -n "$PACKAGE/.AndeeService" \
    > "$OUT/service-start.txt" 2>&1 || true

STARTED=0
for _ in $(seq 1 90); do
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        > "$OUT/hyperbeam.stdout" 2>/dev/null || true
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
        > "$OUT/hyperbeam.stderr" 2>/dev/null || true
    if grep -q "AndEE HyperBEAM node started" "$OUT/hyperbeam.stdout"; then
        STARTED=1
        break
    fi
    sleep 1
done

adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
adb forward "tcp:$HOST_PORT" tcp:8734 > "$OUT/adb-forward.txt"

post_json() {
    local name="$1"
    local path="$2"
    local url="http://127.0.0.1:$HOST_PORT$path"
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -X POST \
        -H "Accept: application/json" \
        -D "$OUT/$name.headers" \
        -o "$OUT/$name.body" \
        -w "%{http_code}\n" \
        "$url" > "$OUT/$name.status"
}

get_json() {
    local name="$1"
    local path="$2"
    local url="http://127.0.0.1:$HOST_PORT$path"
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -H "Accept: application/json" \
        -D "$OUT/$name.headers" \
        -o "$OUT/$name.body" \
        -w "%{http_code}\n" \
        "$url" > "$OUT/$name.status"
}

urlencode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

ENCODED_ZONE_NAME="$(urlencode "$ZONE_NAME")"
INIT_PATH="/~zone@1.0/init?name=$ENCODED_ZONE_NAME&self-url=$(urlencode "http://127.0.0.1:$HOST_PORT")&template-measurement-device=andee%401.0"
post_json zone-init "$INIT_PATH"
get_json zone-status "/~zone@1.0/status?name=$ENCODED_ZONE_NAME"

BASE_URL="http://127.0.0.1:$HOST_PORT"
if [ "$(cat "$OUT/zone-status.status")" = "200" ]; then
    python3 "$ROOT/scripts/materialize-ao-json.py" \
        --base-url "$BASE_URL" \
        --output "$OUT/zone-status.materialized.json" \
        "$OUT/zone-status.body"
fi

adb shell run-as "$PACKAGE" find no_backup/encrypted-zones -name store.bin \
    -type f -size +0c > "$OUT/store-files.txt"
STORE_FILE="$(head -1 "$OUT/store-files.txt" | tr -d '\r')"
test -n "$STORE_FILE"
adb exec-out run-as "$PACKAGE" cat "$STORE_FILE" > "$OUT/store.bin"
if LC_ALL=C grep -a "$ZONE_NAME" "$OUT/store.bin" >/dev/null; then
    echo "Android encrypted store contains plaintext zone name: $STORE_FILE" >&2
    exit 1
fi

python3 - <<'PY' "$OUT" "$STARTED" "$MARKER" "$ZONE_NAME" "$STORE_FILE"
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
started = sys.argv[2] == "1"
marker = sys.argv[3]
zone = sys.argv[4]
store_file = sys.argv[5]

def fail(message):
    raise SystemExit(message)

if not started:
    fail("HyperBEAM did not report startup")
if (out / "zone-init.status").read_text().strip() != "200":
    fail("~zone@1.0/init did not return HTTP 200")
if (out / "zone-status.status").read_text().strip() != "200":
    fail("~zone@1.0/status did not return HTTP 200")
doc = json.loads((out / "zone-status.materialized.json").read_text())
body = doc["body"]
volume = body["encrypted-volume"]
if body["name"] != zone:
    fail("zone status name mismatch")
if volume["enabled"] not in (True, "true"):
    fail("encrypted volume was not enabled")
if volume["opened"] not in (True, "true"):
    fail("encrypted volume was not opened")
if not isinstance(volume["store-id"], str) or len(volume["store-id"]) != 43:
    fail("encrypted store id malformed")
if not (out / "store.bin").stat().st_size:
    fail("encrypted store file is empty")
summary = {
    "scenario": "android-andee-zone-encrypted-store",
    "passed": True,
    "marker": marker,
    "zone": zone,
    "zone_init_status": "200",
    "zone_status_status": "200",
    "store_file": store_file,
    "store_bytes": (out / "store.bin").stat().st_size,
    "encrypted_volume": volume,
    "evidence": {
        "zone_init": str(out / "zone-init.body"),
        "zone_status": str(out / "zone-status.materialized.json"),
        "store_files": str(out / "store-files.txt"),
        "store_copy": str(out / "store.bin"),
    },
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
PY

cleanup
trap - EXIT

echo "android zone encrypted-storage evidence: $OUT"
