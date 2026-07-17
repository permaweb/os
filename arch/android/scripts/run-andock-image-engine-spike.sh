#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_ROOT="$ROOT/android"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}}"
ADB="$ANDROID_SDK_ROOT/platform-tools/adb"
SERIAL="${1:?usage: $0 ANDROID_SERIAL}"
APP_APK="$ANDROID_ROOT/andock-image-engine-spike/build/outputs/apk/debug/andock-image-engine-spike-debug.apk"
TEST_APK="$ANDROID_ROOT/andock-image-engine-spike/build/outputs/apk/androidTest/debug/andock-image-engine-spike-debug-androidTest.apk"

"$ADB" -s "$SERIAL" install -r -t "$APP_APK"
"$ADB" -s "$SERIAL" install -r -t "$TEST_APK"
"$ADB" -s "$SERIAL" shell am instrument -w \
    org.permaweb.andee.imageprobe.test/org.permaweb.andee.imageprobe.ImageEngineProbeInstrumentation
