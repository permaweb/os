%%% @doc Simple price oracle for token USD prices.
%%%
%%% Resolves a ticker to its current USD price by fetching configured source
%%% endpoints with bounded HTTP calls, parsing each source's response shape,
%%% and returning the average of the latest valid source prices.
-module(dev_simple_oracle).
-export([info/1, price/3, price_now/3]).

-include_lib("hb/include/hb.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_DAYS, 90).
-define(DEFAULT_CACHE_TTL_MS, 300_000).
-define(CACHE_TABLE, dev_simple_oracle_cache).
-define(CACHE_SERVER, {?MODULE, cache}).

%% @doc Device API information.
info(_) ->
    #{ exports => [<<"price">>, <<"price-now">>] }.

%% @doc Alias for `price-now'.
price(Base, Req, Opts) ->
    price_now(Base, Req, Opts).

%% @doc Return the average current USD price for a configured ticker.
price_now(Base, Req, Opts) ->
    Ticker = ticker(Base, Req, Opts),
    Days = days(Base, Req, Opts),
    Sources = sources(Base, Req, Opts),
    case ticker_sources(Ticker, Sources, Opts) of
        {ok, TickerSources} ->
            CacheKey = {price_now, Ticker, Days, erlang:phash2(TickerSources)},
            cached(
                CacheKey,
                Opts,
                fun() -> source_average(TickerSources, Days, Opts) end
            );
        Error ->
            Error
    end.

%% @doc Return the configured sources for a ticker.
ticker_sources(Ticker, Sources, Opts) ->
    case hb_maps:get(Ticker, Sources, not_found, Opts) of
        not_found ->
            {error, #{ <<"status">> => 404, <<"body">> => <<"Unknown ticker.">> }};
        TickerSources when is_list(TickerSources) ->
            {ok, TickerSources};
        _ ->
            {error, invalid_oracle_sources}
    end.

%% @doc Average latest prices from all source endpoints that respond cleanly.
source_average(TickerSources, Days, Opts) ->
    Results =
        lists:map(
            fun(Source) ->
                case fetch_source(Source, Days, Opts) of
                    {ok, Price} ->
                        {ok, Price};
                    Error ->
                        ?event(debug_oracle, {oracle_source_failed, Source, Error}),
                        Error
                end
            end,
            TickerSources
        ),
    Prices = [Price || {ok, Price} <- Results],
    case Prices of
        [] ->
            {error, #{ <<"status">> => 502, <<"body">> => <<"No oracle prices.">> }};
        _ ->
            {ok, hb_util:mean(Prices)}
    end.

%% @doc Fetch and parse a source endpoint through the relay device.
fetch_source(Source, Days, Opts) ->
    URL = source_url(Source, Days),
    case httpc:request(
        get,
        {binary_to_list(URL), [{"accept", "application/json"}]},
        http_options(Opts),
        [{body_format, binary}]
    ) of
        {ok, {{_, Status, _}, _Headers, Body}} when Status >= 200, Status < 300 ->
            parse_source(Source, Body, Opts);
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {oracle_http_status, Status, Body}};
        {error, Reason} ->
            {error, {oracle_http_error, Reason}}
    end.

http_options(Opts) ->
    Timeout =
        hb_util:int(
            hb_opts:get(<<"oracle-source-timeout-ms">>, 5000, Opts)
        ),
    [
        {timeout, Timeout},
        {connect_timeout, Timeout},
        {autoredirect, false},
        {ssl, [
            {verify, verify_peer},
            {cacertfile, certifi:cacertfile()},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ]}
    ].

%% @doc Parse a source response based on its configured response shape.
parse_source(Source, Body, Opts) ->
    try
        Shape =
            hb_ao:normalize_key(
                hb_maps:get(<<"shape">>, Source, <<>>, Opts)
            ),
        Decoded = hb_json:decode(Body),
        case Shape of
            <<"coingecko-market-chart">> ->
                coingecko_price(Decoded);
            <<"coinpaprika-historical">> ->
                coinpaprika_price(Decoded);
            <<"binance-ticker-price">> ->
                binance_price(Decoded);
            <<"gateio-spot-ticker">> ->
                gateio_price(Decoded);
            _ ->
                {error, {unknown_oracle_shape, Shape}}
        end
    catch
        Class:Reason ->
            {error, {invalid_oracle_body, Class, Reason}}
    end.

%% @doc Extract the latest price from CoinGecko's market chart shape.
coingecko_price(#{ <<"prices">> := Prices }) when is_list(Prices) ->
    latest_price(
        lists:filtermap(
            fun
                ([_Timestamp, Price | _]) -> to_price(Price);
                (_) -> false
            end,
            Prices
        )
    );
coingecko_price(_) ->
    {error, invalid_coingecko_response}.

%% @doc Extract the latest price from CoinPaprika's historical ticker shape.
coinpaprika_price(Prices) when is_list(Prices) ->
    latest_price(
        lists:filtermap(
            fun
                (#{ <<"price">> := Price }) -> to_price(Price);
                (_) -> false
            end,
            Prices
        )
    );
coinpaprika_price(_) ->
    {error, invalid_coinpaprika_response}.

%% @doc Extract price from Binance's ticker price shape.
binance_price(#{ <<"price">> := Price }) ->
    case to_price(Price) of
        {true, ParsedPrice} -> {ok, ParsedPrice};
        false -> {error, invalid_binance_response}
    end;
binance_price(_) ->
    {error, invalid_binance_response}.

%% @doc Extract price from Gate.io's spot ticker shape.
gateio_price(Tickers) when is_list(Tickers) ->
    latest_price(
        lists:filtermap(
            fun
                (#{ <<"last">> := Price }) -> to_price(Price);
                (_) -> false
            end,
            Tickers
        )
    );
gateio_price(_) ->
    {error, invalid_gateio_response}.

%% @doc Return the last valid source price.
latest_price([]) ->
    {error, no_prices};
latest_price(Prices) ->
    {ok, lists:last(Prices)}.

%% @doc Normalize JSON numbers to floats.
to_price(Price) when is_integer(Price); is_float(Price) ->
    {true, hb_util:float(Price)};
to_price(Price) when is_binary(Price); is_list(Price) ->
    try {true, hb_util:float(Price)}
    catch _:_ -> false
    end;
to_price(_) ->
    false.

%% @doc Build a source URL with a dynamic date range.
source_url(Source, Days) ->
    source_url(Source, Days, current_date()).
source_url(Source, Days, EndDate) ->
    StartDate =
        calendar:gregorian_days_to_date(
            calendar:date_to_gregorian_days(EndDate) - Days
        ),
    replace_all(
        hb_maps:get(<<"url">>, Source, <<>>, #{}),
        [
            {<<"{{days}}">>, integer_to_binary(Days)},
            {<<"{{start}}">>, date_bin(StartDate)},
            {<<"{{end}}">>, date_bin(EndDate)}
        ]
    ).

%% @doc Replace a set of binary tokens in a binary.
replace_all(Bin, Replacements) ->
    lists:foldl(
        fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
        Bin,
        Replacements
    ).

%% @doc Return the current UTC date.
current_date() ->
    {Date, _Time} =
        calendar:system_time_to_universal_time(
            erlang:system_time(second),
            second
        ),
    Date.

%% @doc Format a date as YYYY-MM-DD.
date_bin({Year, Month, Day}) ->
    iolist_to_binary(
        io_lib:format("~4..0B-~2..0B-~2..0B", [Year, Month, Day])
    ).

%% @doc Read the requested ticker.
ticker(Base, Req, Opts) ->
    Value =
        hb_maps:get(
            <<"ticker">>,
            Req,
            hb_maps:get(<<"ticker">>, Base, not_found, Opts),
            Opts
        ),
    case Value of
        not_found -> not_found;
        _ -> list_to_binary(string:uppercase(binary_to_list(hb_util:bin(Value))))
    end.

%% @doc Read the historical range used by the sources.
days(Base, Req, Opts) ->
    hb_util:int(
        hb_maps:get(
            <<"days">>,
            Req,
            hb_maps:get(
                <<"days">>,
                Base,
                hb_opts:get(oracle_days, ?DEFAULT_DAYS, Opts),
                Opts
            ),
            Opts
        )
    ).

%% @doc Read configured oracle sources.
sources(Base, _Req, Opts) ->
    configured_sources(Base, Opts).

configured_sources(Base, Opts) ->
    hb_maps:get(
        <<"oracle-sources">>,
        Base,
        hb_opts:get(<<"oracle-sources">>, default_sources(), Opts),
        Opts
    ).

%% @doc Default source endpoints.
default_sources() ->
    #{
        <<"AO">> => [
            #{
                <<"shape">> => <<"coingecko-market-chart">>,
                <<"url">> =>
                    <<"https://api.coingecko.com/api/v3/coins/"
                        "ao-computer/market_chart?vs_currency=usd&days={{days}}">>
            },
            #{
                <<"shape">> => <<"coinpaprika-historical">>,
                <<"url">> =>
                    <<"https://api.coinpaprika.com/v1/tickers/"
                        "ao-ao-computer/historical?start={{start}}&end={{end}}"
                        "&interval=1d&quote=usd">>
            },
            #{
                <<"shape">> => <<"gateio-spot-ticker">>,
                <<"url">> =>
                    <<"https://api.gateio.ws/api/v4/spot/tickers?"
                        "currency_pair=AO_USDT">>
            }
        ],
        <<"AR">> => [
            #{
                <<"shape">> => <<"coingecko-market-chart">>,
                <<"url">> =>
                    <<"https://api.coingecko.com/api/v3/coins/"
                        "arweave/market_chart?vs_currency=usd&days={{days}}">>
            },
            #{
                <<"shape">> => <<"coinpaprika-historical">>,
                <<"url">> =>
                    <<"https://api.coinpaprika.com/v1/tickers/"
                        "ar-arweave/historical?start={{start}}&end={{end}}"
                        "&interval=1d&quote=usd">>
            },
            #{
                <<"shape">> => <<"binance-ticker-price">>,
                <<"url">> =>
                    <<"https://api.binance.com/api/v3/ticker/price?"
                        "symbol=ARUSDT">>
            }
        ]
    }.

%% @doc Read-through cache for oracle prices.
cached(Key, Opts, Fun) ->
    TTL =
        hb_opts:get(
            <<"oracle-cache-ttl-ms">>,
            hb_opts:get(oracle_cache_ttl_ms, ?DEFAULT_CACHE_TTL_MS, Opts),
            Opts
        ),
    case TTL =< 0 of
        true ->
            Fun();
        false ->
            ensure_cache(),
            Now = erlang:system_time(millisecond),
            case cache_lookup(Key) of
                [{Key, Timestamp, Price}] when Now - Timestamp =< TTL ->
                    {ok, Price};
                _ ->
                    case Fun() of
                        {ok, Price} ->
                            cache_insert(Key, Now, Price),
                            {ok, Price};
                        Error ->
                            Error
                    end
            end
    end.

%% @doc Ensure the oracle cache table exists.
ensure_cache() ->
    PID = hb_name:singleton(?CACHE_SERVER, fun cache_server/0),
    hb_util:wait_until(
        fun() -> ets:info(?CACHE_TABLE, owner) =:= PID end,
        1000
    ),
    ok.

cache_server() ->
    case ets:info(?CACHE_TABLE) of
        undefined ->
            ets:new(
                ?CACHE_TABLE,
                [
                    named_table,
                    public,
                    set,
                    {read_concurrency, true},
                    {write_concurrency, true}
                ]
            ),
            receive stop -> ok end;
        _ ->
            timer:sleep(100),
            cache_server()
    end.

cache_lookup(Key) ->
    try ets:lookup(?CACHE_TABLE, Key)
    catch error:badarg -> []
    end.

cache_insert(Key, Timestamp, Price) ->
    try ets:insert(?CACHE_TABLE, {Key, Timestamp, Price}) of
        true -> ok
    catch error:badarg -> ok
    end.

-ifdef(TEST).

%%% Tests

%% @doc Source URLs use the current call date window.
source_url_dynamic_date_test() ->
    Source =
        #{
            <<"url">> =>
                <<"https://example.invalid/history?"
                    "start={{start}}&end={{end}}&days={{days}}">>
        },
    ?assertEqual(
        <<"https://example.invalid/history?"
            "start=2026-02-05&end=2026-05-06&days=90">>,
        source_url(Source, 90, {2026, 5, 6})
    ).

%% @doc Cache table is owned by a singleton process, not a request process.
cache_owner_test() ->
    ensure_cache(),
    ?assertNotEqual(self(), ets:info(?CACHE_TABLE, owner)).

%% @doc The parser averages latest prices from relay-fetched source shapes.
price_now_mock_sources_test() ->
    {ok, MockURL, MockHandle} =
        hb_mock_server:start(
            [
                {"/cg", cg, {200, <<"{\"prices\":[[1,2.0],[2,4.0]]}">>}},
                {"/cp", cp, {200,
                    <<"[{\"timestamp\":\"2026-05-05T00:00:00Z\","
                        "\"price\":6.0}]">>}},
                {"/binance", binance, {200,
                    <<"{\"symbol\":\"ARUSDT\",\"price\":\"10.0\"}">>}},
                {"/gateio", gateio, {200,
                    <<"[{\"currency_pair\":\"AO_USDT\",\"last\":\"2.0\"}]">>}}
            ]
        ),
    try
        Sources =
            #{
                <<"AR">> => [
                    #{
                        <<"shape">> => <<"coingecko-market-chart">>,
                        <<"url">> => <<MockURL/binary, "/cg?days={{days}}">>
                    },
                    #{
                        <<"shape">> => <<"coinpaprika-historical">>,
                        <<"url">> =>
                            <<MockURL/binary,
                                "/cp?start={{start}}&end={{end}}">>
                    },
                    #{
                        <<"shape">> => <<"binance-ticker-price">>,
                        <<"url">> => <<MockURL/binary, "/binance">>
                    },
                    #{
                        <<"shape">> => <<"gateio-spot-ticker">>,
                        <<"url">> => <<MockURL/binary, "/gateio">>
                    }
                ]
            },
        {ok, Price} =
            price_now(
                #{},
                #{ <<"ticker">> => <<"AR">> },
                #{
                    <<"relay-http-client">> => httpc,
                    <<"oracle-sources">> => Sources,
                    <<"oracle-cache-ttl-ms">> => 0
                }
            ),
        ?assertEqual(5.5, Price),
        ?assertEqual(1, length(hb_mock_server:get_requests(MockHandle, cg))),
        ?assertEqual(1, length(hb_mock_server:get_requests(MockHandle, cp))),
        ?assertEqual(1, length(hb_mock_server:get_requests(MockHandle, binance))),
        ?assertEqual(1, length(hb_mock_server:get_requests(MockHandle, gateio)))
    after
        hb_mock_server:stop(MockHandle)
    end.

%% @doc Bad sources are ignored if at least one source yields a price.
price_now_ignores_bad_source_test() ->
    {ok, MockURL, MockHandle} =
        hb_mock_server:start(
            [
                {"/bad", bad, {200, <<"not-json">>}},
                {"/good", good, {200, <<"{\"prices\":[[1,8.0]]}">>}}
            ]
        ),
    try
        Sources =
            #{
                <<"AR">> => [
                    #{
                        <<"shape">> => <<"coingecko-market-chart">>,
                        <<"url">> => <<MockURL/binary, "/bad">>
                    },
                    #{
                        <<"shape">> => <<"coingecko-market-chart">>,
                        <<"url">> => <<MockURL/binary, "/good">>
                    }
                ]
            },
        {ok, 8.0} =
            price_now(
                #{},
                #{ <<"ticker">> => <<"AR">> },
                #{
                    <<"relay-http-client">> => httpc,
                    <<"oracle-sources">> => Sources,
                    <<"oracle-cache-ttl-ms">> => 0
                }
            )
    after
        hb_mock_server:stop(MockHandle)
    end.

%% @doc Public requests cannot choose oracle fetch targets.
price_now_ignores_request_sources_by_default_test() ->
    {ok, MockURL, MockHandle} =
        hb_mock_server:start(
            [
                {"/configured", configured, {200, <<"{\"prices\":[[1,7.0]]}">>}},
                {"/request", request, {200, <<"{\"prices\":[[1,1.0]]}">>}}
            ]
        ),
    try
        ConfiguredSources =
            #{
                <<"AR">> => [
                    #{
                        <<"shape">> => <<"coingecko-market-chart">>,
                        <<"url">> => <<MockURL/binary, "/configured">>
                    }
                ]
            },
        RequestSources =
            #{
                <<"AR">> => [
                    #{
                        <<"shape">> => <<"coingecko-market-chart">>,
                        <<"url">> => <<MockURL/binary, "/request">>
                    }
                ]
            },
        {ok, 7.0} =
            price_now(
                #{},
                #{
                    <<"ticker">> => <<"AR">>,
                    <<"oracle-sources">> => RequestSources
                },
                #{
                    <<"relay-http-client">> => httpc,
                    <<"oracle-sources">> => ConfiguredSources,
                    <<"oracle-cache-ttl-ms">> => 0
                }
            ),
        ?assertEqual(
            1,
            length(hb_mock_server:get_requests(MockHandle, configured))
        ),
        ?assertEqual(0, length(hb_mock_server:get_requests(MockHandle, request)))
    after
        hb_mock_server:stop(MockHandle)
    end.

-endif.
