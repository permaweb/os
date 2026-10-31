#!/usr/bin/env bash

ANDEE_PRELOAD_SIGNER_SEED='PermawebOS AndEE reproducible preloaded-store signer v1'
ANDEE_PRELOAD_SIGNER_ADDRESS='cbfIwVIoLq4Q2F9dzmgh66z4ri_KT-Re2CGoqH0DKHk'
ANDEE_ELMDB_VERSION='94f6d305a6c337dabbeb4eb8358c74fc93f146fd'

andee_prepare_elmdb_cargo_lock() {
    local crate lock
    crate="$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb/native/elmdb_nif"
    lock="$PERMAWEBOS_COMMON_DEVICE_ROOT/cargo-locks/elmdb_nif.Cargo.lock"
    if [ ! -f "$lock" ]; then
        echo "missing pinned elmdb_nif Cargo.lock: $lock" >&2
        return 1
    fi
    cp "$lock" "$crate/Cargo.lock"
}

andee_preload_key() {
    local path="$1"
    local signer

    signer="$(
        cd "$ANDEE_DEVICE_ROOT"
        erl -noshell -pa _build/default/lib/*/ebin -eval '
            [Output, SeedText] = init:get_plain_arguments(),
            Seed = crypto:hash(sha256, unicode:characters_to_binary(SeedText)),
            {Pub, Priv} = crypto:generate_key(eddsa, ed25519, Seed),
            Wallet = ar_wallet:new({eddsa, ed25519}, Priv, Pub),
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
    local app source
    app="$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb"
    source='native/elmdb_nif/vendor/lmdb-sys/lmdb/libraries/liblmdb'
    if [ "$(git -C "$app" rev-parse HEAD)" != "$ANDEE_ELMDB_VERSION" ] ||
        ! git -C "$app" diff --quiet HEAD -- "$source"; then
        echo "unexpected vendored LMDB source" >&2
        return 1
    fi
    printf '%s\n' "$app/$source"
}

andee_lmdb_canonical_tools() {
    local out source
    out="$BUILD_DIR/host-tools/andee-lmdb-canonical"
    source="$(andee_lmdb_source_dir)"
    mkdir -p "$(dirname "$out")"
    cc -O2 -Wall -Wextra -I "$source" \
        "$ANDEE_RUNTIME_SRC/andee_lmdb_canonical.c" \
        "$source/mdb.c" "$source/midl.c" -o "$out"
    printf '%s\n' "$out"
}

canonicalize_andee_preloaded_store() {
    local out="$1"
    local tools canonical
    tools="$(andee_lmdb_canonical_tools)"
    canonical="$out.canonical"

    rm -rf "$canonical"
    "$tools" "$out" "$canonical"
    rm -rf "$out"
    mv "$canonical" "$out"
}

build_andee_host_elmdb_nif() {
    local app crate library
    app="$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb"
    crate="$app/native/elmdb_nif"
    andee_prepare_elmdb_cargo_lock
    (
        cd "$crate"
        cargo build --release --locked
    )
    library="$(find "$crate/target/release" -maxdepth 1 -type f \
        \( -name 'libelmdb_nif.so' -o -name 'libelmdb_nif.dylib' \) \
        -print -quit)"
    if [ -z "$library" ]; then
        echo "host elmdb NIF was not generated" >&2
        return 1
    fi
    mkdir -p "$app/priv"
    install -m 0755 "$library" "$app/priv/elmdb_nif.so"
}

build_andee_host_b64veryfast_nif() {
    local app jobs
    app="$ANDEE_DEVICE_ROOT/_build/default/lib/b64veryfast"
    jobs="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
    make -C "$app" -j "$jobs" all
    if [ ! -f "$app/priv/b64veryfast.so" ]; then
        echo "host b64veryfast NIF was not generated" >&2
        return 1
    fi
}

build_andee_host_hb_util_string_nif() {
    local app erts_root erts_include out
    local linker_flags
    app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    erts_root="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt(0).')"
    erts_include="$(find "$erts_root" -maxdepth 2 -type d \
        -path '*/erts-*/include' -print -quit)"
    out="$app/priv/hb_util_string.so"
    if [ -z "$erts_include" ]; then
        echo "missing host ERTS include directory" >&2
        return 1
    fi
    case "$(uname -s)" in
        Darwin) linker_flags=(-bundle -undefined dynamic_lookup) ;;
        *) linker_flags=(-shared) ;;
    esac
    mkdir -p "$(dirname "$out")"
    cc -std=c99 -fPIC -O3 -Wall -Wextra \
        -I "$erts_include" \
        "${linker_flags[@]}" \
        -o "$out" \
        "$app/native/hb_util_string/hb_util_string.c"
}

build_andee_preloaded_store() {
    local out="$1"
    local key
    key="$out.preload-key.json"

    rm -rf "$out"
    mkdir -p "$(dirname "$out")"
    build_andee_host_elmdb_nif
    build_andee_host_b64veryfast_nif
    build_andee_host_hb_util_string_nif
    andee_preload_key "$key"
    (
        trap 'rm -f "$key"' EXIT
        cd "$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
        # EUnit auto-export uses an unordered set, so production packages that
        # include *_test() functions otherwise get nondeterministic debug info.
        ERL_COMPILER_OPTIONS="[{d,'NOTEST'}]" \
        erl -noshell -pa "$ANDEE_DEVICE_ROOT"/_build/default/lib/*/ebin \
            -eval '
                [Output, Key, DeviceRoot] = init:get_plain_arguments(),
                DeviceDirs = [
                    <<"src/preloaded">>,
                    unicode:characters_to_binary(
                        filename:join(DeviceRoot, "src")
                    )
                ],
                Wallet = hb:wallet(Key),
                Groups = hb_packager:scan(DeviceDirs, #{}),
                Opts = #{
                    <<"bootstrap-device-src">> => [<<"src/preloaded">>],
                    <<"commitment-device">> => <<"ans104@1.0">>
                },
                % ANS-104 supports the deterministic Ed25519 build identity.
                {ok, Result} =
                    hb_forge_seed:with_forge_bootstrap(
                        Opts,
                        fun(SeedOpts) ->
                            hb_preload:build_dir(
                                hb_packager:package_all(Groups, SeedOpts),
                                Wallet,
                                Output,
                                SeedOpts#{
                                    <<"commitment-device">> => #{
                                        <<"device">> => <<"ans104@1.0">>,
                                        <<"type">> => <<"ed25519-sha512">>
                                    }
                                }
                            )
                        end
                    ),
                io:format(
                    "Device preload complete: Store: ~s; Index: ~s.~n",
                    [Output, maps:get(index, Result)]
                ),
                halt(0).
            ' -extra "$out" "$key" "$ANDEE_DEVICE_ROOT"
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
            Check = fun(Name) ->
                case hb_device_load:reference(Name, Opts) of
                    {ok, Module} when is_atom(Module) -> ok;
                    LoadFailure ->
                        io:format(standard_error,
                            "cannot load local ~s archive: ~p~n",
                            [Name, LoadFailure]),
                        halt(1)
                end
            end,
            ok = Check(<<"andock@1.0">>),
            ok = Check(<<"andee-inference@1.0">>),
            ok = Check(<<"tunnel@1.0">>),
            halt(0).
        ' -extra "$out"
    )
    export ANDEE_PRELOADED_STORE_SIGNER="$ANDEE_PRELOAD_SIGNER_ADDRESS"
    export ANDEE_PRELOADED_STORE_SHA256
    ANDEE_PRELOADED_STORE_SHA256="$(shasum -a 256 "$out/data.mdb" | awk '{print $1}')"
}
