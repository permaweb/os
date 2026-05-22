#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMAWEBOS_ROOT="$(cd "$ROOT/../.." && pwd)"
HANDEE_DEVICE_ROOT="${HANDEE_DEVICE_ROOT:-$PERMAWEBOS_ROOT/devices/android}"
HANDEE_CONFIG="${HANDEE_CONFIG:-$ROOT/config/handee.json}"
HANDEE_RUNTIME_SRC="${HANDEE_RUNTIME_SRC:-$ROOT/runtime-src}"
HANDEE_VERIFIER_DIR="${HANDEE_VERIFIER_DIR:-$ROOT/secondary-external-verifier}"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
export PERMAWEBOS_ROOT HANDEE_DEVICE_ROOT HANDEE_CONFIG HANDEE_RUNTIME_SRC \
    HANDEE_VERIFIER_DIR ANDROID_HOME ANDROID_SDK_ROOT JAVA_HOME PATH

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
mkdir -p "$BUILD_DIR"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required tool: $1" >&2
        return 1
    fi
}
