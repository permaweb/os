#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/_build/device-packages"
ARCHIVE=""
while IFS= read -r candidate; do
    if [[ -z "$ARCHIVE" || "$candidate" -nt "$ARCHIVE" ]]; then
        ARCHIVE="$candidate"
    fi
done < <(find "$PACKAGE_DIR" -maxdepth 1 -type f \
    -name '_hb_device_andock_1_0_*.beam-archive.zip' -print)

if [[ -z "$ARCHIVE" ]]; then
    echo "No andock@1.0 archive was emitted." >&2
    exit 1
fi

ENTRIES="$(unzip -Z1 "$ARCHIVE")"
for module in andock ouroboros_execution ouroboros_execution_tools ouroboros_utils; do
    if ! grep -q "__${module}\\.beam$" <<<"$ENTRIES"; then
        echo "andock@1.0 is missing $module." >&2
        exit 1
    fi
done

if grep -Eq '__ouroboros_(andock|docker|qemu|router|provider|member)\\.beam$' \
        <<<"$ENTRIES"; then
    echo "andock@1.0 embeds an application or foreign backend module." >&2
    exit 1
fi

printf 'andock package boundary ok: %s\n' "$(basename "$ARCHIVE")"
