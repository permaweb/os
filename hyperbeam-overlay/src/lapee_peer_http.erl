%%% @doc Thin peer HTTP helper for LapEE devices.
%%%
%%% Peer handshakes use HyperBEAM's raw HTTP client layer to request bundled
%%% AO-Core JSON and then decode it with the normal JSON codec. Staying below
%%% `hb_http' avoids client-side link expansion while preserving message
%%% semantics at the device boundary.
-module(lapee_peer_http).
-export([get/3, post/4]).

-include_lib("eunit/include/eunit.hrl").

get(BaseURL, Path, Opts) ->
    request(BaseURL, <<"GET">>, accept_path(Path), <<>>, Opts).

post(BaseURL, Path, Body, Opts) ->
    {ok, Encoded} = dev_codec_json:to(Body, codec_req(), Opts),
    request(BaseURL, <<"POST">>, accept_path(Path), Encoded, Opts).

request(BaseURL, Method, Path, Body, Opts) ->
    URL = strip_trailing_slash(BaseURL),
    case hb_http_client:request(
        #{
            peer => URL,
            path => Path,
            method => Method,
            headers => request_headers(Method),
            body => Body
        },
        peer_opts(Opts))
    of
        {ok, Status, _Headers, ResponseBody} ->
            decode_response(Status, ResponseBody, Opts);
        {error, Reason} ->
            throw({lapee_peer_http_error, #{
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }})
    end.

request_headers(<<"GET">>) ->
    #{<<"accept">> => <<"application/json">>};
request_headers(_) ->
    #{
        <<"accept">> => <<"application/json">>,
        <<"content-type">> => <<"application/json">>
    }.

decode_response(Status, <<>>, _Opts) ->
    #{<<"status">> => Status, <<"body">> => #{}};
decode_response(Status, Body, _Opts) ->
    try decode_json_body(Body) of
        Msg = #{<<"status">> := _} ->
            Msg;
        Msg ->
            #{<<"status">> => Status, <<"body">> => Msg}
    catch
        Class:Reason ->
            #{<<"status">> => Status, <<"body">> => #{
                <<"error">> => <<"peer-json-decode-failed">>,
                <<"class">> => hb_util:bin(Class),
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }}
    end.

codec_req() ->
    #{<<"bundle">> => true}.

decode_json_body(Body) ->
    restore_ao_scalar_types(json:decode(Body)).

restore_ao_scalar_types(Map) when is_map(Map) ->
    Types = ao_types(Map),
    Restored = maps:from_list(
        [
            {Key, restore_ao_value(Key, Value, Types)}
         || {Key, Value} <- maps:to_list(Map)
        ]),
    case maps:get(<<".">>, Types, undefined) of
        <<"list">> -> restore_ao_list(Restored);
        _ -> Restored
    end;
restore_ao_scalar_types(List) when is_list(List) ->
    [restore_ao_scalar_types(Value) || Value <- List];
restore_ao_scalar_types(Value) ->
    Value.

restore_ao_value(<<"ao-types">>, Value, _Types) ->
    Value;
restore_ao_value(Key, Value, Types) ->
    restore_ao_typed_value(
        maps:get(Key, Types, undefined),
        restore_ao_scalar_types(Value)).

restore_ao_typed_value(<<"atom">>, Value) when is_binary(Value) ->
    try hb_util:atom(Value)
    catch _:_ -> Value
    end;
restore_ao_typed_value(<<"integer">>, Value) when is_binary(Value) ->
    try binary_to_integer(Value)
    catch _:_ -> Value
    end;
restore_ao_typed_value(_Type, Value) ->
    Value.

restore_ao_list(Map) ->
    [
        Value
     || {_Index, Value} <-
            lists:sort(
                [
                    {Index, Value}
                 || {Key, Value} <- maps:to_list(Map),
                    {ok, Index} <- [numeric_key(Key)]
                ])
    ].

numeric_key(Key) when is_binary(Key) ->
    try {ok, binary_to_integer(Key)}
    catch _:_ -> error
    end;
numeric_key(_) ->
    error.

ao_types(Map) ->
    case maps:get(<<"ao-types">>, Map, undefined) of
        Types when is_binary(Types) ->
            maps:from_list(
                [Type || Part <- binary:split(Types, <<",">>, [global]),
                         Type <- [parse_ao_type(Part)],
                         Type =/= undefined]);
        _ ->
            #{}
    end.

parse_ao_type(Part0) ->
    Part = trim(Part0),
    case binary:split(Part, <<"=">>) of
        [RawKey, RawType0] ->
            RawType = trim(RawType0),
            Type = trim_quotes(RawType),
            {trim(RawKey), Type};
        _ ->
            undefined
    end.

trim(Bin) ->
    iolist_to_binary(string:trim(binary_to_list(Bin))).

trim_quotes(<<"\"", Rest/binary>>) ->
    case Rest of
        <<Inner:(byte_size(Rest) - 1)/binary, "\"">> -> Inner;
        _ -> Rest
    end;
trim_quotes(Bin) ->
    Bin.

peer_opts(Opts) ->
    Base = Opts#{
        http_only_result => false,
        <<"http-only-result">> => false,
        http_client =>
            hb_opts:get(
                <<"peer-http-client">>,
                hb_opts:get(<<"http-client">>, gun, Opts),
                Opts),
        <<"http-client">> =>
            hb_opts:get(
                <<"peer-http-client">>,
                hb_opts:get(<<"http-client">>, gun, Opts),
                Opts)
    },
    with_timeout(
        <<"peer-http-connect-timeout-ms">>,
        http_client_connect_timeout,
        with_timeout(
            <<"peer-http-timeout-ms">>,
            http_client_hackney_recv_timeout,
            with_timeout(
                <<"peer-http-timeout-ms">>,
                http_client_send_timeout,
                Base))).

with_timeout(From, To, Opts) ->
    case hb_opts:get(From, undefined, Opts#{<<"prefer">> => local}) of
        N when is_integer(N), N > 0 -> Opts#{To => N};
        B when is_binary(B) ->
            try binary_to_integer(B) of
                N when N > 0 -> Opts#{To => N};
                _ -> Opts
            catch _:_ -> Opts
            end;
        _ -> Opts
    end.

accept_path(Path) ->
    case binary:match(Path, <<"accept=">>) of
        nomatch ->
            Sep = case binary:match(Path, <<"?">>) of
                nomatch -> <<"?">>;
                _ -> <<"&">>
            end,
            <<Path/binary, Sep/binary,
              "accept=application/json&accept-bundle=true">>;
        _ ->
            Path
    end.

strip_trailing_slash(B) when is_binary(B), byte_size(B) > 0 ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _ -> B
    end;
strip_trailing_slash(B) ->
    B.

decode_response_preserves_committed_bundle_body_test() ->
    Opts = #{<<"priv-wallet">> => ar_wallet:new()},
    Body = hb_message:commit(
        #{
            <<"measurement-device">> => <<"tpm@2.0a">>,
            <<"pcr-selection">> => [0, 1, 7, 10, 11, 14, 15],
            <<"ao-types">> => <<"initialized=\"atom\"">>,
            <<"initialized">> => <<"permanent">>
        },
        Opts),
    Response = hb_message:commit(
        #{<<"status">> => 200, <<"body">> => Body},
        Opts),
    {ok, JSON} = dev_codec_json:to(Response, codec_req(), Opts),
    ?assertMatch(
        #{<<"body">> := #{
            <<"measurement-device">> := <<"tpm@2.0a">>,
            <<"pcr-selection">> := [0, 1, 7, 10, 11, 14, 15],
            <<"initialized">> := permanent
        }},
        decode_response(200, JSON, Opts)).

decode_response_restores_structured_lists_test() ->
    JSON =
        <<"{\"ao-types\":\".=\\\"list\\\", 1=\\\"atom\\\", 2=\\\"integer\\\"\","
          "\"1\":\"ready\",\"2\":\"42\"}">>,
    ?assertEqual([ready, 42], decode_json_body(JSON)).
