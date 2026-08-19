#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMAWEBOS_ROOT="$(cd "$ROOT/../.." && pwd)"

SURFACES=(
    "$ROOT/Makefile"
    "$ROOT/README.md"
    "$ROOT/docs"
    "$ROOT/scripts/device.sh"
    "$ROOT/src"
    "$PERMAWEBOS_ROOT/devices/common/src/sandbox"
)

if rg -n -i \
        'OUROBOROS_SRC|lib_ouroboros|ouroboros[-_]?execution|ouroboros[-_]?base|xylophonez|xylophonezygote' \
        "${SURFACES[@]}"; then
    echo "Linux execution device contains an application dependency." >&2
    exit 1
fi

printf 'docker application boundary ok\n'
