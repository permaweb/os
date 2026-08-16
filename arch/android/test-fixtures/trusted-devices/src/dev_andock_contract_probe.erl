%%% @doc A non-application consumer of the generic execution-device contract.
%%%
%%% This fixture is packaged and loaded only by the Android trusted-device
%%% acceptance test. It is deliberately outside the staged Android source set.
-module(dev_andock_contract_probe).
-implements(<<"andock-contract-probe@1.0">>).
-specification("../docs/andock-contract-probe.md").
-export([info/1, index/3, run/3]).

info(_) ->
    #{
        <<"index">> => fun index/3,
        <<"run">> => fun run/3
    }.

index(_Base, _Req, Opts) ->
    {ok,
        #{
            <<"device">> => <<"andock-contract-probe@1.0">>,
            <<"execution-device">> => execution_device(Opts),
            <<"status">> => <<"ready">>
        }}.

run(_Base, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, Req, Opts),
    Member = hb_maps:get(<<"member-id">>, Body, <<"neutral-runtime-consumer">>, Opts),
    Path = <<"/root/", Member/binary, "/contract-probe.txt">>,
    Context =
        #{
            <<"id">> => Member,
            <<"tools">> => [<<"Read">>, <<"Write">>, <<"Bash">>],
            <<"metadata">> => #{ <<"allow-network">> => false }
        },
    {ok, Write} =
        call(
            <<"write-file">>,
            #{ <<"member-id">> => Member, <<"path">> => Path,
                <<"content">> => <<"neutral-">> },
            Context,
            Opts
        ),
    true = maps:get(<<"ok">>, Write, false),
    {ok, Exec} =
        call(
            <<"bash">>,
            #{ <<"member-id">> => Member, <<"cwd">> => <<"/root">>,
                <<"command">> => <<"printf consumer >> ", Path/binary>>,
                <<"timeout-ms">> => 5000 },
            Context,
            Opts
        ),
    true = maps:get(<<"ok">>, Exec, false),
    {ok, Read} =
        call(
            <<"read-file">>,
            #{ <<"member-id">> => Member, <<"path">> => Path },
            Context,
            Opts
        ),
    {ok,
        #{
            <<"device">> => <<"andock-contract-probe@1.0">>,
            <<"execution-device">> => execution_device(Opts),
            <<"member-id">> => Member,
            <<"content">> => maps:get(<<"content">>, Read, <<>>),
            <<"ok">> => true,
            <<"status">> => 200
        }}.

call(Action, Body, Context, Opts) ->
    hb_ao:resolve(
        #{ <<"device">> => execution_device(Opts) },
        #{
            <<"path">> => Action,
            <<"method">> => <<"POST">>,
            <<"body">> => Body,
            <<"member-context">> => Context
        },
        Opts#{
            <<"hashpath">> => ignore,
            <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
        }
    ).

execution_device(Opts) ->
    hb_util:bin(
        hb_opts:get(
            <<"andock-probe-execution-device">>,
            <<"andock@1.0">>,
            Opts
        )
    ).
