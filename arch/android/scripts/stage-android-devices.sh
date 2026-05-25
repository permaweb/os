#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

for lock in "$PERMAWEBOS_COMMON_DEVICE_ROOT/rebar.lock" \
        "$ANDEE_DEVICE_OVERLAY_ROOT/rebar.lock"; do
    if [ ! -f "$lock" ]; then
        echo "missing pinned device rebar.lock: $lock" >&2
        exit 1
    fi
done

rm -rf "$ANDEE_DEVICE_ROOT"
mkdir -p "$ANDEE_DEVICE_ROOT"

copy_device_tree() {
    local src="$1"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude '_build' \
            "$src"/ "$ANDEE_DEVICE_ROOT"/
    else
        cp -a "$src"/. "$ANDEE_DEVICE_ROOT"/
        rm -rf "$ANDEE_DEVICE_ROOT/_build"
    fi
}

copy_device_tree "$PERMAWEBOS_COMMON_DEVICE_ROOT"
copy_device_tree "$ANDEE_DEVICE_OVERLAY_ROOT"

if [ ! -f "$ANDEE_DEVICE_ROOT/rebar.lock" ]; then
    echo "staged Android device package has no rebar.lock" >&2
    exit 1
fi

rm -f "$ANDEE_DEVICE_ROOT/src/lapee_devices.app.src"
rm -rf "$ANDEE_DEVICE_ROOT/_build/default/lib/andee_devices"
if [ -d "$ANDEE_DEVICE_ROOT/src/priv" ]; then
    rm -rf "$ANDEE_DEVICE_ROOT/priv"
    cp -a "$ANDEE_DEVICE_ROOT/src/priv" "$ANDEE_DEVICE_ROOT/priv"
fi

echo "android device package: $ANDEE_DEVICE_ROOT"
