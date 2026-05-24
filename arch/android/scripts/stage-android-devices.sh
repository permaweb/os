#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

mkdir -p "$ANDEE_DEVICE_ROOT"
find "$ANDEE_DEVICE_ROOT" -mindepth 1 -maxdepth 1 ! -name _build \
    -exec rm -rf {} +

copy_device_tree() {
    local src="$1"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '_build' --exclude 'rebar.lock' \
            "$src"/ "$ANDEE_DEVICE_ROOT"/
    else
        cp -a "$src"/. "$ANDEE_DEVICE_ROOT"/
        rm -rf "$ANDEE_DEVICE_ROOT/_build" "$ANDEE_DEVICE_ROOT/rebar.lock"
    fi
}

copy_device_tree "$PERMAWEBOS_COMMON_DEVICE_ROOT"
copy_device_tree "$ANDEE_DEVICE_OVERLAY_ROOT"

rm -f "$ANDEE_DEVICE_ROOT/src/lapee_devices.app.src"
rm -rf "$ANDEE_DEVICE_ROOT/_build/default/lib/andee_devices"
if [ -d "$ANDEE_DEVICE_ROOT/src/priv" ]; then
    rm -rf "$ANDEE_DEVICE_ROOT/priv"
    cp -a "$ANDEE_DEVICE_ROOT/src/priv" "$ANDEE_DEVICE_ROOT/priv"
fi

echo "android device package: $ANDEE_DEVICE_ROOT"
