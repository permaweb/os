%%% @doc Runtime helpers for the Linux execution adapter.
-module(lib_permawebos_execution_runtime).
-export([
    device_info/3,
    first_defined/1,
    handler_map/2,
    lower_bin/1,
    normalize_boolean/2,
    safe_bin/1,
    safe_int/2
]).

device_info(Handlers, Default, Extra) ->
    maps:merge(
        #{
            <<"status">> => 404,
            <<"content-type">> => <<"text/plain; charset=utf-8">>,
            <<"body">> => <<"Not found">>,
            handlers => Handlers,
            default => Default,
            excludes => [<<"keys">>, <<"set">>, <<"remove">>]
        },
        Extra
    ).

handler_map(Module, Specs) ->
    maps:from_list([handler_entry(Module, Spec) || Spec <- Specs]).

handler_entry(Module, {Key, Function}) ->
    {Key, fun Module:Function/3};
handler_entry(Module, Function) ->
    {hb_util:bin(Function), fun Module:Function/3}.

first_defined([Value | Rest])
        when Value =:= undefined; Value =:= null; Value =:= <<>>;
             Value =:= false; Value =:= "" ->
    first_defined(Rest);
first_defined([Value | _Rest]) ->
    Value;
first_defined([]) ->
    undefined.

lower_bin(Value) when is_binary(Value) ->
    hb_util:bin(string:lowercase(binary_to_list(Value)));
lower_bin(Value) when Value =:= undefined; Value =:= null; is_map(Value) ->
    <<>>;
lower_bin(Value) ->
    lower_bin(hb_util:bin(Value)).

normalize_boolean(true, _Default) -> true;
normalize_boolean(false, _Default) -> false;
normalize_boolean(<<"true">>, _Default) -> true;
normalize_boolean(<<"false">>, _Default) -> false;
normalize_boolean(<<"1">>, _Default) -> true;
normalize_boolean(<<"0">>, _Default) -> false;
normalize_boolean(1, _Default) -> true;
normalize_boolean(0, _Default) -> false;
normalize_boolean(_, Default) -> Default.

safe_bin(Value) when is_binary(Value) ->
    Value;
safe_bin(Value) when is_integer(Value); is_float(Value); is_atom(Value) ->
    hb_util:bin(Value);
safe_bin(Value) when is_map(Value); is_list(Value) ->
    try hb_json:encode(Value)
    catch _:_ -> hb_util:bin(io_lib:format("~p", [Value]))
    end;
safe_bin(Value) ->
    hb_util:bin(io_lib:format("~p", [Value])).

safe_int(Value, Default) ->
    try
        binary_to_integer(hb_util:bin(Value))
    catch
        _:_ -> Default
    end.
