-module(lib_permawebos_execution_contract_tests).
-export([container_read/3, container_write/4, container_list_dir/3, exec/6]).
-export([start_session/8, poll_session/6]).
-include_lib("eunit/include/eunit.hrl").

-define(DEVICE, <<"portable-test@1.0">>).
-define(MEMBER, <<"portable-member">>).
-define(OTHER_MEMBER, <<"portable-member-2">>).
-define(TEST_PATH, <<"/root/append.log">>).

read_file_uses_backend_and_read_authorization_test() ->
    {ok, Response} =
        call(
            read_file,
            [<<"Read">>],
            #{ <<"path">> => <<"hello.txt">> }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    ?assertEqual(?DEVICE, maps:get(<<"device">>, Response)),
    ?assertEqual(<<"portable">>, maps:get(<<"content">>, Response)),
    ?assertEqual(8, maps:get(<<"size">>, Response)).

read_file_rejects_missing_read_authorization_test() ->
    {ok, Response} =
        call(
            read_file,
            [<<"Write">>],
            #{ <<"path">> => <<"hello.txt">> }
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(403, maps:get(<<"status">>, Response)).

write_file_uses_backend_and_write_authorization_test() ->
    {ok, Response} =
        call(
            write_file,
            [<<"Write">>],
            #{
                <<"path">> => <<"written.txt">>,
                <<"content">> => <<"written">>
            }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    ?assertEqual(7, maps:get(<<"bytes">>, Response)),
    ?assertEqual([], maps:get(<<"artifacts">>, Response)).

non_post_request_is_rejected_test() ->
    {ok, Response} =
        lib_permawebos_execution:handle(
            read,
            ?DEVICE,
            ?MODULE,
            #{ <<"method">> => <<"GET">> },
            #{}
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(405, maps:get(<<"status">>, Response)),
    ?assertEqual(?DEVICE, maps:get(<<"device">>, Response)).

member_context_identity_must_match_test() ->
    {ok, Response} =
        lib_permawebos_execution:handle(
            read,
            ?DEVICE,
            ?MODULE,
            #{
                <<"method">> => <<"POST">>,
                <<"body">> => #{
                    <<"member-id">> => ?MEMBER,
                    <<"path">> => <<"hello.txt">>
                },
                <<"member-context">> => #{
                    <<"id">> => ?OTHER_MEMBER,
                    <<"tools">> => [<<"Read">>]
                }
            },
            #{}
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(400, maps:get(<<"status">>, Response)).

list_files_returns_backend_neutral_entries_test() ->
    {ok, Response} =
        call(
            list_files,
            [<<"Read">>],
            #{ <<"path">> => <<"/root">> }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    ?assertEqual(
        [
            #{
                <<"name">> => <<"hello.txt">>,
                <<"path">> => <<"/root/hello.txt">>,
                <<"size">> => 8,
                <<"type">> => <<"file">>
            }
        ],
        maps:get(<<"entries">>, Response)
    ).

