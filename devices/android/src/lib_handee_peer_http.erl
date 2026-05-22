%%% @doc AO-Core peer HTTP helper for HandEE devices.
%%%
%%% Peer handshakes use ordinary HyperBEAM HTTP calls and ask the peer to encode
%%% replies through HTTPSig with bundling enabled. This keeps device-to-device
%%% verification in the signed AO-Core HTTP path without ad hoc JSON parsing or
%%% link expansion.
-module(lib_handee_peer_http).
-export([get/3, get_json/3, post/4, peer_opts/2]).


get(BaseURL, Path, Opts) ->
    request(BaseURL, <<"GET">>, Path, #{}, Opts).

get_json(BaseURL, Path, Opts) ->
    URL = strip_trailing_slash(BaseURL),
    application:ensure_all_started(inets),
    Request = {
        binary_to_list(<<URL/binary, Path/binary>>),
        [{"accept", "application/json"}]
    },
    HTTPOpts = [
        {timeout, http_timeout(Opts)},
        {connect_timeout, http_connect_timeout(Opts)}
    ],
    case httpc:request(get, Request, HTTPOpts, [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, Body}}
                when Status >= 200, Status < 300 ->
            hb_json:decode(Body);
        {ok, {{_, Status, _}, _Headers, Body}} ->
            response_with_status(Status, Body);
        {error, Reason} ->
            throw({handee_peer_http_error, #{
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }})
    end.

post(BaseURL, Path, Body, Opts) ->
    request(BaseURL, <<"POST">>, Path, Body, Opts).

request(BaseURL, Method, Path, Body, Opts) ->
    URL = strip_trailing_slash(BaseURL),
    Msg = request_message(Method, Path, Body),
    PeerOpts = peer_opts(URL, Opts),
    Res =
        case Method of
            <<"GET">> -> hb_http:get(URL, Msg, PeerOpts);
            <<"POST">> -> hb_http:post(URL, Path, Msg, PeerOpts)
        end,
    case Res of
        {ok, Response} ->
            semantic_response(Response);
        {error, Response = #{}} ->
            response_with_status(
                hb_maps:get(<<"status">>, Response, 500, Opts),
                Response);
        {error, Reason} ->
            throw({handee_peer_http_error, #{
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }})
    end.

request_message(<<"GET">>, Path, Body) ->
    hb_maps:merge(
        #{
            <<"path">> => Path,
            <<"require-codec">> => <<"httpsig@1.0">>,
            <<"accept-bundle">> => true
        },
        Body,
        #{});
request_message(<<"POST">>, Path, Body) ->
    hb_maps:merge(
        request_message(<<"GET">>, Path, #{}),
        Body,
        #{}).

response_with_status(Status, Response) when is_map(Response) ->
    case hb_maps:get(<<"status">>, Response, undefined, #{}) of
        S when is_integer(S) -> Response;
        _ -> Response#{<<"status">> => Status}
    end;
response_with_status(Status, Body) ->
    #{<<"status">> => Status, <<"body">> => Body}.

semantic_response(Response = #{<<"type">> := _Type}) ->
    Response;
semantic_response(#{<<"status">> := Status, <<"body">> := Body})
        when is_integer(Status), Status >= 200, Status < 300 ->
    Body;
semantic_response(Response) ->
    Response.

peer_opts(BaseURL, Opts) ->
    URL = strip_trailing_slash(BaseURL),
    Base = (with_peer_store(URL, Opts))#{
        http_only_result => false,
        <<"http-only-result">> => false,
        <<"linkify-mode">> => false,
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

http_timeout(Opts) ->
    timeout_value(<<"peer-http-timeout-ms">>, 30000, Opts).

http_connect_timeout(Opts) ->
    timeout_value(<<"peer-http-connect-timeout-ms">>, 5000, Opts).

timeout_value(Key, Default, Opts) ->
    case hb_opts:get(Key, undefined, Opts#{<<"prefer">> => local}) of
        N when is_integer(N), N > 0 -> N;
        B when is_binary(B) ->
            try binary_to_integer(B) of
                N when N > 0 -> N;
                _ -> Default
            catch _:_ -> Default
            end;
        _ -> Default
    end.

with_peer_store(URL, Opts) ->
    Stores = store_list(hb_opts:get(<<"store">>, [], Opts)),
    PeerStore = #{
        <<"store-module">> => hb_store_remote_node,
        <<"node">> => URL,
        <<"only-ids">> => true
    },
    Opts#{<<"store">> => Stores ++ [PeerStore]}.

store_list(undefined) -> [];
store_list(Store) when is_list(Store) -> Store;
store_list(Store) -> [Store].

strip_trailing_slash(B) when is_binary(B), byte_size(B) > 0 ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _ -> B
    end;
strip_trailing_slash(B) ->
    B.
