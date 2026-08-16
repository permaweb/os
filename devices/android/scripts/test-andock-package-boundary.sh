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
PREFIX="$(basename "$ARCHIVE" .beam-archive.zip)"
if [ "$(wc -l <<<"$ENTRIES" | tr -d ' ')" -ne 5 ]; then
    echo "andock@1.0 contains an unexpected number of archive entries." >&2
    printf '%s\n' "$ENTRIES" >&2
    exit 1
fi

while IFS= read -r entry; do
    case "$entry" in
        "ebin/$PREFIX.beam" | \
        "ebin/${PREFIX}__andock.beam" | \
        "ebin/${PREFIX}__permawebos_bash_session.beam" | \
        "ebin/${PREFIX}__permawebos_execution.beam" | \
        "ebin/${PREFIX}__permawebos_execution_tools.beam")
            ;;
        *)
            echo "andock@1.0 contains unexpected entry: $entry" >&2
            exit 1
            ;;
    esac
done <<<"$ENTRIES"

for module in andock permawebos_bash_session permawebos_execution \
        permawebos_execution_tools; do
    if ! grep -q "__${module}\\.beam$" <<<"$ENTRIES"; then
        echo "andock@1.0 is missing $module." >&2
        exit 1
    fi
done

if grep -Eqi 'ouroboros|__docker|__qemu|__router|__provider|__member' \
        <<<"$ENTRIES"; then
    echo "andock@1.0 embeds an application or foreign execution backend." >&2
    exit 1
fi

if while IFS= read -r entry; do
        unzip -p "$ARCHIVE" "$entry" | strings
    done <<<"$ENTRIES" | grep -Eqi \
        'ouroboros|__docker|__qemu'; then
    echo "andock@1.0 contains forbidden application content." >&2
    exit 1
fi

printf 'andock package boundary ok: %s\n' "$(basename "$ARCHIVE")"
