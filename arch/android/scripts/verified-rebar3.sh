#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

REBAR3_URL="${REBAR3_URL:-https://s3.amazonaws.com/rebar3/rebar3}"
REBAR3_SHA256="${REBAR3_SHA256:-af85aab41f9fd74bdd6341ebdf6fe9c88077aab9f8eac82371583fa02f2b0bdf}"
REBAR3_BIN="${REBAR3_BIN:-$BUILD_DIR/tools/rebar3}"

mkdir -p "$(dirname "$REBAR3_BIN")"
if [ ! -x "$REBAR3_BIN" ]; then
    tmp="$REBAR3_BIN.tmp"
    rm -f "$tmp"
    curl -fsSL "$REBAR3_URL" -o "$tmp"
    echo "$REBAR3_SHA256  $tmp" | shasum -a 256 -c -
    chmod +x "$tmp"
    mv "$tmp" "$REBAR3_BIN"
fi

echo "$REBAR3_SHA256  $REBAR3_BIN" | shasum -a 256 -c - >/dev/null

if [ "${1:-}" = compile ]; then
    if [ ! -f rebar.lock ]; then
        echo "refusing rebar3 compile without a pinned rebar.lock" >&2
        exit 1
    fi
    before="$(shasum -a 256 rebar.lock)"
    real_cargo="$(command -v cargo || true)"
    if [ -n "$real_cargo" ]; then
        cargo_wrapper_dir="$BUILD_DIR/tools/locked-cargo"
        mkdir -p "$cargo_wrapper_dir"
        cat > "$cargo_wrapper_dir/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
idx=0
if [[ "${args[0]:-}" == +* ]]; then
    idx=1
fi
case "${args[$idx]:-}" in
    build|metadata|test)
        crate="$(basename "$PWD")"
        lock="${LAPEE_CARGO_LOCK_DIR:-}/$crate.Cargo.lock"
        if [ -f "$lock" ]; then
            cp "$lock" Cargo.lock
        elif [ ! -f Cargo.lock ]; then
            echo "refusing cargo ${args[$idx]} without Cargo.lock" >&2
            exit 1
        else
            echo "using upstream Cargo.lock for $crate" >&2
        fi
        args=("${args[@]:0:$((idx + 1))}" --locked \
            "${args[@]:$((idx + 1))}")
        ;;
esac
exec "${LAPEE_REAL_CARGO:?}" "${args[@]}"
SH
        chmod +x "$cargo_wrapper_dir/cargo"
        PATH="$cargo_wrapper_dir:$PATH" \
            LAPEE_REAL_CARGO="$real_cargo" \
            LAPEE_CARGO_LOCK_DIR="$PERMAWEBOS_COMMON_DEVICE_ROOT/cargo-locks" \
            "$REBAR3_BIN" "$@"
    else
        "$REBAR3_BIN" "$@"
    fi
    after="$(shasum -a 256 rebar.lock)"
    if [ "$before" != "$after" ]; then
        echo "rebar.lock changed during compile" >&2
        exit 1
    fi
    exit 0
fi

exec "$REBAR3_BIN" "$@"
