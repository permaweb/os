#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"
REBAR3="${REBAR3:-rebar3}"
DEVICE_KEY="${DEVICE_KEY:-$ROOT/_build/device-key.json}"
DEVICE_SRC="$ROOT/src"
ANDOCK_PRIV_DIR="$DEVICE_SRC/priv/dev_andock"
mkdir -p "$ANDOCK_PRIV_DIR"
trap 'rmdir "$ANDOCK_PRIV_DIR" "$DEVICE_SRC/priv" 2>/dev/null || true' EXIT
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
