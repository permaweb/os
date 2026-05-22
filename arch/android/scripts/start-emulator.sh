#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

AVD_NAME="${AVD_NAME:-handee-api-36-arm64}"
if adb devices | awk 'NR>1 && $2=="device" {found=1} END {exit !found}'; then
    echo "device already connected"
    exit 0
fi

LOG="$BUILD_DIR/handee-emulator.log"
if command -v screen >/dev/null 2>&1; then
    screen -S handee-emulator -X quit >/dev/null 2>&1 || true
    screen -dmS handee-emulator sh -lc \
        "ANDROID_HOME='$ANDROID_HOME' ANDROID_SDK_ROOT='$ANDROID_SDK_ROOT' JAVA_HOME='$JAVA_HOME' PATH='$PATH' exec emulator -avd '$AVD_NAME' -no-window -no-snapshot -no-audio -no-boot-anim >'$LOG' 2>&1"
    echo "screen:handee-emulator" > "$BUILD_DIR/handee-emulator.pid"
else
    nohup emulator -avd "$AVD_NAME" -no-window -no-snapshot -no-audio -no-boot-anim \
        >"$LOG" 2>&1 &
    echo "$!" > "$BUILD_DIR/handee-emulator.pid"
fi

adb wait-for-device
until adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
    sleep 2
done
adb shell input keyevent 82 >/dev/null 2>&1 || true
echo "emulator ready: $AVD_NAME"
