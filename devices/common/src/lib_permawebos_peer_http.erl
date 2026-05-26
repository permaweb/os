%%% @doc AO-Core peer HTTP helper for PermawebOS devices.
%%%
%%% Peer handshakes use ordinary HyperBEAM HTTP calls and ask the peer to encode
%%% replies through HTTPSig with bundling enabled. This keeps device-to-device
%%% verification in the signed AO-Core HTTP path without ad hoc JSON parsing or
%%% link expansion.
-module(lib_permawebos_peer_http).
-export([get/3, post/4, peer_opts/2]).


get(BaseURL, Path, Opts) ->
    request(BaseURL, <<"GET">>, Path, #{}, Opts).

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
            throw({lapee_peer_http_error, #{
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }})
    end.

request_message(<<"GET">>, Path, _Body) ->
    #{
        <<"path">> => Path,
        <<"require-codec">> => <<"httpsig@1.0">>,
        <<"accept-bundle">> => true
    };
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

semantic_response(Response) ->
    Response.

peer_opts(_BaseURL, Opts) ->
    PeerClient = hb_opts:get(<<"peer-http-client">>, gun, Opts),
    Base = Opts#{
        http_only_result => false,
        <<"http-only-result">> => false,
        <<"linkify-mode">> => false,
        http_client => PeerClient,
        <<"http-client">> => PeerClient
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

strip_trailing_slash(B) when is_binary(B), byte_size(B) > 0 ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _ -> B
    end;
strip_trailing_slash(B) ->
    B.