integration_keys_reject_parent_traversal_test() ->
    {ok, Response} =
        call(
            read_file,
            [<<"Read">>],
            #{ <<"path">> => <<"../secret">> }
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(400, maps:get(<<"status">>, Response)).

local_pip_install_reaches_network_disabled_backend_test() ->
    Command = <<"pip install ./wheel">>,
    {ok, Response} =
        call(
            bash,
            [<<"Bash">>],
            #{
                <<"command">> => Command,
                <<"cwd">> => <<"/root/project">>,
                <<"timeout-ms">> => 1234
            }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    ?assertEqual(<<"executed">>, maps:get(<<"output">>, Response)).

network_and_explicit_timeout_are_forwarded_test() ->
    {ok, Response} =
        call(
            bash,
            ?MEMBER,
            [<<"Bash">>],
            #{ <<"command">> => <<"observe">>, <<"timeout-ms">> => 999999999 },
            #{contract_test_owner => self(), contract_allow_network => true}
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    receive
        {contract_exec, ?MEMBER, <<"/root">>, <<"observe">>, 999999999, false} ->
            ok
    after 1000 ->
        error(contract_exec_not_observed)
    end.

default_timeout_and_network_denial_are_forwarded_test() ->
    {ok, Response} =
        call(
            bash,
            ?MEMBER,
            [<<"Bash">>],
            #{ <<"command">> => <<"observe">> },
            #{contract_test_owner => self()}
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    receive
        {contract_exec, ?MEMBER, <<"/root">>, <<"observe">>, undefined, true} ->
            ok
    after 1000 ->
        error(contract_exec_not_observed)
    end.

backend_error_status_is_preserved_test() ->
    {ok, Response} =
        call(
            bash,
            [<<"Bash">>],
            #{ <<"command">> => <<"backend-error">> }
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(503, maps:get(<<"status">>, Response)),
    ?assertEqual(<<"backend unavailable">>, maps:get(<<"error">>, Response)).

backend_contention_details_are_preserved_test() ->
    {ok, Response} =
        call(
            bash,
            [<<"Bash">>],
            #{ <<"command">> => <<"member-session-active">> }
        ),
    ?assertEqual(false, maps:get(<<"ok">>, Response)),
    ?assertEqual(409, maps:get(<<"status">>, Response)),
    ?assertEqual(<<"member-session-active">>, maps:get(<<"error">>, Response)),
    ?assertEqual(<<"active-session">>, maps:get(<<"session-id">>, Response)),
    ?assertEqual(<<"running">>, maps:get(<<"execution-status">>, Response)),
    ?assertEqual(
        [<<"poll">>, <<"wait">>, <<"terminate">>],
        maps:get(<<"session-control-operations">>, Response)
    ).

command_output_is_clipped_at_contract_limit_test() ->
    {ok, Response} =
        call(
            bash,
            [<<"Bash">>],
            #{ <<"command">> => <<"clipped-output">> }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Response)),
    ?assertEqual(true, maps:get(<<"truncated">>, Response)),
    ?assertEqual(200000, byte_size(maps:get(<<"output">>, Response))).

bash_session_is_authorized_by_bash_capability_test() ->
    Session = <<"01234567890123456789">>,
    {ok, Authorized} =
        call(
            bash_session,
            [<<"Bash">>],
            #{ <<"session-id">> => Session, <<"wait-ms">> => 0 }
        ),
    ?assertEqual(true, maps:get(<<"ok">>, Authorized)),
    {ok, Rejected} =
        call(
            bash_session,
            [<<"Read">>],
            #{ <<"session-id">> => Session, <<"wait-ms">> => 0 }
        ),
    ?assertEqual(403, maps:get(<<"status">>, Rejected)).

same_member_append_operations_are_atomic_test() ->
    with_stateful_backend(
        fun(Table) ->
            Ref = make_ref(),
            ets:insert(Table, {{file, ?MEMBER, ?TEST_PATH}, <<>>}),
            Opts = stateful_backend_opts(Table, Ref, [?MEMBER]),
            First = spawn_append(Ref, first, ?MEMBER, <<"first">>, Opts),
            await_started(Ref, first, First),
            ?assertEqual({ok, First}, await_read_entered(Ref, ?MEMBER, 1000)),
            Second = spawn_append(Ref, second, ?MEMBER, <<"second">>, Opts),
            await_started(Ref, second, Second),
            case await_read_or_lock(Ref, ?MEMBER, Second, 1000) of
                locked ->
                    release_read(Ref, First),
                    await_success(Ref, first),
                    ?assertEqual(
                        {ok, Second},
                        await_read_entered(Ref, ?MEMBER, 1000)
                    ),
                    release_read(Ref, Second),
                    await_success(Ref, second);
                {entered, Second} = Overlap ->
                    release_read(Ref, First),
                    release_read(Ref, Second),
                    await_success(Ref, first),
                    await_success(Ref, second),
                    ?assertEqual(locked, Overlap)
            end,
            ?assertEqual(
                [{{file, ?MEMBER, ?TEST_PATH}, <<"firstsecond">>}],
                ets:lookup(Table, {file, ?MEMBER, ?TEST_PATH})
            )
        end
    ).

different_member_operations_overlap_test() ->
    with_stateful_backend(
        fun(Table) ->
            Ref = make_ref(),
            ets:insert(
                Table,
                [
                    {{file, ?MEMBER, ?TEST_PATH}, <<>>},
                    {{file, ?OTHER_MEMBER, ?TEST_PATH}, <<>>}
                ]
            ),
            Opts =
                stateful_backend_opts(
                    Table,
                    Ref,
                    [?MEMBER, ?OTHER_MEMBER]
                ),
            First = spawn_append(Ref, first, ?MEMBER, <<"first">>, Opts),
            await_started(Ref, first, First),
            ?assertEqual({ok, First}, await_read_entered(Ref, ?MEMBER, 1000)),
            Second =
                spawn_append(
                    Ref,
                    second,
                    ?OTHER_MEMBER,
                    <<"second">>,
                    Opts
                ),
            await_started(Ref, second, Second),
            case await_read_or_lock(Ref, ?OTHER_MEMBER, Second, 1000) of
                {entered, Second} ->
                    release_read(Ref, First),
                    release_read(Ref, Second),
                    await_success(Ref, first),
                    await_success(Ref, second);
                locked = NoOverlap ->
                    release_read(Ref, First),
                    await_success(Ref, first),
                    ?assertEqual(
                        {ok, Second},
                        await_read_entered(Ref, ?OTHER_MEMBER, 1000)
                    ),
                    release_read(Ref, Second),
                    await_success(Ref, second),
                    ?assertMatch({entered, _}, NoOverlap)
            end,
            ?assertEqual(
                [{{file, ?MEMBER, ?TEST_PATH}, <<"first">>}],
                ets:lookup(Table, {file, ?MEMBER, ?TEST_PATH})
            ),
            ?assertEqual(
                [{{file, ?OTHER_MEMBER, ?TEST_PATH}, <<"second">>}],
                ets:lookup(Table, {file, ?OTHER_MEMBER, ?TEST_PATH})
            )
        end
    ).

call(Action, Tools, Body) ->
    call(Action, ?MEMBER, Tools, Body, #{}).

call(Action, Member, Tools, Body, Opts) ->
    lib_permawebos_execution:handle(
        Action,
        ?DEVICE,
        ?MODULE,
        #{
            <<"method">> => <<"POST">>,
            <<"body">> => Body#{ <<"member-id">> => Member },
            <<"member-context">> =>
                #{
                    <<"id">> => Member,
                    <<"tools">> => Tools,
                    <<"metadata">> => #{
                        <<"allow-network">> =>
                            maps:get(contract_allow_network, Opts, false)
                    }
                }
        },
        Opts
    ).

container_read(Member, Path, Opts) ->
    case maps:get(portable_test_table, Opts, undefined) of
        undefined ->
            static_container_read(Member, Path);
        Table ->
            maybe_block_read(Member, Opts),
            case ets:lookup(Table, {file, Member, Path}) of
                [{{file, Member, Path}, Content}] -> {ok, Content};
                [] -> {error, enoent}
            end
    end.

static_container_read(?MEMBER, <<"/root/hello.txt">>) ->
    {ok, <<"portable">>};
static_container_read(_Member, _Path) ->
    {error, enoent}.

container_write(Member, Path, Content, Opts) ->
    case maps:get(portable_test_table, Opts, undefined) of
        undefined ->
            static_container_write(Member, Path, Content);
        Table ->
            true = ets:insert(Table, {{file, Member, Path}, Content}),
            ok
    end.

static_container_write(?MEMBER, <<"/root/written.txt">>, <<"written">>) ->
    ok;
static_container_write(_Member, _Path, _Content) ->
    {error, invalid_write}.

container_list_dir(?MEMBER, <<"/root">>, _Opts) ->
    {ok,
        [
            #{
                <<"name">> => <<"hello.txt">>,
                <<"size">> => 8,
                <<"type">> => <<"file">>
            }
        ]};
container_list_dir(_Member, _Path, _Opts) ->
    {error, enoent}.

exec(
    ?MEMBER,
    <<"/root/project">>,
    <<"pip install ./wheel">>,
    1234,
    true,
    _Opts
) ->
    {ok, <<"executed">>, 0};
exec(Member, Cwd, <<"observe">> = Command, TimeoutMs, DisableNetwork, Opts) ->
    maps:get(contract_test_owner, Opts) !
        {contract_exec, Member, Cwd, Command, TimeoutMs, DisableNetwork},
    {ok, <<"observed">>, 0};
exec(_Member, _Cwd, <<"backend-error">>, _TimeoutMs, _DisableNetwork, _Opts) ->
    {error, 503, <<"backend unavailable">>};
exec(_Member, _Cwd, <<"clipped-output">>, _TimeoutMs, _DisableNetwork, _Opts) ->
    {ok, binary:copy(<<"x">>, 200001), 0};
exec(_Member, _Cwd, _Command, _TimeoutMs, _DisableNetwork, _Opts) ->
    {error, 500, <<"unexpected execution request">>}.

start_session(
    Member,
    SessionId,
    Cwd,
    Command,
    Timeout,
    _Wait,
    DisableNetwork,
    Opts
) ->
    case Command of
        <<"backend-error">> ->
            {error, 503, <<"backend unavailable">>};
        <<"member-session-active">> ->
            {error,
                409,
                <<"member-session-active">>,
                #{
                    <<"session-id">> => <<"active-session">>,
                    <<"execution-status">> => <<"running">>,
                    <<"session-control-action">> => <<"bash-session">>,
                    <<"session-control-operations">> =>
                        [<<"poll">>, <<"wait">>, <<"terminate">>],
                    <<"retry-when">> => <<"session-terminal">>
                }};
        <<"clipped-output">> ->
            {ok, session_result(SessionId, binary:copy(<<"x">>, 200000), true)};
        _ ->
            case maps:get(contract_test_owner, Opts, undefined) of
                undefined -> ok;
                Owner ->
                    Owner !
                        {contract_exec, Member, Cwd, Command, Timeout, DisableNetwork}
            end,
            Output = case Command of
                <<"pip install ./wheel">> -> <<"executed">>;
                _ -> <<"observed">>
            end,
            {ok, session_result(SessionId, Output, false)}
    end.

poll_session(_Member, SessionId, Cursor, _Wait, _Terminate, _Opts) ->
    {ok,
        (session_result(SessionId, <<>>, false))#{
            <<"cursor">> => Cursor,
            <<"next-cursor">> => Cursor
        }}.

