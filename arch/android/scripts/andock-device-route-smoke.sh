#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/android-andock-device"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-38734}"
PACKAGE=org.permaweb.andee
mkdir -p "$OUT"

cleanup() {
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "${KEEP_ANDEE_RUNNING:-0}" != 1 ]; then
        adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

test -f "$APK"
adb install -r "$APK" >"$OUT/install.txt"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb shell run-as "$PACKAGE" rm -f \
    no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr \
    >/dev/null 2>&1 || true
adb shell am start -n "$PACKAGE/.OrnamentActivity" >"$OUT/activity.txt"
adb shell am start-foreground-service -n "$PACKAGE/.AndeeService" \
    >"$OUT/service-start.txt" 2>&1 || true
for _ in $(seq 1 90); do
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        >"$OUT/hyperbeam.stdout" 2>/dev/null || true
    if grep -q 'AndEE HyperBEAM node started' "$OUT/hyperbeam.stdout"; then
        break
    fi
    sleep 1
done
grep -q 'AndEE HyperBEAM node started' "$OUT/hyperbeam.stdout"
adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
adb forward "tcp:$HOST_PORT" tcp:8734 >"$OUT/adb-forward.txt"
python3 "$ROOT/scripts/andock-device-route-smoke.py" \
    --base-url "http://127.0.0.1:$HOST_PORT" \
    --evidence "$OUT/evidence.json"
