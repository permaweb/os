#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

AVD_NAME="${AVD_NAME:-andee-api-36-arm64}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
if adb devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'; then
    echo "device already connected"
    exit 0
fi

LOG="$BUILD_DIR/andee-emulator.log"
if command -v screen >/dev/null 2>&1; then
    screen -S andee-emulator -X quit >/dev/null 2>&1 || true
    screen -dmS andee-emulator sh -lc \
        "ANDROID_HOME='$ANDROID_HOME' ANDROID_SDK_ROOT='$ANDROID_SDK_ROOT' JAVA_HOME='$JAVA_HOME' PATH='$PATH' exec emulator -avd '$AVD_NAME' -no-window -no-snapshot -no-audio -no-boot-anim >'$LOG' 2>&1"
    echo "screen:andee-emulator" > "$BUILD_DIR/andee-emulator.pid"
else
    nohup emulator -avd "$AVD_NAME" -no-window -no-snapshot -no-audio -no-boot-anim \
        >"$LOG" 2>&1 &
    echo "$!" > "$BUILD_DIR/andee-emulator.pid"
fi

deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
until adb get-state >/dev/null 2>&1 \
    && adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "emulator did not boot within ${BOOT_TIMEOUT}s: $AVD_NAME" >&2
        tail -n 80 "$LOG" >&2 || true
        exit 1
    fi
    sleep 2
done
adb shell input keyevent 82 >/dev/null 2>&1 || true
echo "emulator ready: $AVD_NAME"
