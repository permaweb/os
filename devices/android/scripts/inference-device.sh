#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERMAWEBOS_ROOT="$(cd "$ROOT/../.." && pwd)"
ACTION="${1:-}"
REBAR3="${REBAR3:-rebar3}"
DEVICE_KEY="${DEVICE_KEY:-$ROOT/_build/device-key.json}"
PRIV_DIR="$ROOT/src/priv/dev_andee_inference"
DEVICE_SRC="$ROOT/src,$PERMAWEBOS_ROOT/devices/common/src/sandbox"

mkdir -p "$PRIV_DIR"
trap 'rmdir "$PRIV_DIR" "$ROOT/src/priv" 2>/dev/null || true' EXIT
cd "$ROOT"
case "$ACTION" in
    package)
        "$REBAR3" device package \
            --device-src "$DEVICE_SRC" \
            --devices dev_andee_inference \
            --key "$DEVICE_KEY"
        ;;
    test)
        HB_PORT=0 "$REBAR3" device test \
            --device-src "$DEVICE_SRC" \
            --devices dev_andee_inference \
            --key "$DEVICE_KEY"
        ;;
    *)
        echo "usage: $0 package|test" >&2
        exit 2
        ;;
esac
