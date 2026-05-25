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
    Env = hb_opts:default_message_with_env(),
    ConfigPath = hb_opts:get(<<"hb-config-location">>, ?DEFAULT_CONFIG, Env),
    start(ConfigPath).

start(ConfigPath) ->
    io:format("andee-bootstrap=load-config path=~ts~n", [hb_util:bin(ConfigPath)]),
    Env = hb_opts:default_message_with_env(),
    Loaded = with_bootstrap_devices(load_config(ConfigPath)),
    io:format("andee-bootstrap=config-loaded~n"),
    Merged = hb_maps:merge(Env, Loaded),
    ensure_runtime_applications(),
    hb_http_client:setup_conn(Merged),
    io:format("andee-bootstrap=start-store~n"),
    Store = start_store(Merged),
    io:format("andee-bootstrap=generate-wallet~n"),
    Wallet = ephemeral_wallet(),
    io:format("andee-bootstrap=derive-address~n"),
    Address = hb_util:human_id(ar_wallet:to_address(Wallet)),
    io:format("andee-bootstrap=build-node-subject address=~s~n", [Address]),
    SubjectOpts = Loaded#{<<"address">> => Address},
    NodeSubject = dev_andee:node_subject(SubjectOpts),
    io:format("andee-bootstrap=derive-node-message-id~n"),
    NodeMessageID = dev_andee:node_message_id(SubjectOpts),
    io:format("andee-bootstrap=node-message-id id=~s~n", [NodeMessageID]),
    NodeMsg =
        Loaded#{
            <<"priv-wallet">> => Wallet,
            <<"address">> => Address,
            <<"store">> => Store,
            <<"port">> => hb_opts:get(<<"port">>, ?DEFAULT_PORT, Loaded),
            <<"cache-writers">> => [Address],
            <<"andee-node-message-id">> => NodeMessageID,
            <<"andee-node-subject">> => NodeSubject
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
    normalize_config_atoms(
        maps:update_with(<<"store">>, fun normalize_stores/1, Config)
    ).

normalize_config_atoms(Config) ->
    maps:map(
        fun
            (<<"protocol">>, <<"http1">>) -> http1;
            (<<"protocol">>, <<"http2">>) -> http2;
            (<<"protocol">>, <<"http3">>) -> http3;
            (<<"scheduling-mode">>, <<"aggressive">>) -> aggressive;
            (<<"scheduling-mode">>, <<"local_confirmation">>) -> local_confirmation;
            (<<"scheduling-mode">>, <<"remote_confirmation">>) -> remote_confirmation;
            (<<"scheduling-mode">>, <<"disabled">>) -> disabled;
            (<<"compute-mode">>, <<"aggressive">>) -> aggressive;
            (<<"compute-mode">>, <<"lazy">>) -> lazy;
            (_Key, Value) -> Value
        end,
        Config
    ).

normalize_stores(Stores) when is_list(Stores) ->
    [normalize_store(Store) || Store <- Stores];
normalize_stores(Other) ->
    Other.

normalize_store(Store) when is_map(Store) ->
    maps:map(
        fun
            (<<"store-module">>, <<"hb_store_volatile">>) -> hb_store_volatile;
            (<<"store-module">>, <<"hb_store_lmdb">>) -> hb_store_lmdb;
            (<<"store-module">>, <<"hb_store_fs">>) -> hb_store_fs;
            (<<"store-module">>, <<"hb_store_andee_encrypted">>) ->
                hb_store_andee_encrypted;
            (<<"store-module">>, <<"hb_store_gateway">>) -> hb_store_gateway;
            (<<"store-module">>, <<"hb_store_remote_node">>) -> hb_store_remote_node;
            (<<"store">>, SubStores) -> normalize_stores(SubStores);
            (_Key, Value) -> Value
        end,
        Store
    );
normalize_store(Other) ->
    Other.

with_bootstrap_devices(Config) ->
    Devices = bootstrap_devices(),
    maps:foreach(fun ensure_bootstrap_device_loaded/2, Devices),
    Config#{ <<"forge-bootstrap">> => Devices }.

ensure_bootstrap_device_loaded(_Name, Mod) ->
    case code:ensure_loaded(Mod) of
        {module, Mod} -> ok;
        {error, Reason} -> erlang:error({failed_to_load_andee_bootstrap_device, Mod, Reason})
    end.

