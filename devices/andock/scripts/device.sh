#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"
REBAR3="${REBAR3:-rebar3}"
DEVICE_KEY="${DEVICE_KEY:-$ROOT/_build/device-key.json}"

if [[ -z "${OUROBOROS_SRC:-}" ]]; then
    echo "OUROBOROS_SRC must name the generic Ouroboros source checkout." >&2
    exit 2
fi

OUROBOROS_SRC="$(cd "$OUROBOROS_SRC" && pwd)"
for source in \
    lib_ouroboros_execution.erl \
    lib_ouroboros_execution_tools.erl \
    lib_ouroboros_utils.erl; do
    if [[ ! -f "$OUROBOROS_SRC/src/$source" ]]; then
        echo "Missing shared execution source: $OUROBOROS_SRC/src/$source" >&2
        exit 2
    fi
done

if [[ -e "$OUROBOROS_SRC/src/dev_andock.erl" || \
      -e "$OUROBOROS_SRC/src/lib_andock.erl" || \
      -e "$OUROBOROS_SRC/src/lib_ouroboros_andock.erl" ]]; then
    echo "The Ouroboros source checkout embeds an Andock backend." >&2
    exit 2
fi

DEVICE_SRC="$ROOT/src,$OUROBOROS_SRC/src"
cd "$ROOT"
case "$ACTION" in
    package)
        "$REBAR3" device package \
            --device-src "$DEVICE_SRC" \
            --devices dev_andock \
            --key "$DEVICE_KEY"
        ;;
    test)
        HB_PORT=0 "$REBAR3" device test \
            --device-src "$DEVICE_SRC" \
            --devices dev_andock \
            --key "$DEVICE_KEY"
        ;;
    *)
        echo "usage: $0 package|test" >&2
        exit 2
        ;;
esac
