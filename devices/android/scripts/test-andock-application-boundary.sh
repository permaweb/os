#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMAWEBOS_ROOT="$(cd "$ROOT/../.." && pwd)"

SURFACES=(
    "$ROOT/Makefile"
    "$ROOT/README.md"
    "$ROOT/docs/device-specs/andock.md"
    "$ROOT/scripts/andock-device.sh"
    "$ROOT/src"
    "$PERMAWEBOS_ROOT/arch/android/Makefile"
    "$PERMAWEBOS_ROOT/arch/android/scripts/android-common.sh"
    "$PERMAWEBOS_ROOT/arch/android/scripts/stage-android-devices.sh"
)

if rg -n -i \
        'OUROBOROS_SRC|ANDEE_OUROBOROS|lib_ouroboros|ouroboros[-_]?andock|ouroboros[-_]execution' \
        "${SURFACES[@]}"; then
    echo "Andock or Android build surfaces contain an application dependency." >&2
    exit 1
fi

printf 'andock application boundary ok\n'
