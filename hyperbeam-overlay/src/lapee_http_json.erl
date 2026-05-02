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

get(BaseURL, Path, _Opts) ->
    request(get, BaseURL, Path, undefined).

post(BaseURL, Path, Body, _Opts) ->
    request(post, BaseURL, Path, Body).

request(Method, BaseURL, Path, Body) ->
    URL = url_parts(BaseURL, Path),
    Socket = connect(URL),
    ok = gen_tcp:send(Socket, request_bytes(Method, URL, Body)),
    Response = recv_all(Socket, []),
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

connect(#{host := Host, port := Port}) ->
    case gen_tcp:connect(
        binary_to_list(Host),
        Port,
        [binary, {packet, raw}, {active, false}],
        5000
    ) of
        {ok, Socket} -> Socket;
        {error, Reason} ->
            throw({lapee_http_json_error,
                   #{<<"connect">> => hb_util:bin(Reason)}})
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

recv_all(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 15000) of
        {ok, Chunk} -> recv_all(Socket, [Chunk | Acc]);
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
        Msg when is_map(Msg) -> Msg;
        _ -> Body
    catch _:_ -> Body
    end;
decode_json_body(Body) ->
    Body.

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

-endif.
