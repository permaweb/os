#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

mkdir -p "$HANDEE_DEVICE_ROOT"
find "$HANDEE_DEVICE_ROOT" -mindepth 1 -maxdepth 1 ! -name _build \
    -exec rm -rf {} +

copy_device_tree() {
    local src="$1"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '_build' --exclude 'rebar.lock' \
            "$src"/ "$HANDEE_DEVICE_ROOT"/
    else
        cp -a "$src"/. "$HANDEE_DEVICE_ROOT"/
        rm -rf "$HANDEE_DEVICE_ROOT/_build" "$HANDEE_DEVICE_ROOT/rebar.lock"
    fi
}

copy_device_tree "$PERMAWEBOS_COMMON_DEVICE_ROOT"
copy_device_tree "$HANDEE_DEVICE_OVERLAY_ROOT"

rm -f "$HANDEE_DEVICE_ROOT/src/lapee_devices.app.src"
rm -rf "$HANDEE_DEVICE_ROOT/_build/default/lib/handee_devices"

echo "android device package: $HANDEE_DEVICE_ROOT"
