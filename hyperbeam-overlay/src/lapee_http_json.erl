%%% @doc Minimal HTTP/1.1 JSON client for LapEE peer-to-peer calls.
%%%
%%% HyperBEAM's normal outbound client is the right default for general
%%% requests, but the green-zone TPM handshake has a narrower requirement:
%%% fetch or post AO-Core JSON messages over plain HTTP between LapEE peers.
%%% Keeping that path here avoids hidden dependencies on OS CA bundles or
%%% HyperBEAM's `ao-result' response shortcut.
-module(lapee_http_json).
-export([get/3, post/4]).

-include_lib("eunit/include/eunit.hrl").

get(BaseURL, Path, Opts) ->
    request(get, BaseURL, Path, undefined, Opts).

post(BaseURL, Path, Body, Opts) ->
    request(post, BaseURL, Path, Body, Opts).

request(Method, BaseURL, Path, Body, Opts) ->
    URL = url_parts(BaseURL, Path),
    Socket = connect(URL, Opts),
    ok = gen_tcp:send(Socket, request_bytes(Method, URL, Body)),
    Response = recv_all(Socket, [], recv_timeout(Opts)),
    gen_tcp:close(Socket),
    parse_response(Response).

url_parts(BaseURL, Path) ->
    URL = <<(to_bin(BaseURL))/binary, Path/binary>>,
    Parsed = uri_string:parse(URL),
    case maps:get(scheme, Parsed, <<"http">>) of
        <<"http">> -> ok;
        Other -> throw({lapee_http_json_error,
                        #{<<"unsupported-scheme">> => Other}})
    end,
    Host = maps:get(host, Parsed),
    Port = maps:get(port, Parsed, 80),
    RawPath = maps:get(path, Parsed, <<"/">>),
    Query = maps:get(query, Parsed, <<>>),
    RequestPath =
        case Query of
            <<>> -> RawPath;
            _ -> <<RawPath/binary, "?", Query/binary>>
        end,
    #{host => Host, port => Port, path => RequestPath}.

connect(#{host := Host, port := Port}, Opts) ->
    case gen_tcp:connect(
        binary_to_list(Host),
        Port,
        [binary, {packet, raw}, {active, false}],
        connect_timeout(Opts)
    ) of
        {ok, Socket} -> Socket;
        {error, Reason} ->
            throw({lapee_http_json_error,
                  #{<<"connect">> => hb_util:bin(Reason)}})
    end.

connect_timeout(Opts) ->
    timeout_opt(<<"peer-http-connect-timeout-ms">>, 10000, Opts).

recv_timeout(Opts) ->
    timeout_opt(<<"peer-http-timeout-ms">>, 120000, Opts).

timeout_opt(Key, Default, Opts) ->
    case hb_opts:get(Key, Default, Opts) of
        N when is_integer(N), N > 0 -> N;
        B when is_binary(B) ->
            try binary_to_integer(B) of
                N when N > 0 -> N
            catch _:_ -> Default
            end;
        _ -> Default
    end.

request_bytes(get, URL, _Body) ->
    request_head(<<"GET">>, URL, []);
request_bytes(post, URL, Body) ->
    Encoded = hb_json:encode(Body),
    [
        request_head(
            <<"POST">>,
            URL,
            [
                <<"Content-Type: application/json\r\n">>,
                <<"Content-Length: ">>,
                integer_to_binary(byte_size(Encoded)),
                <<"\r\n">>
            ]
        ),
        Encoded
    ].

request_head(Method, #{host := Host, port := Port, path := Path}, Extra) ->
    HostHeader = <<Host/binary, ":", (integer_to_binary(Port))/binary>>,
    [
        Method, <<" ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: ">>, HostHeader, <<"\r\n">>,
        <<"Accept: application/json\r\n">>,
        <<"Accept-Bundle: true\r\n">>,
        <<"Connection: close\r\n">>,
        Extra,
        <<"\r\n">>
    ].

recv_all(Socket, Acc, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Chunk} -> recv_all(Socket, [Chunk | Acc], Timeout);
        {error, closed} -> iolist_to_binary(lists:reverse(Acc));
        {error, Reason} ->
            throw({lapee_http_json_error,
                   #{<<"recv">> => hb_util:bin(Reason)}})
    end.

parse_response(Response) ->
    case binary:split(Response, <<"\r\n\r\n">>) of
        [Head, Body0] ->
            {Status, Headers} = parse_head(Head),
            Body = maybe_decode_chunked(Headers, Body0),
            Decoded = decode_json_body(Body),
            case Status >= 200 andalso Status < 300 of
                true -> Decoded;
                false -> http_error_response(Status, Decoded)
            end;
        _ ->
            throw({lapee_http_json_error,
                   #{<<"bad-response">> => Response}})
    end.

parse_head(Head) ->
    [StatusLine | HeaderLines] = binary:split(Head, <<"\r\n">>, [global]),
    [_, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    {binary_to_integer(StatusBin), headers(HeaderLines)}.

headers(Lines) ->
    maps:from_list(
        lists:filtermap(
            fun(Line) ->
                case binary:split(Line, <<":">>) of
                    [K, V] ->
                        {true, {
                            string:lowercase(binary_to_list(K)),
                            string:trim(binary_to_list(V))
                        }};
                    _ -> false
                end
            end,
            Lines
        )
    ).

maybe_decode_chunked(Headers, Body) ->
    case maps:get("transfer-encoding", Headers, "") of
        "chunked" -> decode_chunks(Body, []);
        _ -> Body
    end.

decode_chunks(Body, Acc) ->
    [SizeLine, Rest0] = binary:split(Body, <<"\r\n">>),
    [SizeHex | _] = binary:split(SizeLine, <<";">>),
    Size = erlang:list_to_integer(binary_to_list(SizeHex), 16),
    case Size of
        0 -> iolist_to_binary(lists:reverse(Acc));
        _ ->
            <<Chunk:Size/binary, "\r\n", Rest/binary>> = Rest0,
            decode_chunks(Rest, [Chunk | Acc])
    end.

decode_json_body(Body) when is_binary(Body) ->
    try hb_json:decode(Body) of
        Msg when is_map(Msg) -> restore_json_atom_types(Msg);
        _ -> Body
    catch _:_ -> Body
    end;
decode_json_body(Body) ->
    Body.

restore_json_atom_types(Msg) when is_map(Msg) ->
    RestoredNested =
        maps:map(
            fun(_Key, Value) ->
                restore_json_atom_types(Value)
            end,
            Msg
        ),
    lists:foldl(
        fun(Key, Acc) ->
            case maps:get(Key, Acc, undefined) of
                B when is_binary(B) ->
                    Acc#{Key => known_json_atom(B)};
                _ ->
                    Acc
            end
        end,
        RestoredNested,
        atom_type_keys(maps:get(<<"ao-types">>, RestoredNested, <<>>))
    );
restore_json_atom_types(List) when is_list(List) ->
    [restore_json_atom_types(Value) || Value <- List];
restore_json_atom_types(Value) ->
    Value.

atom_type_keys(Types) when is_binary(Types) ->
    lists:filtermap(
        fun(Part0) ->
            Part = string:trim(Part0),
            case binary:split(unicode:characters_to_binary(Part), <<"=">>) of
                [Key0, <<"\"atom\"">>] ->
                    {true, strip_json_type_quotes(Key0)};
                _ ->
                    false
            end
        end,
        string:split(Types, <<",">>, all)
    );
atom_type_keys(_) ->
    [].

strip_json_type_quotes(<<"\"", Rest/binary>>) ->
    case binary:last(Rest) of
        $" -> binary:part(Rest, 0, byte_size(Rest) - 1);
        _ -> Rest
    end;
strip_json_type_quotes(Bin) ->
    Bin.

known_json_atom(<<"true">>) -> true;
known_json_atom(<<"false">>) -> false;
known_json_atom(<<"null">>) -> null;
known_json_atom(<<"undefined">>) -> undefined;
known_json_atom(Bin) ->
    try binary_to_existing_atom(Bin, utf8)
    catch _:_ -> Bin
    end.

http_error_response(_Status, #{<<"status">> := _} = Msg) ->
    Msg;
http_error_response(Status, Body) when is_map(Body) ->
    #{<<"status">> => Status, <<"body">> => Body};
http_error_response(Status, Body) ->
    throw({lapee_http_json_error,
           #{<<"status">> => Status, <<"body">> => Body}}).

to_bin(B) when is_binary(B) ->
    B;
to_bin(L) when is_list(L) ->
    unicode:characters_to_binary(L);
to_bin(Other) ->
    hb_util:bin(Other).

-ifdef(TEST).

decode_chunked_response_test() ->
    Msg = parse_response(
        <<
            "HTTP/1.1 200 OK\r\n",
            "Transfer-Encoding: chunked\r\n\r\n",
            "7\r\n{\"ok\":1\r\n",
            "1\r\n}\r\n",
            "0\r\n\r\n"
        >>
    ),
    ?assertEqual(#{<<"ok">> => 1}, Msg).

structured_http_error_response_test() ->
    Msg = parse_response(
        <<
            "HTTP/1.1 400 Bad Request\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"status\":400,\"body\":{\"error\":\"template-mismatch\"}}"
        >>
    ),
    ?assertEqual(
        #{
            <<"status">> => 400,
            <<"body">> => #{<<"error">> => <<"template-mismatch">>}
        },
        Msg).

typed_json_response_round_trips_atom_test() ->
    Msg = parse_response(
        <<
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"ok\":\"true\",\"ao-types\":\"ok=\\\"atom\\\"\"}"
        >>
    ),
    ?assertMatch(#{<<"ok">> := true}, Msg).

signed_json_response_remains_verifiable_test() ->
    Wallet = ar_wallet:new(),
    Signed = hb_message:commit(
        #{
            <<"type">> => <<"lapee-http-json-test">>,
            <<"ok">> => true,
            <<"store-module">> => hb_store_fs,
            <<"nested">> => #{
                <<"maybe">> => null,
                <<"value">> => <<"kept">>
            }
        },
        #{<<"priv-wallet">> => Wallet}
    ),
    JSON = hb_message:convert(
        Signed,
        #{<<"device">> => <<"json@1.0">>, <<"bundle">> => true},
        #{}
    ),
    Decoded = decode_json_body(JSON),
    ?assert(hb_message:verify(
        Decoded,
        [hb_util:human_id(ar_wallet:to_address(Wallet))],
        #{})).

-endif.
