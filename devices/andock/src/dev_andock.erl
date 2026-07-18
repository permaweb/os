%%% @doc Android isolated-process Linux execution device.
-module(dev_andock).
-implements(<<"andock@1.0">>).
-specification("../docs/device-specs/andock.md").
-device_libraries([
    lib_andock,
    lib_ouroboros_execution,
    lib_ouroboros_execution_tools,
    lib_ouroboros_utils
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
    lib_ouroboros_utils:device_info(
        lib_ouroboros_utils:handler_map(
            ?MODULE,
            [
                read,
                write,
                append,
                edit,
                glob,
                grep,
                bash,
                {<<"read-file">>, read_file},
                {<<"write-file">>, write_file},
                {<<"list-files">>, list_files}
            ]
        ),
        fun proxy/4,
        #{ <<"index">> => fun index/3 }
    ).

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
                    <<"bash">>
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

read_file(_Base, Req, Opts) ->
    lib_ouroboros_execution:handle(
        read_file,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).

write_file(_Base, Req, Opts) ->
    lib_ouroboros_execution:handle(
        write_file,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).

list_files(_Base, Req, Opts) ->
    lib_ouroboros_execution:handle(
        list_files,
        ?DEVICE,
        lib_andock,
        Req,
        Opts
    ).
