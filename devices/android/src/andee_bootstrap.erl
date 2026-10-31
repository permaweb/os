%%% @doc Android entrypoint for AndEE's bundled HyperBEAM node.
%%%
%%% The Android native launcher calls this module to load the enforced config,
%%% bind the node/config identity into the measurement context, and start the
%%% HTTP node in the foreground VM. The node wallet follows stock HyperBEAM
%%% `priv-key-location' semantics. Android supplies an app-private default path
%%% that persists across service restarts but is never projected into runtime
%%% facts or passed to an isolated execution worker.
-module(andee_bootstrap).

-export([start/0, start/1]).

-define(DEFAULT_CONFIG, <<"config/andee.json">>).
-define(DEFAULT_PORT, 8734).

start() ->
    ensure_preloaded_store(),
    Env = hb_opts:default_message_with_env(),
    ConfigPath = hb_opts:get(<<"hb-config-location">>, ?DEFAULT_CONFIG, Env),
    start(ConfigPath).

start(ConfigPath) ->
    ensure_preloaded_store(),
    % Register the bundled kernel modules before decoding atom-typed config.
    application:load(hb),
    io:format("andee-bootstrap=load-config path=~ts~n", [hb_util:bin(ConfigPath)]),
    Env = hb_opts:default_message_with_env(),
    Loaded =
        hb_maps:merge(
            without_runtime_environment_keys(load_config(ConfigPath)),
            runtime_environment()
        ),
    io:format("andee-bootstrap=config-loaded~n"),
    Configured = merge_hooks(Env, Loaded),
    Merged = hb_maps:merge(Env, Configured),
    ensure_runtime_applications(),
    configure_public_key_cacerts(),
    ok = hb_http_client:init_prometheus(),
    io:format("andee-bootstrap=start-store~n"),
    Store = start_store(Merged),
    io:format("andee-bootstrap=load-wallet~n"),
    Wallet = node_wallet(Configured),
    io:format("andee-bootstrap=derive-address~n"),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    NodeMsg =
        Configured#{
            <<"priv-wallet">> => Wallet,
            <<"address">> => Address,
            <<"store">> => Store,
            <<"port">> => hb_opts:get(<<"port">>, ?DEFAULT_PORT, Configured),
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

%% Configured event hooks extend the stock HyperBEAM chain by event name.
%% Without this merge, AndEE's measurement `on/start' hook replaces the
%% default `on/request' chain, disabling normal name and manifest resolution.
merge_hooks(Env, Configured) ->
    Configured#{
        <<"on">> =>
            hb_maps:merge(
                hb_maps:get(<<"on">>, Env, #{}, Env),
                hb_maps:get(<<"on">>, Configured, #{}, Env)
            )
    }.

ensure_preloaded_store() ->
    case file:read_file_info("_build/preloaded-store/data.mdb") of
        {ok, _} -> ok;
        {error, Reason} -> erlang:error({missing_andee_preloaded_store, Reason})
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
    case hb_opts:load(Path, #{}) of
        {ok, Config} -> Config;
        {error, Reason} -> erlang:error({failed_to_load_andee_config, Path, Reason})
    end.

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

node_wallet(Configured) ->
    hb:wallet(wallet_location(Configured)).

wallet_location(Configured) ->
    Default =
        case env_binary("ANDEE_NODE_WALLET") of
            {ok, Location} -> Location;
            false -> <<"hyperbeam-key.json">>
        end,
    hb_opts:get(
        <<"priv-key-location">>,
        Default,
        Configured#{<<"only">> => local}
    ).

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

wallet_location_uses_private_default_and_normal_override_test() ->
    setenv("ANDEE_NODE_WALLET", "/tmp/andee-default-wallet.json"),
    try
        ?assertEqual(
            <<"/tmp/andee-default-wallet.json">>,
            wallet_location(#{})
        ),
        ?assertEqual(
            <<"operator-wallet.json">>,
            wallet_location(#{
                <<"priv-key-location">> => <<"operator-wallet.json">>
            })
        )
    after
        os:unsetenv("ANDEE_NODE_WALLET")
    end.

node_wallet_reloads_stable_identity_test() ->
    Path =
        filename:join(
            <<"/tmp">>,
            <<"andee_wallet_",
                (integer_to_binary(erlang:unique_integer([positive])))/binary,
                ".json">>
        ),
    Original = ar_wallet:new({eddsa, ed25519}),
    ok = file:write_file(Path, ar_wallet:to_json(Original)),
    try
        First = node_wallet(#{<<"priv-key-location">> => Path}),
        Second = node_wallet(#{<<"priv-key-location">> => Path}),
        ?assertEqual(ar_wallet:to_address(Original), ar_wallet:to_address(First)),
        ?assertEqual(ar_wallet:to_address(First), ar_wallet:to_address(Second))
    after
        file:delete(Path)
    end.

configured_hooks_preserve_default_request_chain_test() ->
    DefaultRequest = [#{ <<"device">> => <<"manifest@1.0">> }],
    MeasurementStart = #{
        <<"device">> => <<"measurement@1.0">>,
        <<"path">> => <<"boot">>
    },
    Merged =
        merge_hooks(
            #{ <<"on">> => #{ <<"request">> => DefaultRequest } },
            #{ <<"on">> => #{ <<"start">> => MeasurementStart } }
        ),
    ?assertEqual(
        DefaultRequest,
        hb_maps:get(<<"request">>, hb_maps:get(<<"on">>, Merged), undefined)
    ),
    ?assertEqual(
        MeasurementStart,
        hb_maps:get(<<"start">>, hb_maps:get(<<"on">>, Merged), undefined)
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
          "ao-types": "atom=(\"scheduling-mode\")",
          "store": [
            {
              "store-module": "hb_store_volatile",
              "name": "runtime",
              "ao-types": "atom=(\"store-module\")"
            },
            {
              "store-module": "hb_store_gateway",
              "ao-types": "atom=(\"store-module\")",
              "local-store": [
                {
                  "store-module": "hb_store_volatile",
                  "name": "runtime",
                  "ao-types": "atom=(\"store-module\")"
                }
              ]
            }
          ],
          "scheduling-mode": "local_confirmation",
          "priv-store": [{
            "store-module": "hb_store_volatile",
            "name": "private-runtime",
            "ao-types": "atom=(\"store-module\")"
          }],
          "inference-providers": {
            "external": {"priv": {"api-key": "opaque-test-key"}}
          }
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
    ?assertMatch([#{<<"store-module">> := hb_store_volatile}],
        maps:get(<<"priv-store">>, Normalized)),
    ?assertEqual(<<"opaque-test-key">>,
        hb_private:get(<<"api-key">>,
            maps:get(<<"external">>, maps:get(<<"inference-providers">>, Normalized)), #{})),
    ?assertNot(maps:is_key(<<"ao-types">>, Normalized)),
    ?assertEqual(local_confirmation, maps:get(<<"scheduling-mode">>, Normalized)).

remote_indexed_arweave_store_decoding_test() ->
    Path = filename:join(<<"/tmp">>,
        <<"andee_remote_config_",
            (integer_to_binary(erlang:unique_integer([positive])))/binary,
            ".json">>),
    ok = file:write_file(Path, <<"""
        {"store": [{
          "store-module": "hb_store_arweave",
          "ao-types": "atom=(\"store-module\")",
          "index-store": [{
            "store-module": "hb_store_volatile",
            "name": "index",
            "ao-types": "atom=(\"store-module\")"
          }, {
            "store-module": "hb_store_arlmdb",
            "name": "published-offset-index",
            "root": "7vg2832WFsisEcBr1oBQ8ldc4EGOkjQdwW46hDvJsOs",
            "prefix": "~arweave@2.9/offset=",
            "to-key": "~base64url@1.0/decode/~bits@1.0/take=77",
            "from-value": "~bits@1.0/from=_:77,start:49+integer,length:34+integer",
            "ao-types": "atom=(\"store-module\")"
          }, {
            "store-module": "hb_store_arlmdb",
            "name": "published-redstone-offset-index",
            "root": "aOlX-irO0DEKk1U0dP4ZEoBNd2LyKVXFqaEUuxpihLI",
            "prefix": "~arweave@2.9/offset=",
            "to-key": "~base64url@1.0/decode/~bits@1.0/take=77",
            "from-value": "~bits@1.0/from=_:77,start:49+integer,length:34+integer/set&codec=ans104@1.0",
            "ao-types": "atom=(\"store-module\")"
          }, {
            "store-module": "hb_store_arlmdb",
            "name": "published-l1-offset-index",
            "root": "_BjLm7-qslpbSLcqNBQepUZMFoxgdeIbOdnRsaPAnuQ",
            "prefix": "~arweave@2.9/offset=",
            "to-key": "~base64url@1.0/decode/~bits@1.0/take=71",
            "from-value": "~bits@1.0/from=_:71,start:49+integer,length:40+integer/set&codec=tx@1.0",
            "ao-types": "atom=(\"store-module\")"
          }],
          "local-store": [{
            "store-module": "hb_store_fs",
            "name": "/tmp/cache",
            "ao-types": "atom=(\"store-module\")"
          }],
          "remote-index": true
        }]}
    """>>),
    Config = try load_config(Path) after file:delete(Path) end,
    [Store] = maps:get(<<"store">>, Config),
    ?assertEqual(hb_store_arweave, maps:get(<<"store-module">>, Store)),
    ?assertEqual(true, maps:get(<<"remote-index">>, Store)),
    [Index | PublishedIndexes] = maps:get(<<"index-store">>, Store),
    ?assertEqual(hb_store_volatile, maps:get(<<"store-module">>, Index)),
    [DefaultArweave] = [
        S || S <- maps:get(<<"store">>, hb_opts:default_message()),
        maps:get(<<"store-module">>, S) == hb_store_arweave
    ],
    [_Primary | UpstreamIndexes] = maps:get(<<"index-store">>, DefaultArweave),
    ?assertEqual(3, length(PublishedIndexes)),
    ?assertEqual(UpstreamIndexes, PublishedIndexes),
    [Local] = maps:get(<<"local-store">>, Store),
    ?assertEqual(hb_store_fs, maps:get(<<"store-module">>, Local)).

-endif.
