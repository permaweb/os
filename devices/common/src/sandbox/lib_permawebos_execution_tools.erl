%%% @doc Public tool names and accepted request keys for Unix execution devices.
-module(lib_permawebos_execution_tools).
-export([keys/1, name/1, path/1]).

-define(TOOL_SPECS, #{
    <<"read">> =>
        {<<"Read">>, [<<"member-id">>, <<"path">>]},
    <<"write">> =>
        {<<"Write">>, [<<"member-id">>, <<"path">>, <<"content">>]},
    <<"append">> =>
        {<<"Append">>, [<<"member-id">>, <<"path">>, <<"content">>, <<"clear">>]},
    <<"edit">> =>
        {
            <<"Edit">>,
            [
                <<"member-id">>,
                <<"path">>,
                <<"old-string">>,
                <<"new-string">>,
                <<"replace-all">>
            ]
        },
    <<"glob">> =>
        {<<"Glob">>, [<<"member-id">>, <<"pattern">>, <<"cwd">>]},
    <<"grep">> =>
        {<<"Grep">>, [<<"member-id">>, <<"pattern">>, <<"cwd">>]},
    <<"bash">> =>
        {
            <<"Bash">>,
            [
                <<"member-id">>,
                <<"command">>,
                <<"cwd">>,
                <<"yield-ms">>,
                <<"timeout-ms">>,
                <<"execution-id">>
            ]
        },
    <<"bash-session">> =>
        {
            <<"BashSession">>,
            [
                <<"member-id">>,
                <<"session-id">>,
                <<"cursor">>,
                <<"wait-ms">>,
                <<"terminate">>
            ]
        }
}).

keys(Action) ->
    case spec(Action) of
        {_Name, Keys} -> Keys;
        false -> false
    end.

name(Action) ->
    case spec(Action) of
        {Name, _Keys} -> Name;
        false -> false
    end.

path(Action) ->
    canonical_action(Action).

spec(Action) ->
    maps:get(canonical_action(Action), ?TOOL_SPECS, false).

canonical_action(Action) ->
    case lower_bin(Action) of
        <<"bashsession">> -> <<"bash-session">>;
        Lower -> binary:replace(Lower, <<"_">>, <<"-">>, [global])
    end.

lower_bin(Value) when is_binary(Value) ->
    hb_util:bin(string:lowercase(hb_util:list(Value)));
lower_bin(Value) when Value =:= undefined; Value =:= null; is_map(Value) ->
    <<>>;
lower_bin(Value) ->
    lower_bin(hb_util:bin(Value)).
