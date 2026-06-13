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
        {ok, Bin} -> normalize_config(hb_json:decode(Bin));
        {error, Reason} -> erlang:error({failed_to_load_andee_config, Path, Reason})
    end.

normalize_config(Config) when is_map(Config) ->
    normalize_config_value(Config).

normalize_config_value(Config) when is_map(Config) ->
    maps:map(
        fun
            (<<"store-module">>, Value) -> normalize_store_module(Value);
            (<<"protocol">>, <<"http1">>) -> http1;
            (<<"protocol">>, <<"http2">>) -> http2;
            (<<"protocol">>, <<"http3">>) -> http3;
            (<<"scheduling-mode">>, <<"aggressive">>) -> aggressive;
            (<<"scheduling-mode">>, <<"local_confirmation">>) -> local_confirmation;
            (<<"scheduling-mode">>, <<"remote_confirmation">>) -> remote_confirmation;
            (<<"scheduling-mode">>, <<"disabled">>) -> disabled;
            (<<"compute-mode">>, <<"aggressive">>) -> aggressive;
            (<<"compute-mode">>, <<"lazy">>) -> lazy;
            (_Key, Value) -> normalize_config_value(Value)
        end,
        Config
    );
normalize_config_value(Values) when is_list(Values) ->
    [normalize_config_value(Value) || Value <- Values];
normalize_config_value(Value) ->
    Value.

normalize_store_module(<<"hb_store_volatile">>) -> hb_store_volatile;
normalize_store_module(Value) -> normalize_config_value(Value).

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

normalize_config_coerces_nested_volatile_store_modules_test() ->
    Config =
        #{
            <<"store">> =>
                [
                    #{
                        <<"store-module">> => <<"hb_store_volatile">>,
                        <<"name">> => <<"runtime">>
                    }
                ],
            <<"match-index">> =>
                [
                    #{
                        <<"store-module">> => <<"hb_store_volatile">>,
                        <<"name">> => <<"match">>
                    }
                ],
            <<"priv-store">> =>
                [
                    #{
                        <<"store-module">> => <<"hb_store_volatile">>,
                        <<"name">> => <<"priv">>
                    }
                ],
            <<"scheduling-mode">> => <<"local_confirmation">>,
            <<"on">> =>
                #{
                    <<"start">> =>
                        [
                            #{
                                <<"device">> => <<"measurement@1.0">>,
                                <<"store-module">> => <<"not-a-store-module">>
                            }
                        ]
                }
        },
    Normalized = normalize_config(Config),
    ?assertMatch(
        [#{<<"store-module">> := hb_store_volatile}],
        maps:get(<<"store">>, Normalized)
    ),
    ?assertMatch(
        [#{<<"store-module">> := hb_store_volatile}],
        maps:get(<<"match-index">>, Normalized)
    ),
    ?assertMatch(
        [#{<<"store-module">> := hb_store_volatile}],
        maps:get(<<"priv-store">>, Normalized)
    ),
    ?assertEqual(local_confirmation, maps:get(<<"scheduling-mode">>, Normalized)),
    [Hook] = maps:get(<<"start">>, maps:get(<<"on">>, Normalized)),
    ?assertEqual(<<"not-a-store-module">>, maps:get(<<"store-module">>, Hook)).

-endif.