session_result(SessionId, Output, Truncated) ->
    #{
        <<"session-id">> => SessionId,
        <<"execution-status">> => <<"exited">>,
        <<"cursor">> => 0,
        <<"next-cursor">> => byte_size(Output),
        <<"output">> => Output,
        <<"truncated">> => Truncated,
        <<"output-limit-reached">> => false,
        <<"exit-code">> => 0
    }.

with_stateful_backend(Fun) ->
    Table = ets:new(?MODULE, [set, public]),
    try
        Fun(Table)
    after
        ets:delete(Table)
    end.

stateful_backend_opts(Table, Ref, BlockedMembers) ->
    #{
        portable_test_table => Table,
        portable_test_owner => self(),
        portable_test_ref => Ref,
        portable_test_block_reads => BlockedMembers
    }.

maybe_block_read(Member, Opts) ->
    case lists:member(
        Member,
        maps:get(portable_test_block_reads, Opts, [])
    ) of
        false ->
            ok;
        true ->
            Owner = maps:get(portable_test_owner, Opts),
            Ref = maps:get(portable_test_ref, Opts),
            Owner ! {portable_read_entered, Ref, Member, self()},
            receive
                {portable_release_read, Ref} -> ok
            after 5000 ->
                error(portable_read_barrier_timeout)
            end
    end.

