%%% @doc P4 pricing adapter for Arweave byte costs in AO base units.
%%%
%%% This device keeps `metering@1.0' generic. It opens/closes the canonical
%%% metering session, reads the consumed `arweave-bytes' count using a unit
%%% metering rate, and converts the Arweave gateway `/price' result into AO
%%% base units using `simple-oracle@1.0' AR and AO USD prices.
-module(dev_arweave_byte_pricing).
-export([info/1, estimate/3, price/3, quote/3]).

-include_lib("hb/include/hb.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(ORACLE_SCALE, 1_000_000_000).
-define(BEAM_REDUCTIONS, <<"beam-reductions">>).

%% @doc Device API information.
info(_) ->
    #{ exports => [<<"estimate">>, <<"price">>, <<"quote">>] }.

%% @doc Open metering and estimate the cost of a bundler upload if possible.
estimate(Base, Req, Opts) ->
    case hb_ao:resolve(
        metering_msg(Base, Opts),
        request_with_path(Req, <<"estimate">>, Opts),
        Opts
    ) of
        {ok, _} ->
            case bundler_upload_subject(Req, Opts) of
                {ok, Item} ->
                    quote_bundled_item(Item, Base, Opts);
                false ->
                    {ok, 0}
            end;
        Error ->
            Error
    end.

%% @doc Close metering and dynamically price consumed Arweave bytes.
price(Base, Req, Opts) ->
    UnitOpts =
        Opts#{
            <<"metering-rates">> => #{
                <<"arweave-bytes">> => 1,
                ?BEAM_REDUCTIONS => 0
            }
        },
    case hb_ao:resolve(
        metering_msg(Base, Opts),
        request_with_path(Req, <<"price">>, Opts),
        UnitOpts
    ) of
        {ok, Amount} ->
            quote_amount(Amount, Base, Opts);
        Error ->
            Error
    end.

