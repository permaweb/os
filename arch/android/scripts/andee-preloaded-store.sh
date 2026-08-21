#!/usr/bin/env bash

ANDEE_PRELOAD_SIGNER_SEED='PermawebOS AndEE reproducible preloaded-store signer v1'
ANDEE_PRELOAD_SIGNER_ADDRESS='cbfIwVIoLq4Q2F9dzmgh66z4ri_KT-Re2CGoqH0DKHk'
ANDEE_LMDB_SYS_VERSION='0.8.0'
ANDEE_LMDB_SYS_CHECKSUM='d5b392838cfe8858e86fac37cf97a0e8c55cc60ba0a18365cadc33092f128ce9'

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
    local out source patched
    out="$ROOT/build/host-tools/andee-lmdb-canonical-v2"
    source="$(andee_lmdb_source_dir)"
    if [ ! -x "$out/mdb_dump" ] || [ ! -x "$out/mdb_load" ]; then
        patched="$out/source"
        rm -rf "$patched"
        mkdir -p "$patched"
        cp "$source/mdb_dump.c" "$source/mdb_load.c" "$patched"
        patch --quiet -d "$patched" -p0 < "$ROOT/scripts/lmdb-canonical-no-lock.patch"
        # Canonicalization owns both databases exclusively. Avoid consuming
        # host-wide POSIX semaphores while dumping and loading these offline
        # stores; shared build hosts can otherwise exhaust the Darwin limit.
        cc -O2 -I "$source" \
            "$patched/mdb_dump.c" "$source/mdb.c" "$source/midl.c" \
            -o "$out/mdb_dump"
        cc -O2 -I "$source" \
            "$patched/mdb_load.c" "$source/mdb.c" "$source/midl.c" \
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
                    <<"bootstrap-device-src">> => [<<"src/preloaded">>]
                },
                {ok, Result} = hb_preload:build_groups(
                    Groups,
                    Wallet,
                    Output,
                    Opts
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
                IndexPath = <<"~meta@1.0/preloaded-devices-index/", Name/binary>>,
                case hb_store:read(Store, IndexPath, Opts) of
                    {ok, SpecID} when is_binary(SpecID), byte_size(SpecID) =:= 43 ->
                        case hb_device_load:reference(Name, Opts) of
                            {ok, Module} when is_atom(Module) -> ok;
                            LoadFailure ->
                                io:format(standard_error,
                                    "cannot load local ~s archive: ~p~n",
                                    [Name, LoadFailure]),
                                halt(1)
                        end;
                    Other ->
                        io:format(standard_error,
                            "missing local ~s spec: ~p~n", [Name, Other]),
                        halt(1)
                end
            end,
            ok = Check(<<"andock@1.0">>),
            ok = Check(<<"andee-inference@1.0">>),
            halt(0).
        ' -extra "$out"
    )
    export ANDEE_PRELOADED_STORE_SIGNER="$ANDEE_PRELOAD_SIGNER_ADDRESS"
    export ANDEE_PRELOADED_STORE_SHA256
    ANDEE_PRELOADED_STORE_SHA256="$(shasum -a 256 "$out/data.mdb" | awk '{print $1}')"
}