spawn_append(Ref, Tag, Member, Content, Opts) ->
    Parent = self(),
    spawn(
        fun() ->
            Parent ! {portable_call_started, Ref, Tag, self()},
            Result =
                call(
                    append,
                    Member,
                    [<<"Append">>],
                    #{
                        <<"path">> => ?TEST_PATH,
                        <<"content">> => Content
                    },
                    Opts
                ),
            Parent ! {portable_call_result, Ref, Tag, Result}
        end
    ).

await_started(Ref, Tag, Pid) ->
    receive
        {portable_call_started, Ref, Tag, Pid} -> ok
    after 1000 ->
        error({portable_call_not_started, Tag})
    end.

await_read_entered(Ref, Member, Timeout) ->
    receive
        {portable_read_entered, Ref, Member, Pid} -> {ok, Pid}
    after Timeout ->
        timeout
    end.

await_read_or_lock(Ref, Member, Pid, Attempts) ->
    receive
        {portable_read_entered, Ref, Member, Pid} ->
            {entered, Pid}
    after 0 ->
        case process_info(Pid, current_stacktrace) of
            {current_stacktrace, Stack} ->
                case lists:any(
                    fun
                        ({global, random_sleep, _Arity, _Location}) -> true;
                        (_) -> false
                    end,
                    Stack
                ) of
                    true ->
                        locked;
                    false when Attempts > 0 ->
                        receive after 1 -> ok end,
                        await_read_or_lock(
                            Ref,
                            Member,
                            Pid,
                            Attempts - 1
                        );
                    false ->
                        error({portable_call_neither_entered_nor_locked, Pid})
                end;
            undefined ->
                error({portable_call_exited_before_read, Pid})
        end
    end.

release_read(Ref, Pid) ->
    Pid ! {portable_release_read, Ref}.

await_success(Ref, Tag) ->
    receive
        {portable_call_result, Ref, Tag, {ok, Response}} ->
            ?assertEqual(true, maps:get(<<"ok">>, Response))
    after 2000 ->
        error({portable_call_did_not_finish, Tag})
    end.
