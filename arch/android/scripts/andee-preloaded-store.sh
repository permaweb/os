#!/usr/bin/env bash

ANDEE_PRELOAD_SIGNER_SEED='PermawebOS AndEE reproducible preloaded-store signer v1'
ANDEE_PRELOAD_SIGNER_ADDRESS='cbfIwVIoLq4Q2F9dzmgh66z4ri_KT-Re2CGoqH0DKHk'
ANDEE_LMDB_SYS_VERSION='0.8.0'
ANDEE_LMDB_SYS_CHECKSUM='d5b392838cfe8858e86fac37cf97a0e8c55cc60ba0a18365cadc33092f128ce9'

andee_preload_key() {
    local path="$1"
    local signer

    signer="$(
        cd "$ANDEE_DEVICE_ROOT"
        erl -noshell -pa _build/default/lib/*/ebin -eval '
            [Output, SeedText] = init:get_plain_arguments(),
            Seed = crypto:hash(sha256, unicode:characters_to_binary(SeedText)),
            {Pub, Priv} = crypto:generate_key(eddsa, ed25519, Seed),
            Wallet = {{eddsa, ed25519}, Priv, Pub},
            ok = file:write_file(Output, ar_wallet:to_json(Wallet)),
            io:format("~s", [hb_util:human_id(
                ar_wallet:to_address(Pub, {eddsa, ed25519})
            )]),
            halt(0).
        ' -extra "$path" "$ANDEE_PRELOAD_SIGNER_SEED"
    )"
    chmod 600 "$path"
    if [ "$signer" != "$ANDEE_PRELOAD_SIGNER_ADDRESS" ]; then
        echo "unexpected AndEE preload signer: $signer" >&2
        return 1
    fi
}

andee_lmdb_source_dir() {
    local cargo_lock registry source version checksum
    cargo_lock="$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb/native/elmdb_nif/Cargo.lock"
    version="$(awk '
        $0 == "name = \"lmdb-sys\"" { found = 1; next }
        found && /^version = / { gsub(/[\" ]/, "", $3); print $3; exit }
    ' "$cargo_lock")"
    checksum="$(awk '
        $0 == "name = \"lmdb-sys\"" { found = 1; next }
        found && /^checksum = / { gsub(/[\" ]/, "", $3); print $3; exit }
    ' "$cargo_lock")"
    if [ "$version" != "$ANDEE_LMDB_SYS_VERSION" ] ||
        [ "$checksum" != "$ANDEE_LMDB_SYS_CHECKSUM" ]; then
        echo "unexpected lmdb-sys package: $version $checksum" >&2
        return 1
    fi

    registry="${CARGO_HOME:-$HOME/.cargo}/registry/src"
    source="$(find "$registry" -type d \
        -path "*/lmdb-sys-$ANDEE_LMDB_SYS_VERSION/lmdb/libraries/liblmdb" \
        -print -quit)"
    if [ -z "$source" ]; then
        echo "missing fetched lmdb-sys $ANDEE_LMDB_SYS_VERSION source" >&2
        return 1
    fi
    printf '%s\n' "$source"
}

andee_lmdb_canonical_tools() {
    local out source
    out="$ROOT/build/host-tools/andee-lmdb-canonical-v1"
    source="$(andee_lmdb_source_dir)"
    if [ ! -x "$out/mdb_dump" ] || [ ! -x "$out/mdb_load" ]; then
        mkdir -p "$out"
        cc -O2 \
            "$source/mdb_dump.c" "$source/mdb.c" "$source/midl.c" \
            -o "$out/mdb_dump"
        cc -O2 \
            "$source/mdb_load.c" "$source/mdb.c" "$source/midl.c" \
            -o "$out/mdb_load"
    fi
    printf '%s\n' "$out"
}

canonicalize_andee_preloaded_store() {
    local out="$1"
    local tools dump canonical
    tools="$(andee_lmdb_canonical_tools)"
    dump="$out.dump"
    canonical="$out.canonical"

    rm -rf "$canonical"
    mkdir -p "$canonical"
    "$tools/mdb_dump" "$out" | awk '!/^db_pagesize=/' > "$dump"
    "$tools/mdb_load" -f "$dump" "$canonical"
    rm -f "$canonical/lock.mdb" "$dump"
    rm -rf "$out"
    mv "$canonical" "$out"
}

build_andee_preloaded_store() {
    local out="$1"
    local rebar3="${REBAR3:-$ROOT/scripts/verified-rebar3.sh}"
    local key
    key="$out.preload-key.json"

    rm -rf "$out"
    mkdir -p "$(dirname "$out")"
    andee_preload_key "$key"
    (
        trap 'rm -f "$key"' EXIT
        cd "$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
        # EUnit auto-export uses an unordered set, so production packages that
        # include *_test() functions otherwise get nondeterministic debug info.
        device_src="src/preloaded,$ANDEE_DEVICE_ROOT/src"
        device_src="$device_src,$ANDEE_DEVICE_ROOT/src/security"
        device_src="$device_src,$ANDEE_DEVICE_ROOT/src/sandbox"
        ERL_COMPILER_OPTIONS="[{d,'NOTEST'}]" "$rebar3" device preload \
            --device-src "$device_src" \
            --output-dir "$out" \
            --key "$key"
    )
    rm -f "$key"
    canonicalize_andee_preloaded_store "$out"
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
            Opts = #{
                <<"store">> => [Store],
                <<"preloaded-store">> => Store,
                <<"trusted-device-signers">> => [],
                <<"name-resolvers">> => []
            },
            case hb_store:read(
                Store,
                <<"~meta@1.0/preloaded-devices-index/andock@1.0">>,
                Opts
            ) of
                {ok, SpecID} when is_binary(SpecID), byte_size(SpecID) =:= 43 ->
                    case hb_device_load:reference(<<"andock@1.0">>, Opts) of
                        {ok, Module} when is_atom(Module) -> halt(0);
                        LoadFailure ->
                            io:format(standard_error,
                                "cannot load local andock@1.0 archive: ~p~n",
                                [LoadFailure]),
                            halt(1)
                    end;
                Other ->
                    io:format(standard_error,
                        "missing local andock@1.0 spec: ~p~n", [Other]),
                    halt(1)
            end.
        ' -extra "$out"
    )
    export ANDEE_PRELOADED_STORE_SIGNER="$ANDEE_PRELOAD_SIGNER_ADDRESS"
    export ANDEE_PRELOADED_STORE_SHA256
    ANDEE_PRELOADED_STORE_SHA256="$(shasum -a 256 "$out/data.mdb" | awk '{print $1}')"
}
