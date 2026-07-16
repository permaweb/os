#!/usr/bin/env bash

build_andee_preloaded_store() {
    local out="$1"
    local rebar3="${REBAR3:-$ROOT/scripts/verified-rebar3.sh}"

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
    (
        cd "$ANDEE_DEVICE_ROOT"
        erl -noshell -pa _build/default/lib/*/ebin -eval '
            [Output] = init:get_plain_arguments(),
            Store = #{
                <<"store-module">> => hb_store_lmdb,
                <<"name">> => unicode:characters_to_binary(Output),
                <<"read-only">> => true
            },
            ok = hb_store:start(Store),
            case hb_store:resolve(
                Store,
                <<"~meta@1.0/preloaded-devices-index">>,
                #{}
            ) of
                {ok, ID} when is_binary(ID), byte_size(ID) > 0 -> halt(0);
                Other ->
                    io:format(standard_error,
                        "missing in-store preloaded index: ~p~n", [Other]),
                    halt(1)
            end.
        ' -extra "$out"
    )
}
