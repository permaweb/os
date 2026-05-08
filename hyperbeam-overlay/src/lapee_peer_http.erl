%%% @doc Thin peer HTTP helper for LapEE devices.
%%%
%%% Peer handshakes should use HyperBEAM's normal HTTP machinery so AO-Core
%%% messages, commitments, codecs, and response verification keep their native
%%% shape. This module only standardizes the opts LapEE needs for peer calls:
%%% keep full response messages (`http-only-result=false') and map the
%%% peer-specific timeout knobs onto `hb_http_client'.
-module(lapee_peer_http).
-export([get/3, post/4]).

get(BaseURL, Path, Opts) ->
    result(hb_http:get(strip_trailing_slash(BaseURL), #{<<"path">> => Path},
                       peer_opts(Opts))).

post(BaseURL, Path, Body, Opts) ->
    result(hb_http:post(strip_trailing_slash(BaseURL), Path, Body,
                        peer_opts(Opts))).

result({ok, Msg}) ->
    Msg;
result({error, Msg}) when is_map(Msg) ->
    Msg;
result({failure, Msg}) when is_map(Msg) ->
    Msg;
result({Status, Reason}) ->
    throw({lapee_peer_http_error, #{
        <<"status">> => hb_util:bin(Status),
        <<"reason">> => iolist_to_binary(io_lib:format("~0p", [Reason]))
    }}).

peer_opts(Opts) ->
    Base = Opts#{
        <<"http-only-result">> => false,
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
            http_client_send_timeout,
            Base)).

with_timeout(From, To, Opts) ->
    case hb_opts:get(From, undefined, Opts) of
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
