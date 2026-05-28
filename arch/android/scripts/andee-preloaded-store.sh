#!/usr/bin/env bash

build_andee_preloaded_store() {
    local out="$1"
    local hrl
    local rebar3="${REBAR3:-$ROOT/scripts/verified-rebar3.sh}"
    hrl="$(dirname "$out")/hb_preloaded_index.hrl"

    rm -rf "$out"
    mkdir -p "$(dirname "$out")"
    (
        cd "$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
        "$rebar3" device preload \
            --device-src "src/preloaded,$ANDEE_DEVICE_ROOT/src" \
            --output-dir "$out"
    )
    if [ ! -s "$out/data.mdb" ]; then
        echo "AndEE preloaded LMDB store was not generated: $out" >&2
        exit 1
    fi
    PRELOADED_DEVICES_INDEX="$(
        sed -n 's/.*PRELOADED_DEVICES_INDEX_MESSAGE_ID, <<"\([^"]*\)">>.*/\1/p' \
            "$hrl" | head -1
    )"
    if [ -z "$PRELOADED_DEVICES_INDEX" ]; then
        echo "AndEE preloaded device index could not be parsed from $hrl" >&2
        exit 1
    fi
    export PRELOADED_DEVICES_INDEX
}
