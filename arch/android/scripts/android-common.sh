#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMAWEBOS_ROOT="$(cd "$ROOT/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
PERMAWEBOS_COMMON_DEVICE_ROOT="${PERMAWEBOS_COMMON_DEVICE_ROOT:-$PERMAWEBOS_ROOT/devices/common}"
ANDEE_DEVICE_OVERLAY_ROOT="${ANDEE_DEVICE_OVERLAY_ROOT:-$PERMAWEBOS_ROOT/devices/android}"
ANDEE_DEVICE_ROOT="${ANDEE_DEVICE_ROOT:-$BUILD_DIR/android-devices}"
ANDEE_CONFIG="${ANDEE_CONFIG:-$ROOT/config/andee.json}"
ANDEE_RUNTIME_SRC="${ANDEE_RUNTIME_SRC:-$ROOT/runtime-src}"
ANDEE_VERIFIER_DIR="${ANDEE_VERIFIER_DIR:-$ROOT/secondary-external-verifier}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
export PERMAWEBOS_ROOT BUILD_DIR PERMAWEBOS_COMMON_DEVICE_ROOT \
    ANDEE_DEVICE_OVERLAY_ROOT ANDEE_DEVICE_ROOT ANDEE_CONFIG \
    ANDEE_RUNTIME_SRC ANDEE_VERIFIER_DIR ANDROID_HOME ANDROID_SDK_ROOT \
    JAVA_HOME PATH

mkdir -p "$BUILD_DIR"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        return 1
    fi
}
