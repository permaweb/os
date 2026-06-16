%%% @doc Android entrypoint for AndEE's bundled HyperBEAM node.
%%%
%%% The stock HB application entrypoint loads or creates a disk wallet. AndEE's
%%% node key is deliberately session-local, so the Android native launcher calls
%%% this module instead: it loads the enforced config, creates an in-memory
%%% wallet, binds the node/config identity into the measurement context, and
%%% starts the HTTP node in the foreground VM.
-module(andee_bootstrap).

-export([start/0, start/1]).

-define(DEFAULT_CONFIG, <<"config/andee.json">>).
-define(DEFAULT_PORT, 8734).

start() ->
    ensure_preloaded_store_environment(),
    Env = hb_opts:default_message_with_env(),
    ConfigPath = hb_opts:get(<<"hb-config-location">>, ?DEFAULT_CONFIG, Env),
    start(ConfigPath).

start(ConfigPath) ->
    ensure_preloaded_store_environment(),
    io:format("andee-bootstrap=load-config path=~ts~n", [hb_util:bin(ConfigPath)]),
    Env = hb_opts:default_message_with_env(),
    Loaded =
        hb_maps:merge(
            without_runtime_environment_keys(load_config(ConfigPath)),
            runtime_environment()
        ),
    io:format("andee-bootstrap=config-loaded~n"),
    Merged = hb_maps:merge(Env, Loaded),
    ensure_runtime_applications(),
    configure_public_key_cacerts(),
    hb_http_client:setup_conn(Merged),
    ok = hb_http_client:init_prometheus(),
    io:format("andee-bootstrap=start-store~n"),
    Store = start_store(Merged),
    io:format("andee-bootstrap=generate-wallet~n"),
    Wallet = ephemeral_wallet(),
    io:format("andee-bootstrap=derive-address~n"),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    NodeMsg =
        Loaded#{
            <<"priv-wallet">> => Wallet,
            <<"address">> => Address,
            <<"store">> => Store,
            <<"port">> => hb_opts:get(<<"port">>, ?DEFAULT_PORT, Loaded),
            <<"cache-writers">> => [Address]
        },
    io:format("andee-bootstrap=start-http port=~p~n",
        [hb_opts:get(<<"port">>, ?DEFAULT_PORT, NodeMsg)]),
    {ok, _Listener} = hb_http_server:start(NodeMsg),
    io:format(
        "AndEE HyperBEAM node started on port ~p as ~s~n",
        [hb_opts:get(<<"port">>, ?DEFAULT_PORT, NodeMsg), Address]
    ),
    receive
        stop -> ok
    end.

ensure_preloaded_store_environment() ->
    ok = ensure_preloaded_store(),
    case os:getenv("HB_PRELOADED_DEVICES_INDEX") of
        false ->
            os:putenv(
                "HB_PRELOADED_DEVICES_INDEX",
                binary_to_list(read_preloaded_devices_index())
            );
        _ ->
            ok
    end.

ensure_preloaded_store() ->
    case file:read_file_info("_build/preloaded-store/data.mdb") of
        {ok, _} -> ok;
        {error, Reason} -> erlang:error({missing_andee_preloaded_store, Reason})
    end.

read_preloaded_devices_index() ->
    case file:read_file("_build/hb_preloaded_index.hrl") of
        {ok, Bin} ->
            case re:run(
                Bin,
                <<"PRELOADED_DEVICES_INDEX_MESSAGE_ID, <<\"([^\"]+)\">>">>,
                [{capture, [1], binary}]
            ) of
                {match, [Index]} -> Index;
                nomatch -> erlang:error(missing_andee_preloaded_devices_index)
            end;
        {error, Reason} ->
            erlang:error({missing_andee_preloaded_devices_index, Reason})
    end.

