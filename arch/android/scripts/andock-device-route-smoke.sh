#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/android-andock-device"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-38734}"
PACKAGE=org.permaweb.andee
ADB_SERIAL="${ADB_SERIAL:?set ADB_SERIAL to an Android emulator serial}"
mkdir -p "$OUT"

cleanup() {
    "$ADB" -s "$ADB_SERIAL" forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
    if [ "${KEEP_ANDEE_RUNNING:-0}" != 1 ]; then
        "$ADB" -s "$ADB_SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

test -f "$APK"
ADB_SERIAL="$ADB_SERIAL" APK="$APK" HOST_PORT="$HOST_PORT" \
    KEEP_ANDEE_RUNNING=1 "$ROOT/scripts/andee-smoke.sh"
"$ADB" -s "$ADB_SERIAL" forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
"$ADB" -s "$ADB_SERIAL" forward "tcp:$HOST_PORT" tcp:8734 >"$OUT/adb-forward.txt"
python3 "$ROOT/scripts/andock-device-route-smoke.py" \
    --base-url "http://127.0.0.1:$HOST_PORT" \
    --evidence "$OUT/evidence.json" \
    --materialization-timeout "${MATERIALIZATION_TIMEOUT:-1800}"
