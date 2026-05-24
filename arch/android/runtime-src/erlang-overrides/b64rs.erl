%%% @doc Pure Erlang b64rs-compatible codec for the Android runtime.
%%%
%%% Upstream b64rs is a Rust NIF. HandEE's Android runtime keeps the same public
%%% module contract but avoids this native dependency unless/until we ship a
%%% separately audited Android NIF build.
-module(b64rs).

-export([encode/1, decode/1]).

encode(Bin) when is_binary(Bin) ->
    encode_binary(Bin);
encode(IoList) when is_list(IoList) ->
    encode_binary(iolist_to_binary(IoList));
encode(_) ->
    error(badarg).

decode(Bin) when is_binary(Bin) ->
    decode_binary(Bin);
decode(IoList) when is_list(IoList) ->
    decode_binary(iolist_to_binary(IoList));
decode(_) ->
    error(badarg).

encode_binary(Bin) ->
    UrlSafe = binary:replace(
        binary:replace(strip_padding(base64:encode(Bin)), <<"+">>, <<"-">>, [global]),
        <<"/">>,
        <<"_">>,
        [global]
    ),
    UrlSafe.

decode_binary(Bin) ->
    Canonical0 = binary:replace(
        binary:replace(remove_whitespace(Bin), <<"-">>, <<"+">>, [global]),
        <<"_">>,
        <<"/">>,
        [global]
    ),
    Canonical =
        case byte_size(Canonical0) rem 4 of
            0 -> Canonical0;
            1 -> error(badarg);
            2 -> <<Canonical0/binary, "==">>;
            3 -> <<Canonical0/binary, "=">>
        end,
    try base64:decode(Canonical) of
        Decoded -> Decoded
    catch
        _:_ -> error(badarg)
    end.

strip_padding(<<>>) ->
    <<>>;
strip_padding(Bin) ->
    case binary:last(Bin) of
        $= -> strip_padding(binary:part(Bin, 0, byte_size(Bin) - 1));
        _ -> Bin
    end.

remove_whitespace(Bin) ->
    <<
        <<C>>
    ||
        <<C>> <= Bin,
        C =/= $\s,
        C =/= $\t,
        C =/= $\n,
        C =/= $\r
    >>.