bootstrap_devices() ->
    #{
        <<"message@1.0">> => dev_message,
        <<"httpsig@1.0">> => dev_httpsig,
        <<"structured@1.0">> => dev_structured,
        <<"flat@1.0">> => dev_flat,
        <<"json@1.0">> => dev_json,
        <<"json-iface@1.0">> => dev_json_iface,
        <<"ans104@1.0">> => dev_ans104,
        <<"tx@1.0">> => dev_tx,
        <<"cookie@1.0">> => dev_cookie,
        <<"auth-hook@1.0">> => dev_auth_hook,
        <<"http-auth@1.0">> => dev_http_auth,
        <<"secret@1.0">> => dev_secret,
        <<"meta@1.0">> => dev_andee_meta,
        <<"hyperbuddy@1.0">> => dev_hyperbuddy,
        <<"name@1.0">> => dev_name,
        <<"b32-name@1.0">> => dev_b32_name,
        <<"local-name@1.0">> => dev_local_name,
        <<"query@1.0">> => dev_query,
        <<"manifest@1.0">> => dev_manifest,
        <<"relay@1.0">> => dev_relay,
        <<"arweave@2.9">> => dev_arweave,
        <<"p4@1.0">> => dev_p4,
        <<"simple-pay@1.0">> => dev_simple_pay,
        <<"metering@1.0">> => dev_metering,
        <<"bundler@1.0">> => dev_bundler,
        <<"process@1.0">> => dev_process,
        <<"node-process@1.0">> => dev_node_process,
        <<"scheduler@1.0">> => dev_scheduler,
        <<"scheduler-cache@1.0">> => dev_scheduler_cache,
        <<"process-cache@1.0">> => dev_process_cache,
        <<"push@1.0">> => dev_push,
        <<"lua@5.3a">> => dev_lua,
        <<"stack@1.0">> => dev_stack,
        <<"cron@1.0">> => dev_cron,
        <<"location@1.0">> => dev_location,
        <<"ao-payment@1.0">> => dev_aopayment,
        <<"arweave-byte-pricing@1.0">> => dev_arweave_byte_pricing,
        <<"bundler-settlement@1.0">> => dev_bundler_settlement,
        <<"lapee-bundler-gc@1.0">> => dev_lapee_bundler_gc,
        <<"lapee-p4-bootstrap@1.0">> => dev_lapee_p4_bootstrap,
        <<"pricing-router@1.0">> => dev_pricing_router,
        <<"process-ledger@1.0">> => dev_process_ledger,
        <<"simple-oracle@1.0">> => dev_simple_oracle,
        <<"9UWGmklgbqBBA4R4PjXUVAq36E2LHDrGlSFYj47PYpA">> => dev_aopayment,
        <<"oFa5rQ5Z22OwEqUuM6-CdPfnP00txmgloQVkyJlvGUY">> =>
            dev_arweave_byte_pricing,
        <<"e2UIQeUAQ3ZJagogjrJE3arMq4TNq4nNCIWzWKd_kSA">> =>
            dev_bundler_settlement,
        <<"Lwg6OIIDQS1x_wllEl6NRpuoq-GIuNiViWvWHfwydg4">> =>
            dev_lapee_bundler_gc,
        <<"nWaRhtbUD2nAF4gJe9QgPbyeXS_UUEABEtgrXzqoM1w">> =>
            dev_lapee_p4_bootstrap,
        <<"b3I0in7ymZvek_TrkNabBRg-UORNV0IB1irm8OiVSu4">> => dev_metering,
        <<"qNj7rWBlIN4hvtH2HFx3EYhj-AdNSYtbwgy6WQdZ_YE">> =>
            dev_pricing_router,
        <<"LzW6-EdC6tVSyymRxAycnYMSXo6fWRfsIFPGFjLKFR0">> =>
            dev_process_ledger,
        <<"wWYW_nB3jb5PhwWCZtM93wKTR6gGSGKfaiuj3lNu7Fg">> =>
            dev_simple_oracle,
        <<"cache@1.0">> => dev_cache,
        <<"router@1.0">> => dev_router,
        <<"tpm@2.0a">> => dev_tpm2,
        <<"snp@1.0">> => dev_lapee_snp,
        <<"andee@1.0">> => dev_andee,
        <<"measurement@1.0">> => dev_measurement,
        <<"system@1.0">> => dev_system,
        <<"zone@1.0">> => dev_zone
    }.

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
        [crypto, public_key, ssl, inets, ranch, cowboy, gun, hackney]
    ).

ephemeral_wallet() ->
    ar_wallet:new({rsa, 65537}).