%% @doc Price an explicit `arweave-bytes' resource amount.
quote(Base, Req, Opts) ->
    Resource = hb_ao:normalize_key(hb_maps:get(<<"resource">>, Req, <<>>, Opts)),
    case Resource of
        <<"arweave-bytes">> ->
            Amount = hb_util:int(hb_maps:get(<<"amount">>, Req, 0, Opts)),
            quote_amount(Amount, Base, Opts);
        _ ->
            {error, {unsupported_resource, Resource}}
    end.

%% @doc Return the configured metering device message.
metering_msg(Base, Opts) ->
    Device0 =
        hb_maps:get(
            <<"metering-device">>,
            Base,
            hb_opts:get(
                arweave_byte_pricing_metering_device,
                <<"metering@1.0">>,
                Opts
            ),
            Opts
        ),
    Device = named_device_ref(Device0, Opts),
    #{ <<"device">> => Device }.

request_with_path(Req, Path, Opts) ->
    hb_maps:put(<<"path">>, Path, hb_message:uncommitted(Req, Opts), Opts).

%% @doc Extract a bundler upload subject from a P4 pricing request.
bundler_upload_subject(Req, Opts) ->
    Request =
        hb_ao:get(
            <<"request">>,
            Req,
            undefined,
            Opts#{ <<"hashpath">> => ignore }
        ),
    case is_bundler_upload(Request, Opts) of
        true ->
            {ok, bundler_subject(Request, Opts)};
        false ->
            false
    end.

%% @doc Return whether a request targets the bundler upload route.
is_bundler_upload(Req, Opts) when is_map(Req) ->
    Path = path_without_query(hb_maps:get(<<"path">>, Req, <<>>, Opts)),
    lists:member(
        Path,
        [
            <<"/~bundler@1.0/tx">>,
            <<"~bundler@1.0/tx">>,
            <<"/~bundler@1.0/item">>,
            <<"~bundler@1.0/item">>
        ]
    );
is_bundler_upload(_, _) ->
    false.

%% @doc Remove query parameters from a path.
path_without_query(Path) when is_binary(Path) ->
    case binary:split(Path, <<"?">>) of
        [CleanPath, _Query] -> CleanPath;
        [CleanPath] -> CleanPath
    end;
path_without_query(Path) ->
    Path.

%% @doc Resolve the message being uploaded to the bundler.
bundler_subject(Req, Opts) ->
    case hb_maps:find(<<"bundler-subject">>, Req, Opts) of
        {ok, SubjectKey} -> hb_maps:get(SubjectKey, Req, Req, Opts);
        error -> Req
    end.

%% @doc Estimate a bundled item's byte cost.
quote_bundled_item(Item, Base, Opts) ->
    try quote_amount(bundled_item_size(Item, Opts), Base, Opts)
    catch
        Class:Reason:Stack ->
            ?event(
                debug_pricing,
                {bundled_item_estimate_failed, Class, Reason, {trace, Stack}},
                Opts
            ),
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"Unable to estimate Arweave bundle price.">>
            }}
    end.

%% @doc Return the ANS-104 serialized size of a bundled item.
bundled_item_size(Item, Opts) ->
    TX =
        hb_message:convert(
            Item,
            #{ <<"device">> => <<"ans104@1.0">>, <<"bundle">> => true },
            <<"structured@1.0">>,
            Opts
        ),
    byte_size(ar_bundles:serialize(TX)).

%% @doc Price an Arweave byte amount in AO base units.
quote_amount(Amount, _Base, _Opts) when Amount =< 0 ->
    {ok, 0};
quote_amount(Amount, Base, Opts) ->
    case fixed_byte_price(Base, Opts) of
        {ok, Rate} ->
            {ok, Amount * Rate};
        error ->
            dynamic_quote_amount(Amount, Base, Opts)
    end.

%% @doc Return an explicit test/operator byte price if configured.
fixed_byte_price(Base, Opts) ->
    Price =
        hb_maps:get(
            <<"arweave-byte-price">>,
            Base,
            hb_opts:get(<<"arweave-byte-price">>, dynamic, Opts),
            Opts
        ),
    try {ok, hb_util:int(Price)}
    catch _:_ -> error
    end.

%% @doc Price an Arweave byte amount using live gateway and oracle data.
dynamic_quote_amount(Amount, Base, Opts) ->
    {ok, ARWinstons} =
        hb_ao:resolve(
            #{ <<"device">> => <<"arweave@2.9">> },
            #{ <<"path">> => <<"/price">>, <<"size">> => Amount },
            Opts
        ),
    {ok, ARPrice} = oracle_price(<<"AR">>, Base, Opts),
    {ok, AOPrice} = oracle_price(<<"AO">>, Base, Opts),
    {ok,
        div_ceil(
            ARWinstons * scaled_price(ARPrice),
            scaled_price(AOPrice)
        )
    }.

%% @doc Resolve a ticker price through the configured oracle device.
oracle_price(Ticker, Base, Opts) ->
    OracleDevice0 =
        hb_maps:get(
            <<"oracle-device">>,
            Base,
            hb_opts:get(
                arweave_byte_pricing_oracle_device,
                <<"simple-oracle@1.0">>,
                Opts
            ),
            Opts
        ),
    OracleDevice = named_device_ref(OracleDevice0, Opts),
    hb_ao:resolve(
        #{ <<"device">> => OracleDevice },
        #{ <<"path">> => <<"price-now">>, <<"ticker">> => Ticker },
        Opts
    ).

named_device_ref(Name, Opts) ->
    named_device_ref_1(Name, list_opt(<<"name-resolvers">>, Opts), Opts).

named_device_ref_1(Name, [Resolver | Rest], Opts) when is_map(Resolver) ->
    case hb_maps:get(Name, Resolver, not_found, Opts) of
        not_found -> named_device_ref_1(Name, Rest, Opts);
        Ref -> Ref
    end;
named_device_ref_1(Name, [_ | Rest], Opts) ->
    named_device_ref_1(Name, Rest, Opts);
named_device_ref_1(Name, [], _Opts) ->
    Name.

list_opt(Key, Msg) ->
    case hb_maps:get(Key, Msg, [], Msg) of
        Value when is_list(Value) -> Value;
        Value when is_map(Value) ->
            case hb_util:is_ordered_list(Value, Msg) of
                true -> hb_util:message_to_ordered_list(Value, Msg);
                false -> []
            end;
        _ -> []
    end.

%% @doc Convert a decimal price to a fixed-point integer.
scaled_price(Price) ->
    max(1, round(hb_util:float(Price) * ?ORACLE_SCALE)).

%% @doc Integer ceiling division.
div_ceil(Numerator, Denominator) ->
    (Numerator + Denominator - 1) div Denominator.

-ifdef(TEST).

%%% Tests

%% @doc A configured byte price bypasses gateway and oracle lookups.
fixed_byte_price_quote_test() ->
    Pricing = #{ <<"device">> => <<"arweave-byte-pricing@1.0">> },
    {ok, 35} =
        hb_ao:resolve(
            Pricing,
            #{
                <<"path">> => <<"quote">>,
                <<"resource">> => <<"arweave-bytes">>,
                <<"amount">> => 5
            },
            #{
                <<"store">> => hb_test_utils:test_store(),
                <<"arweave-byte-price">> => 7
            }
        ).

%% @doc Dynamic quotes combine Arweave gateway price and oracle AR/AO prices.
dynamic_quote_test() ->
    {GatewayHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(#{ price => {200, <<"100">>} }),
    {ok, OracleURL, OracleHandle} =
        hb_mock_server:start(
            [
                {"/ar", ar, {200, <<"{\"prices\":[[1,6.0]]}">>}},
                {"/ao", ao, {200, <<"{\"prices\":[[1,3.0]]}">>}}
            ]
        ),
    try
        Pricing = #{ <<"device">> => <<"arweave-byte-pricing@1.0">> },
        {ok, 200} =
            hb_ao:resolve(
                Pricing,
                #{
                    <<"path">> => <<"quote">>,
                    <<"resource">> => <<"arweave-bytes">>,
                    <<"amount">> => 123
                },
                oracle_opts(GatewayOpts, OracleURL)
            ),
        ?assertEqual(
            1,
            length(hb_mock_server:get_requests(price, 1, GatewayHandle))
        )
    after
        hb_mock_server:stop(OracleHandle),
        hb_mock_server:stop(GatewayHandle)
    end.

%% @doc The adapter reads canonical metering and then applies dynamic pricing.
metered_price_test() ->
    {GatewayHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(#{ price => {200, <<"100">>} }),
    {ok, OracleURL, OracleHandle} =
        hb_mock_server:start(
            [
                {"/ar", ar, {200, <<"{\"prices\":[[1,6.0]]}">>}},
                {"/ao", ao, {200, <<"{\"prices\":[[1,3.0]]}">>}}
            ]
        ),
    try
        Pricing = #{ <<"device">> => <<"arweave-byte-pricing@1.0">> },
        Opts = oracle_opts(GatewayOpts, OracleURL),
        {ok, 0} =
            hb_ao:resolve(Pricing, #{ <<"path">> => <<"estimate">> }, Opts),
        ok = metering_consume(<<"arweave-bytes">>, 123, Opts),
        {ok, 200} =
            hb_ao:resolve(Pricing, #{ <<"path">> => <<"price">> }, Opts),
        ?assertEqual(
            1,
            length(hb_mock_server:get_requests(price, 1, GatewayHandle))
        )
    after
        hb_mock_server:stop(OracleHandle),
        hb_mock_server:stop(GatewayHandle)
    end.

%% @doc P4 rejects unfunded raw ANS-104 uploads before the bundler runs.
unfunded_raw_bundler_upload_rejected_test() ->
    HostWallet = ar_wallet:new(),
    UploaderWallet = ar_wallet:new(),
    {ServerHandle, GatewayOpts} =
        hb_mock_server:start_arweave_gateway(
            #{
                price => {200, <<"12345">>},
                tx_anchor => {200, hb_util:encode(rand:bytes(32))}
            }
        ),
    Processor =
        #{
            <<"device">> => <<"p4@1.0">>,
            <<"ledger-device">> => <<"simple-pay@1.0">>,
            <<"pricing-device">> => <<"arweave-byte-pricing@1.0">>
        },
    Opts =
        GatewayOpts#{
            <<"priv-wallet">> => HostWallet,
            <<"store">> => hb_test_utils:test_store(),
            <<"bundler-max-items">> => 1,
            <<"arweave-byte-price">> => 2,
            <<"metering-rates">> => #{ ?BEAM_REDUCTIONS => 0 },
            <<"operator">> => ar_wallet:to_address(HostWallet),
            <<"on">> => #{
                <<"request">> => Processor,
                <<"response">> => Processor
            }
        },
    try
        Node = hb_http_server:start_node(Opts),
        RawItem =
            ar_bundles:serialize(
                ar_bundles:sign_item(
                    #tx{
                        data = <<"unfunded-raw-bundler-upload">>,
                        tags = [{<<"content-type">>, <<"text/plain">>}]
                    },
                    UploaderWallet
                )
            ),
        BaseURL = base_url(Node),
        URL =
            binary_to_list(
                <<BaseURL/binary, "/~bundler@1.0/item?codec-device=ans104@1.0">>
            ),
        {ok, {{_, Status, _}, _Headers, _Body}} =
            httpc:request(
                post,
                {
                    URL,
                    [{"content-type", "application/octet-stream"}],
                    "application/octet-stream",
                    RawItem
                },
                [],
                [{body_format, binary}]
            ),
        ?assertEqual(402, Status),
        ?assertEqual(
            0,
            length(hb_mock_server:get_requests(tx, 0, ServerHandle, 200))
        ),
        ?assertEqual(
            0,
            length(hb_mock_server:get_requests(chunk, 0, ServerHandle, 200))
        )
    after
        hb_mock_server:stop(ServerHandle),
        ok
    end.

metering_consume(Resource, Amount, Opts) ->
    {ok, Metering} = hb_device_load:reference(<<"metering@1.0">>, Opts),
    Metering:consume(Resource, Amount, Opts).

oracle_opts(GatewayOpts, OracleURL) ->
    GatewayOpts#{
        <<"store">> => hb_test_utils:test_store(),
        <<"oracle-sources">> => #{
            <<"AR">> => [
                #{
                    <<"shape">> => <<"coingecko-market-chart">>,
                    <<"url">> => <<OracleURL/binary, "/ar">>
                }
            ],
            <<"AO">> => [
                #{
                    <<"shape">> => <<"coingecko-market-chart">>,
                    <<"url">> => <<OracleURL/binary, "/ao">>
                }
            ]
        },
        <<"oracle-cache-ttl-ms">> => 0,
        <<"relay-http-client">> => httpc,
        <<"metering-rates">> => #{ ?BEAM_REDUCTIONS => 0 }
    }.

base_url(Node) ->
    case binary:last(Node) of
        $/ -> binary:part(Node, 0, byte_size(Node) - 1);
        _ -> Node
    end.

-endif.
