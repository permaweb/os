%%% @doc Public `docker@1.0' execution device.
-module(dev_docker).
-implements(<<"docker@1.0">>).
-specification("../docs/device-specs/docker.md").
-device_libraries([
    lib_permawebos_bash_session,
    lib_permawebos_docker,
    lib_permawebos_execution,
    lib_permawebos_execution_runtime,
    lib_permawebos_execution_tools
]).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
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

-define(DEVICE, <<"docker@1.0">>).
-define(DOCKER(Action),
    Action(Base, Req, Opts) ->
        with_volume(
            Opts,
            fun() -> lib_permawebos_docker:Action(Base, Req, Opts) end
        )
).

info(_) ->
    lib_permawebos_execution_runtime:device_info(
        lib_permawebos_execution_runtime:handler_map(
            ?MODULE,
            [
                read,
                write,
                append,
                edit,
                glob,
                grep,
                bash,
                {<<"bash-session">>, bash_session},
                {<<"read-file">>, read_file},
                {<<"write-file">>, write_file},
                {<<"list-files">>, list_files}
            ]
        ),
        fun proxy/4,
        #{ <<"index">> => fun index/3 }
    ).

index(_Base, _Req, Opts) ->
    with_volume(Opts, fun() -> index_ephemeral(Opts) end).

index_ephemeral(Opts) ->
    Base =
        #{
            <<"device">> => ?DEVICE,
            <<"isolation">> => <<"docker-container">>,
            <<"volume">> => <<"ephemeral">>,
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
        },
    case lib_permawebos_docker:readiness(Opts) of
        {ok, Details} ->
            {ok,
                maps:merge(
                    Base,
                    Details#{
                        <<"status">> => 200,
                        <<"readiness">> => <<"ready">>
                    }
                )};
        {error, Status, Reason} ->
            {ok,
                Base#{
                    <<"status">> => Status,
                    <<"readiness">> => <<"not-ready">>,
                    <<"error">> => Reason
                }}
    end.

proxy(_Key, _Base, _Req, _Opts) ->
    with_volume(
        _Opts,
        fun() ->
            {ok,
                #{
                    <<"ok">> => false,
                    <<"device">> => ?DEVICE,
                    <<"status">> => 404,
                    <<"error">> => <<"Unknown docker@1.0 action.">>
                }}
        end
    ).

?DOCKER(read).
?DOCKER(write).
?DOCKER(append).
?DOCKER(edit).
?DOCKER(glob).
?DOCKER(grep).
?DOCKER(bash).
?DOCKER(bash_session).

read_file(_Base, Req, Opts) ->
    with_volume(
        Opts,
        fun() ->
            lib_permawebos_docker:handle(read_file, Req, Opts)
        end
    ).

write_file(_Base, Req, Opts) ->
    with_volume(
        Opts,
        fun() ->
            lib_permawebos_docker:handle(write_file, Req, Opts)
        end
    ).

list_files(_Base, Req, Opts) ->
    with_volume(
        Opts,
        fun() ->
            lib_permawebos_docker:handle(list_files, Req, Opts)
        end
    ).

with_volume(Opts, Fun) ->
    case lib_permawebos_docker:volume(Opts) of
        {ok, <<"ephemeral">>} ->
            Fun();
        {error, Volume, Message} ->
            {failure,
                #{
                    <<"status">> => 503,
                    <<"body">> => Message,
                    <<"error">> => Message,
                    <<"device">> => ?DEVICE,
                    <<"volume">> => Volume
                }}
    end.

-ifdef(TEST).

index_fails_closed_without_private_daemon_test() ->
    PreviousHost = os:getenv("DOCKER_HOST"),
    os:unsetenv("DOCKER_HOST"),
    try
        {ok, Index} = index(#{}, #{}, #{}),
        ?assertEqual(<<"not-ready">>, maps:get(<<"readiness">>, Index)),
        ?assertEqual(503, maps:get(<<"status">>, Index))
    after
        case PreviousHost of
            false -> ok;
            Host -> os:putenv("DOCKER_HOST", Host)
        end
    end.

zone_volume_is_an_ao_core_failure_test() ->
    Opts = #{
        <<"permawebos-docker-volume">> => <<"zone">>,
        <<"hashpath">> => ignore,
        <<"forge-bootstrap">> => #{?DEVICE => ?MODULE}
    },
    ?assertMatch(
        {failure,
            #{
                <<"status">> := 503,
                <<"body">> := _,
                <<"error">> := _,
                <<"device">> := ?DEVICE,
                <<"volume">> := <<"zone">>
            }},
        index(#{}, #{}, Opts)
    ),
    ?assertMatch(
        {failure, #{<<"status">> := 503, <<"volume">> := <<"zone">>}},
        read(#{}, #{}, Opts)
    ),
    ?assertMatch(
        {failure, #{<<"status">> := 503, <<"volume">> := <<"zone">>}},
        hb_ao:resolve(
            #{<<"device">> => ?DEVICE},
            #{<<"path">> => <<"index">>},
            Opts
        )
    ).

-endif.
