#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

AVD_NAME="${AVD_NAME:-andee-api-36-arm64}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
EMULATOR_PORT="${EMULATOR_PORT:-5554}"
ADB_SERIAL="${ADB_SERIAL:-emulator-$EMULATOR_PORT}"
if ! [[ "$EMULATOR_PORT" =~ ^[0-9]+$ ]] ||
    [ "$EMULATOR_PORT" -lt 5554 ] || [ "$EMULATOR_PORT" -gt 5682 ] ||
    [ $((EMULATOR_PORT % 2)) -ne 0 ]; then
    echo "EMULATOR_PORT must be an even port from 5554 through 5682" >&2
    exit 1
fi
if [ "$ADB_SERIAL" != "emulator-$EMULATOR_PORT" ]; then
    echo "ADB_SERIAL must match EMULATOR_PORT: emulator-$EMULATOR_PORT" >&2
    exit 1
fi
if "$ADB" -s "$ADB_SERIAL" get-state >/dev/null 2>&1; then
    running_avd="$("$ADB" -s "$ADB_SERIAL" emu avd name 2>/dev/null | head -1 | tr -d '\r')"
    if [ "$running_avd" != "$AVD_NAME" ]; then
        echo "$ADB_SERIAL already belongs to AVD $running_avd, not $AVD_NAME" >&2
        exit 1
    fi
    echo "emulator ready: $AVD_NAME ($ADB_SERIAL)"
    exit 0
fi

LOG="$BUILD_DIR/andee-emulator-$EMULATOR_PORT.log"
if command -v screen >/dev/null 2>&1; then
    session="andee-emulator-$EMULATOR_PORT"
    screen -dmS "$session" sh -lc \
        "ANDROID_HOME='$ANDROID_HOME' ANDROID_SDK_ROOT='$ANDROID_SDK_ROOT' JAVA_HOME='$JAVA_HOME' PATH='$PATH' exec emulator -avd '$AVD_NAME' -port '$EMULATOR_PORT' -no-window -no-snapshot -no-audio -no-boot-anim >'$LOG' 2>&1"
    echo "screen:$session" > "$BUILD_DIR/andee-emulator-$EMULATOR_PORT.pid"
else
    nohup emulator -avd "$AVD_NAME" -port "$EMULATOR_PORT" \
        -no-window -no-snapshot -no-audio -no-boot-anim \
        >"$LOG" 2>&1 &
    echo "$!" > "$BUILD_DIR/andee-emulator-$EMULATOR_PORT.pid"
fi

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until "$ADB" -s "$ADB_SERIAL" get-state >/dev/null 2>&1 \
    && "$ADB" -s "$ADB_SERIAL" shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "emulator did not boot within ${BOOT_TIMEOUT}s: $AVD_NAME" >&2
        tail -n 80 "$LOG" >&2 || true
        exit 1
    fi
    sleep 2
done
"$ADB" -s "$ADB_SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true
echo "emulator ready: $AVD_NAME ($ADB_SERIAL)"