start_store(Opts) ->
    Store = hb_opts:get(<<"store">>, no_store, Opts),
    Defaults = hb_opts:get(<<"store-defaults">>, #{}, Opts),
    Updated =
        case Store of
            no_store -> no_store;
            StoreList when is_list(StoreList) -> hb_store_opts:apply(StoreList, Defaults);
            Other -> Other
        end,
    hb_store:start(Updated),
    Updated.

load_config(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> decode_json_config(hb_json:decode(Bin));
        {error, Reason} -> erlang:error({failed_to_load_andee_config, Path, Reason})
    end.

decode_json_config(Values) when is_list(Values) ->
    [decode_json_config(Value) || Value <- Values];
decode_json_config(Config) when is_map(Config) ->
    Types = decode_ao_types(Config),
    maps:fold(
        fun
            (<<"ao-types">>, _Value, Acc) ->
                Acc;
            (RawKey, BinValue, Acc) when is_binary(BinValue) ->
                case hb_maps:find(hb_ao:normalize_key(RawKey), Types, #{}) of
                    error -> Acc#{RawKey => BinValue};
                    {ok, Type} -> Acc#{RawKey => hb_util:decode(Type, BinValue)}
                end;
            (RawKey, Child, Acc) when is_map(Child) or is_list(Child) ->
                Acc#{RawKey => decode_json_config(Child)};
            (RawKey, Value, Acc) ->
                Acc#{RawKey => Value}
        end,
        #{},
        Config
    );
decode_json_config(Value) ->
    Value.

decode_ao_types(Config) when is_map(Config) ->
    decode_ao_types(hb_maps:get(<<"ao-types">>, Config, <<>>, #{}));
decode_ao_types(Bin) when is_binary(Bin) ->
    hb_maps:from_list(
        lists:map(
            fun({Key, {item, {_, Value}, _}}) ->
                {hb_escape:decode(Key), Value}
            end,
            hb_structured_fields:parse_dictionary(Bin)
        )
    ).

runtime_environment() ->
    maps:from_list(
        [
            {Key, Value}
         || {Name, Key} <- runtime_environment_keys(),
            {ok, Value} <- [env_binary(Name)]
        ]
    ).

runtime_environment_keys() ->
    [
        {"ANDEE_RUNTIME_ROOT", <<"andee-runtime-root">>},
        {"ANDEE_PACKAGE_NAME", <<"andee-package-name">>},
        {"ANDEE_VERSION_NAME", <<"andee-version-name">>},
        {"ANDEE_VERSION_CODE", <<"andee-version-code">>},
        {"ANDEE_RELEASE_DIGEST", <<"andee-release-digest">>},
        {"ANDEE_NATIVE_LIB_DIR", <<"andee-native-lib-dir">>},
        {"ANDEE_ANDROID_ABI", <<"andee-android-abi">>},
        {"ANDEE_BOOT_CONFIG", <<"andee-boot-config">>},
        {"ANDEE_RUNTIME_ZIP_SHA256", <<"andee-runtime-zip-sha256">>},
        {"ANDEE_BASE_APK_SHA256", <<"andee-base-apk-sha256">>},
        {"ANDEE_APK_SET_SHA256", <<"andee-apk-set-sha256">>},
        {"ANDEE_NATIVE_LAUNCHER_SHA256", <<"andee-native-launcher-sha256">>},
        {"ANDEE_NATIVE_LIBRARIES_SHA256", <<"andee-native-libraries-sha256">>}
    ].

without_runtime_environment_keys(Config) ->
    lists:foldl(
        fun({_Name, Key}, Acc) -> maps:remove(Key, Acc) end,
        Config,
        runtime_environment_keys()
    ).

env_binary(Name) ->
    case os:getenv(Name) of
        false -> false;
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

ensure_runtime_applications() ->
    lists:foreach(
        fun(App) ->
            case application:ensure_all_started(App) of
                {ok, _Started} -> ok;
                {error, {already_started, _}} -> ok;
                {error, Reason} ->
                    erlang:error({failed_to_start_andee_runtime_app, App, Reason})
            end
        end,
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, certifi, hackney, elmdb]
    ).

configure_public_key_cacerts() ->
    Cacerts =
        case code:priv_dir(certifi) of
            {error, PrivReason} ->
                erlang:error({missing_andee_certifi, PrivReason});
            PrivDir -> filename:join(PrivDir, "cacerts.pem")
        end,
    application:set_env(public_key, cacerts_path, Cacerts),
    public_key:cacerts_clear(),
    case public_key:cacerts_load(Cacerts) of
        ok ->
            io:format("andee-bootstrap=cacerts-loaded path=~ts~n", [Cacerts]);
        {error, LoadReason} ->
            erlang:error({failed_to_load_andee_cacerts, Cacerts, LoadReason})
    end.

ephemeral_wallet() ->
    ar_wallet:new({rsa, 65537}).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

runtime_environment_whitelists_artifact_facts_test() ->
    setenv("ANDEE_RUNTIME_ZIP_SHA256", "runtime-id"),
    setenv("ANDEE_BASE_APK_SHA256", "apk-id"),
    setenv("ANDEE_IGNORED_INTERNAL", "do-not-expose"),
    try
        Env = runtime_environment(),
        ?assertEqual(<<"runtime-id">>,
            hb_maps:get(<<"andee-runtime-zip-sha256">>, Env, undefined)),
        ?assertEqual(<<"apk-id">>,
            hb_maps:get(<<"andee-base-apk-sha256">>, Env, undefined)),
        ?assertEqual(undefined,
            hb_maps:get(<<"andee-ignored-internal">>, Env, undefined))
    after
        os:unsetenv("ANDEE_RUNTIME_ZIP_SHA256"),
        os:unsetenv("ANDEE_BASE_APK_SHA256"),
        os:unsetenv("ANDEE_IGNORED_INTERNAL")
    end.

setenv(Name, Value) ->
    os:putenv(Name, Value).

runtime_environment_keys_are_reserved_test() ->
    ?assertEqual(
        #{<<"other">> => <<"kept">>},
        without_runtime_environment_keys(#{
            <<"other">> => <<"kept">>,
            <<"andee-runtime-zip-sha256">> => <<"forged">>,
            <<"andee-base-apk-sha256">> => <<"forged">>
        })
    ).

load_config_honors_json_ao_types_test() ->
    Path =
        filename:join(
            <<"/tmp">>,
            <<"andee_config_",
                (integer_to_binary(erlang:unique_integer([positive])))/binary,
                ".json">>
        ),
    JSON =
        <<"""
        {
          "ao-types": "scheduling-mode=\"atom\"",
          "store": [
            {
              "store-module": "hb_store_volatile",
              "name": "runtime",
              "ao-types": "store-module=\"atom\""
            },
            {
              "store-module": "hb_store_gateway",
              "ao-types": "store-module=\"atom\"",
              "local-store": [
                {
                  "store-module": "hb_store_volatile",
                  "name": "runtime",
                  "ao-types": "store-module=\"atom\""
                }
              ]
            }
          ],
          "scheduling-mode": "local_confirmation"
        }
        """>>,
    ok = file:write_file(Path, JSON),
    Normalized =
        try load_config(Path)
        after file:delete(Path)
        end,
    ?assertMatch(
        [
            #{
                <<"store-module">> := <<"hb_store_volatile">>,
                <<"ao-types">> := _
            },
            _
        ],
        maps:get(<<"store">>, hb_json:decode(JSON))
    ),
    ?assertMatch(
        [
            #{
                <<"store-module">> := hb_store_volatile
            },
            #{
                <<"store-module">> := hb_store_gateway,
                <<"local-store">> :=
                    [#{<<"store-module">> := hb_store_volatile}]
            }
        ],
        maps:get(<<"store">>, Normalized)
    ),
    ?assertNot(maps:is_key(<<"ao-types">>, Normalized)),
    ?assertEqual(local_confirmation, maps:get(<<"scheduling-mode">>, Normalized)).

-endif.
