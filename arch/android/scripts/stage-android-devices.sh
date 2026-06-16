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

STAGING_DENYLIST=(
    '_build'
    '.DS_Store'
    'cache-mainnet'
    'hyperbeam-key.json'
    'logs'
)

SAVED_BUILD=""
if [ -d "$ANDEE_DEVICE_ROOT/_build" ]; then
    SAVED_BUILD="$(mktemp -d "$BUILD_DIR/android-devices-build.XXXXXX")"
    mv "$ANDEE_DEVICE_ROOT/_build" "$SAVED_BUILD/_build"
fi

rm -rf "$ANDEE_DEVICE_ROOT"
mkdir -p "$ANDEE_DEVICE_ROOT"
if [ -n "$SAVED_BUILD" ]; then
    mv "$SAVED_BUILD/_build" "$ANDEE_DEVICE_ROOT/_build"
    rmdir "$SAVED_BUILD"
fi

copy_device_tree() {
    local src="$1"
    if command -v rsync >/dev/null 2>&1; then
        local excludes=()
        local pattern
        for pattern in "${STAGING_DENYLIST[@]}"; do
            excludes+=(--exclude "$pattern")
        done
        rsync -a "${excludes[@]}" \
            "$src"/ "$ANDEE_DEVICE_ROOT"/
    else
        cp -a "$src"/. "$ANDEE_DEVICE_ROOT"/
        local pattern
        for pattern in "${STAGING_DENYLIST[@]}"; do
            find "$ANDEE_DEVICE_ROOT" -name "$pattern" -prune -exec rm -rf {} +
        done
    fi
}

copy_device_tree "$PERMAWEBOS_COMMON_DEVICE_ROOT"
copy_device_tree "$ANDEE_DEVICE_OVERLAY_ROOT"

if [ ! -f "$ANDEE_DEVICE_ROOT/rebar.lock" ]; then
    echo "staged Android device package has no rebar.lock" >&2
    exit 1
fi

if bad_path="$(
    find "$ANDEE_DEVICE_ROOT" \
        -path "$ANDEE_DEVICE_ROOT/_build" -prune -o \
        \( -name '_build' -o \
           -name '.DS_Store' -o \
           -name 'cache-mainnet' -o \
           -name 'hyperbeam-key.json' -o \
           -name 'logs' \) \
        -print -quit
)"; [ -n "$bad_path" ]; then
    echo "staged Android device package contains local artifact: $bad_path" >&2
    exit 1
fi

rm -f "$ANDEE_DEVICE_ROOT/src/lapee_devices.app.src"
rm -rf "$ANDEE_DEVICE_ROOT/_build/default/lib/andee_devices" \
    "$ANDEE_DEVICE_ROOT/_build/default/lib/lapee_devices"
if [ -d "$ANDEE_DEVICE_ROOT/src/priv" ]; then
    rm -rf "$ANDEE_DEVICE_ROOT/priv"
    cp -a "$ANDEE_DEVICE_ROOT/src/priv" "$ANDEE_DEVICE_ROOT/priv"
fi

echo "android device package: $ANDEE_DEVICE_ROOT"
