%%% @doc Android isolated-process Linux execution device.
-module(dev_andock).
-implements(<<"andock@1.0">>).
-specification("../docs/device-specs/andock.md").
-device_libraries([
    lib_andock,
    lib_permawebos_bash_session,
    lib_permawebos_execution,
    lib_permawebos_execution_tools
]).
-export([
    info/1,
    index/3,
    proxy/4,
    read/3,
    write/3,
    append/3,
    edit/3,
    glob/3,
    grep/3,
    bash/3,
    bash_session/3,
    read_file/3,
    write_file/3,
    list_files/3
]).

-define(DEVICE, <<"andock@1.0">>).
-define(ANDOCK(Action),
    Action(Base, Req, Opts) ->
        lib_andock:Action(Base, Req, Opts)
).

info(_) ->
    #{
        <<"status">> => 404,
        <<"content-type">> => <<"text/plain; charset=utf-8">>,
        <<"body">> => <<"Not found">>,
        handlers => #{
            <<"read">> => fun ?MODULE:read/3,
            <<"write">> => fun ?MODULE:write/3,
            <<"append">> => fun ?MODULE:append/3,
            <<"edit">> => fun ?MODULE:edit/3,
            <<"glob">> => fun ?MODULE:glob/3,
            <<"grep">> => fun ?MODULE:grep/3,
            <<"bash">> => fun ?MODULE:bash/3,
            <<"bash-session">> => fun ?MODULE:bash_session/3,
            <<"read-file">> => fun ?MODULE:read_file/3,
            <<"write-file">> => fun ?MODULE:write_file/3,
            <<"list-files">> => fun ?MODULE:list_files/3
        },
        default => fun proxy/4,
        excludes => [<<"keys">>, <<"set">>, <<"remove">>],
        <<"index">> => fun index/3
    }.

index(_Base, _Req, _Opts) ->
    {ok,
        #{
            <<"device">> => ?DEVICE,
            <<"status">> => <<"ready">>,
            <<"isolation">> => <<"android-isolated-uid">>,
            <<"keys">> =>
                [
                    <<"read">>,
                    <<"write">>,
                    <<"append">>,
                    <<"edit">>,
                    <<"glob">>,
                    <<"grep">>,
                    <<"bash">>,
                    <<"bash-session">>
                ]
        }}.

proxy(_Key, _Base, _Req, _Opts) ->
    {ok,
        #{
            <<"ok">> => false,
            <<"device">> => ?DEVICE,
            <<"status">> => 404,
            <<"error">> => <<"Unknown andock@1.0 action.">>
        }}.

?ANDOCK(read).
?ANDOCK(write).
?ANDOCK(append).
?ANDOCK(edit).
?ANDOCK(glob).
?ANDOCK(grep).
?ANDOCK(bash).
?ANDOCK(bash_session).

read_file(_Base, Req, Opts) ->
    lib_permawebos_execution:handle(
        read_file,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).

write_file(_Base, Req, Opts) ->
    lib_permawebos_execution:handle(
        write_file,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).

list_files(_Base, Req, Opts) ->
    lib_permawebos_execution:handle(
        list_files,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).
