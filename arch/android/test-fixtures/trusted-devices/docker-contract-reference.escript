#!/usr/bin/env escript
%%! +A 4
-mode(compile).

%%% Emit reference results for the generic execution contract from docker@1.0.
%%%
%%% This is an acceptance-test fixture. It executes against a separately supplied
%%% application checkout and is outside every LapEE/AndEE build and staging path.

main([Output]) ->
    application:ensure_all_started(crypto),
    Member = <<"andock-parity-", (hb_util:encode(crypto:strong_rand_bytes(9)))/binary>>,
    Opts =
        #{
            <<"ouroboros-execution-device">> => <<"docker@1.0">>,
            <<"ouroboros-docker-image">> => <<"ouroboros-base">>
        },
    try
        Evidence = run(Member, Opts),
        ok = file:write_file(Output, hb_json:encode(Evidence)),
        io:format("DOCKER_CONTRACT_REFERENCE_OK ~s~n", [Output])
    after
        Container = <<"ouroboros-member-", Member/binary>>,
        os:cmd("docker rm -f " ++ binary_to_list(Container) ++ " >/dev/null 2>&1")
    end;
main(_) ->
    io:format(standard_error, "Usage: docker-contract-reference.escript OUTPUT.json~n", []),
    halt(2).

run(Member, Opts) ->
    Write = action(write, Member,
        #{ <<"path">> => <<"parity/a.txt">>, <<"content">> => <<"alpha">> }, all_tools(), Opts),
    Append = action(append, Member,
        #{ <<"path">> => <<"parity/a.txt">>, <<"content">> => <<"beta">> }, all_tools(), Opts),
    Edit = action(edit, Member,
        #{ <<"path">> => <<"parity/a.txt">>, <<"old-string">> => <<"beta">>,
            <<"new-string">> => <<"gamma">> }, all_tools(), Opts),
    Read = action(read, Member, #{ <<"path">> => <<"parity/a.txt">> }, all_tools(), Opts),
    Glob = action(glob, Member,
        #{ <<"pattern">> => <<"missing-*.txt">>, <<"cwd">> => <<"/root/parity">> }, all_tools(), Opts),
    Grep = action(grep, Member,
        #{ <<"pattern">> => <<"definitely-not-present">>,
            <<"cwd">> => <<"/root/parity">> }, all_tools(), Opts),
    Bash = action(bash, Member,
        #{ <<"command">> => <<"printf contract-ok">>, <<"cwd">> => <<"/root">>,
            <<"yield-ms">> => 5000, <<"execution-id">> => <<"parity-bash">> }, all_tools(), Opts),
    Missing = action(read, Member,
        #{ <<"path">> => <<"parity/missing.txt">> }, all_tools(), Opts),
    Unauthorized = action(bash, Member,
        #{ <<"command">> => <<"printf denied">> }, [<<"Read">>], Opts),
    List = list_files(Member, Opts),
    Session = session(Member, Opts),
    Terminated = terminated_session(Member, Opts),
    Timeout = action(bash, Member,
        #{ <<"command">> => <<"sleep 2">>, <<"yield-ms">> => 5000,
            <<"timeout-ms">> => 100, <<"execution-id">> => <<"parity-timeout">> }, all_tools(), Opts),
    #{
        <<"backend">> => <<"docker@1.0">>,
        <<"member-id">> => Member,
        <<"write">> => Write,
        <<"append">> => Append,
        <<"edit">> => Edit,
        <<"read">> => Read,
        <<"glob">> => Glob,
        <<"grep">> => Grep,
        <<"bash">> => Bash,
        <<"missing">> => Missing,
        <<"unauthorized">> => Unauthorized,
        <<"list-files">> => List,
        <<"session">> => Session,
        <<"terminated-session">> => Terminated,
        <<"timeout">> => Timeout
    }.

action(Action, Member, Body, Tools, Opts) ->
    {ok, Response} = apply(
        lib_ouroboros_docker,
        Action,
        [#{}, request(Member, Body, Tools), Opts]
    ),
    Response.

list_files(Member, Opts) ->
    {ok, Response} = lib_ouroboros_docker:list_files(Member, <<"/root/parity">>, Opts),
    Response.

session(Member, Opts) ->
    Started = action(bash, Member,
        #{ <<"command">> => <<"printf one; sleep 1; printf two">>,
            <<"yield-ms">> => 50, <<"execution-id">> => <<"parity-session">> }, all_tools(), Opts),
    collect_session(Member, Started, maps:get(<<"output">>, Started, <<>>), [], Opts).

collect_session(_Member, Current, Output, Polls, _Opts)
        when map_get(<<"execution-status">>, Current) =/= <<"running">> ->
    #{ <<"output">> => Output, <<"terminal">> => Current, <<"polls">> => length(Polls) };
collect_session(Member, Current, Output, Polls, Opts) ->
    Next = action(bash_session, Member,
        #{ <<"session-id">> => maps:get(<<"session-id">>, Current),
            <<"cursor">> => maps:get(<<"next-cursor">>, Current, 0),
            <<"wait-ms">> => 200 }, all_tools(), Opts),
    collect_session(
        Member,
        Next,
        <<Output/binary, (maps:get(<<"output">>, Next, <<>>))/binary>>,
        [Next | Polls],
        Opts
    ).

terminated_session(Member, Opts) ->
    Started = action(bash, Member,
        #{ <<"command">> => <<"sleep 30">>, <<"yield-ms">> => 50,
            <<"execution-id">> => <<"parity-terminate">> }, all_tools(), Opts),
    action(bash_session, Member,
        #{ <<"session-id">> => maps:get(<<"session-id">>, Started),
            <<"cursor">> => maps:get(<<"next-cursor">>, Started, 0),
            <<"wait-ms">> => 5000, <<"terminate">> => true }, all_tools(), Opts).

request(Member, Body, Tools) ->
    #{
        <<"method">> => <<"POST">>,
        <<"body">> => Body#{ <<"member-id">> => Member },
        <<"member-context">> =>
            #{
                <<"id">> => Member,
                <<"tools">> => Tools,
                <<"metadata">> => #{ <<"allow-network">> => false }
            }
    }.

all_tools() ->
    [<<"Read">>, <<"Write">>, <<"Append">>, <<"Edit">>, <<"Glob">>, <<"Grep">>, <<"Bash">>].
