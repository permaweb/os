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
    -name '_hb_device_inference_1_0_*.beam-archive.zip' -print)

if [[ -z "$ARCHIVE" ]]; then
    echo "No inference@1.0 archive was emitted." >&2
    exit 1
fi

ENTRIES="$(unzip -Z1 "$ARCHIVE")"
PREFIX="$(basename "$ARCHIVE" .beam-archive.zip)"
if [ "$(wc -l <<<"$ENTRIES" | tr -d ' ')" -ne 2 ]; then
    echo "inference@1.0 contains an unexpected number of archive entries." >&2
    printf '%s\n' "$ENTRIES" >&2
    exit 1
fi
for expected in "ebin/$PREFIX.beam" "ebin/${PREFIX}__andee_inference.beam"; do
    if ! grep -qxF "$expected" <<<"$ENTRIES"; then
        echo "inference@1.0 is missing $expected." >&2
        exit 1
    fi
done
if while IFS= read -r entry; do
        unzip -p "$ARCHIVE" "$entry" | strings
    done <<<"$ENTRIES" | grep -Eqi \
        'ouroboros|anthropic|__andock|__docker|__qemu'; then
    echo "inference@1.0 contains application or foreign-provider content." >&2
    exit 1
fi

printf 'inference package boundary ok: %s\n' "$(basename "$ARCHIVE")"
