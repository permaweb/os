%%% @doc Private transport between `andock@1.0' and the AndEE execution broker.
-module(lib_andock).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-export([read/3, write/3, append/3, edit/3, glob/3, grep/3, bash/3,
         bash_session/3, tool_keys/1]).
-export([list_files/3, serve_file/3]).
-export([container_read/3, container_write/4, container_list_dir/3, exec/6]).
-export([start_session/8, poll_session/6]).
-export([stop/2, destroy/2]).
-export([health/3, prepare/3]).

-define(DEVICE, <<"andock@1.0">>).
-define(EXECUTION_SOCKET_ENV, "ANDEE_EXECUTION_SOCKET").
-define(PROTOCOL, <<"andock-local@1">>).
-define(DEFAULT_TIMEOUT_MS, 30000).
-define(MAX_FRAME_BYTES, 72 * 1024 * 1024).
-define(ACTION(Action),
    Action(_Base, Req, Opts) ->
        lib_permawebos_execution:handle(Action, ?DEVICE, ?MODULE, Req, Opts)
).

?ACTION(read).
?ACTION(write).
?ACTION(append).
?ACTION(edit).
?ACTION(glob).
?ACTION(grep).
?ACTION(bash).
?ACTION(bash_session).

%% @doc Public readiness for the measured toolkit; never exposes private paths.
health(_Base, _Req, Opts) -> toolkit_health(false, Opts).

%% @doc Start the existing image job without creating a member or running a tool.
prepare(_Base, Req, Opts) ->
    case hb_maps:get(<<"method">>, Req, <<"GET">>, Opts) of
        <<"POST">> -> toolkit_health(true, Opts);
        _ -> {ok, #{<<"status">> => 405, <<"allow">> => <<"POST">>}}
    end.

toolkit_health(Prepare, Opts) ->
    ID = hb_opts:get(andock_default_image, undefined, Opts),
    State = case os:getenv(?EXECUTION_SOCKET_ENV) of
        false -> toolkit_state({error, 'execution-runtime-unavailable'});
        [] -> toolkit_state({error, 'execution-runtime-unavailable'});
        Socket ->
            Result = case Prepare of
                true -> lib_andee_materialization:andock(ID, Opts);
                false -> lib_andee_materialization:andock_status(ID, Opts)
            end,
            case Result of
                {ok, Image} -> toolkit_template(Prepare, Socket, Image);
                _ -> (toolkit_state(Result))#{<<"stage">> => <<"downloading">>}
            end
    end,
    {ok, State#{<<"status">> => 200, <<"device">> => ?DEVICE}}.

%% @doc The downloaded sparse image is not ready until Android has expanded and
%% verified its existing template. Neither action allocates a member workspace.
toolkit_template(Prepare, Socket, Image) ->
    Message = case Prepare of
        true -> #{<<"action">> => <<"prepare">>,
            <<"image-id">> => maps:get(<<"id">>, Image),
            <<"image-path">> => maps:get(<<"path">>, Image),
            <<"image-bytes">> => maps:get(<<"bytes">>, Image)};
        false -> #{<<"action">> => <<"health">>}
    end,
    State = case request_socket(Socket, Message#{<<"protocol">> => ?PROTOCOL}, 5000) of
        {ok, #{<<"state">> := _} = Native} -> maps:with([
            <<"state">>, <<"stage">>, <<"error">>,
            <<"required-storage-bytes">>, <<"available-storage-bytes">>
        ], Native);
        {error, _, Error} -> #{<<"state">> => <<"unavailable">>, <<"error">> => Error};
        {error, _, Error, _} -> #{<<"state">> => <<"failed">>, <<"error">> => Error};
        _ -> #{<<"state">> => <<"unavailable">>, <<"error">> => <<"invalid-toolkit-status">>}
    end,
    State#{<<"image-id">> => maps:get(<<"id">>, Image),
        <<"downloaded-bytes">> => maps:get(<<"bytes">>, Image),
        <<"total-bytes">> => maps:get(<<"bytes">>, Image)}.

toolkit_state({error, 'andock-default-image-missing'}) ->
    #{<<"state">> => <<"missing">>};
toolkit_state({error, 'andock-default-image-materializing'}) ->
    #{<<"state">> => <<"preparing">>};
toolkit_state({error, Reason, Details}) ->
    (maps:with([<<"andock-image-elapsed-ms">>, <<"cause">>, <<"retry-after">>,
        <<"downloaded-bytes">>, <<"total-bytes">>, <<"last-progress-ms">>], Details))#{
        <<"state">> => maps:get(<<"andock-image-state">>, Details, <<"failed">>),
        <<"error">> => materialization_error(Reason)
    };
toolkit_state({error, Reason}) ->
    #{<<"state">> => <<"unavailable">>, <<"error">> => materialization_error(Reason)}.

tool_keys(Action) ->
    lib_permawebos_execution:tool_keys(Action).

list_files(MemberId, Path, Opts) ->
    lib_permawebos_execution:list_files(MemberId, Path, force_backend(Opts)).

serve_file(MemberId, Path, Opts) ->
    lib_permawebos_execution:serve_file(MemberId, Path, force_backend(Opts)).

container_read(MemberId, Path, Opts) ->
    case request(
        #{
            <<"action">> => <<"read">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path
        },
        ?DEFAULT_TIMEOUT_MS,
        Opts
    ) of
        {ok, #{ <<"content">> := Encoded }} ->
            decode_content(Encoded);
        {error, 404, _} ->
            {error, enoent};
        {error, 400, <<"path-is-directory">>} ->
            {error, eisdir};
        {error, Status, Reason, Details} ->
            {error, Status, Reason, Details};
        {error, _Status, Reason} ->
            {error, Reason}
    end.

container_write(MemberId, Path, Content, Opts) ->
    case request(
        #{
            <<"action">> => <<"write">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path,
            <<"content">> => hb_util:encode(Content)
        },
        ?DEFAULT_TIMEOUT_MS,
        Opts
    ) of
        {ok, _} -> ok;
        {error, Status, Reason, Details} ->
            {error, Status, Reason, Details};
        {error, _Status, Reason} -> {error, Reason}
    end.

container_list_dir(MemberId, Path, Opts) ->
    case request(
        #{
            <<"action">> => <<"list">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path
        },
        ?DEFAULT_TIMEOUT_MS,
        Opts
    ) of
        {ok, #{ <<"entries">> := Entries }} when is_list(Entries) ->
            {ok, Entries};
        {error, 404, _} ->
            {error, enoent};
        {error, Status, Reason, Details} ->
            {error, Status, Reason, Details};
        {error, _Status, Reason} ->
            {error, Reason};
        {ok, _} ->
            {error, 'invalid-execution-response'}
    end.

exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, Opts) ->
    case request(
        #{
            <<"action">> => <<"exec">>,
            <<"member-id">> => MemberId,
            <<"cwd">> => Cwd,
            <<"command">> => Command,
            <<"timeout-ms">> => TimeoutMs,
            <<"allow-network">> => not DisableNetwork
        },
        TimeoutMs + 5000,
        Opts
    ) of
        {ok, #{ <<"timed-out">> := true }} ->
            {error, 408, <<"Command timed out.">>};
        {ok, #{ <<"output">> := Encoded, <<"exit-code">> := ExitCode }}
                when is_integer(ExitCode) ->
            case decode_content(Encoded) of
                {ok, Output} -> {ok, Output, ExitCode};
                {error, _} -> {error, 500, <<"Invalid execution output.">>}
            end;
        {error, Status, Reason, Details} ->
            {error, Status, Reason, Details};
        {error, Status, Reason} ->
            {error, Status, Reason};
        {ok, _} ->
            {error, 500, <<"Invalid execution response.">>}
    end.

start_session(
    MemberId,
    SessionId,
    Cwd,
    Command,
    TimeoutMs,
    WaitMs,
    DisableNetwork,
    Opts
) ->
    case request(
        #{
            <<"action">> => <<"session-start">>,
            <<"member-id">> => MemberId,
            <<"session-id">> => SessionId,
            <<"cwd">> => Cwd,
            <<"command">> => Command,
            <<"timeout-ms">> => optional_timeout(TimeoutMs),
            <<"wait-ms">> => WaitMs,
            <<"allow-network">> => not DisableNetwork
        },
        WaitMs + 15000,
        Opts
    ) of
        {ok, Body} -> decode_session_result(Body);
        Error -> Error
    end.

poll_session(MemberId, SessionId, Cursor, WaitMs, Terminate, Opts) ->
    case request(
        #{
            <<"action">> => <<"session-poll">>,
            <<"member-id">> => MemberId,
            <<"session-id">> => SessionId,
            <<"cursor">> => Cursor,
            <<"wait-ms">> => WaitMs,
            <<"terminate">> => Terminate
        },
        WaitMs + 15000,
        Opts
    ) of
        {ok, Body} -> decode_session_result(Body);
        Error -> Error
    end.

optional_timeout(undefined) -> null;
optional_timeout(TimeoutMs) -> TimeoutMs.

decode_session_result(#{ <<"output">> := Encoded } = Body) ->
    case decode_content(Encoded) of
        {ok, Output} -> {ok, Body#{ <<"output">> => Output }};
        {error, _} -> {error, 500, <<"Invalid session output.">>}
    end;
decode_session_result(_) ->
    {error, 500, <<"Invalid session response.">>}.

stop(MemberId, Opts) ->
    request(
        #{ <<"action">> => <<"stop">>, <<"member-id">> => MemberId },
        10000,
        Opts
    ).

destroy(MemberId, Opts) ->
    request(
        #{ <<"action">> => <<"destroy">>, <<"member-id">> => MemberId },
        10000,
        Opts
    ).

force_backend(Opts) ->
    Opts#{
        <<"execution-device">> => ?DEVICE,
        execution_backend => ?MODULE
    }.

decode_content(Encoded) when is_binary(Encoded) ->
    try
        {ok, hb_util:decode(Encoded)}
    catch
        _:_ -> {error, 'invalid-execution-content'}
    end;
decode_content(_) ->
    {error, 'invalid-execution-content'}.

request(Message, Timeout, Opts) ->
    case os:getenv(?EXECUTION_SOCKET_ENV) of
        false ->
            {error, 503, <<"Andock execution runtime is unavailable.">>};
        [] ->
            {error, 503, <<"Andock execution runtime is unavailable.">>};
        SocketPath ->
            case materialize_image(Message, Opts) of
                {ok, Prepared} ->
                    request_socket(
                        SocketPath,
                        Prepared#{ <<"protocol">> => ?PROTOCOL },
                        Timeout
                    );
                {error, Reason, Details} ->
                    {error, 503, materialization_error(Reason), Details};
                {error, Reason} ->
                    {error, 503, materialization_error(Reason)}
            end
    end.

%% @doc Resolve the measured Andock image before invoking Android execution.
materialize_image(#{ <<"action">> := Action } = Message, _Opts)
        when Action =:= <<"session-poll">>; Action =:= <<"stop">>;
             Action =:= <<"destroy">> ->
    {ok, Message};
materialize_image(Message, Opts) ->
    ID = hb_opts:get(andock_default_image, undefined, Opts),
    case lib_andee_materialization:andock(ID, Opts) of
        {ok, Materialized} ->
            {ok, Message#{
                <<"image-id">> => maps:get(<<"id">>, Materialized),
                <<"image-path">> => maps:get(<<"path">>, Materialized),
                <<"image-bytes">> => maps:get(<<"bytes">>, Materialized)
            }};
        Error -> Error
    end.

%% @doc Format internal materialization reasons as hyphenated errors.
materialization_error(Reason) when is_atom(Reason) ->
    binary:replace(atom_to_binary(Reason), <<"_">>, <<"-">>, [global]);
materialization_error(Reason) when is_binary(Reason) -> Reason;
materialization_error(_) -> <<"andock-image-materialization-failed">>.

request_socket(SocketPath, Message, Timeout) ->
    try
        {ok, Socket} = gen_tcp:connect(
            {local, SocketPath},
            0,
            [
                binary,
                {active, false},
                {packet, 4},
                {packet_size, ?MAX_FRAME_BYTES}
            ],
            Timeout
        ),
        try
            ok = gen_tcp:send(Socket, iolist_to_binary(hb_json:encode(Message))),
            receive_response(Socket, Timeout)
        after
            gen_tcp:close(Socket)
        end
    catch
        _Class:_Failure ->
            {error, 503, <<"Andock execution runtime is unavailable.">>}
    end.

receive_response(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Bin} ->
            try
                response(hb_json:decode(Bin))
            catch
                _:_ -> {error, 500, <<"Invalid Andock execution response.">>}
            end;
        {error, timeout} ->
            {error, 408, <<"Command timed out.">>};
        {error, _Reason} ->
            {error, 503, <<"Andock execution runtime is unavailable.">>}
    end.

response(#{ <<"ok">> := true, <<"body">> := Body }) ->
    {ok, Body};
response(#{ <<"status">> := Status, <<"error">> := Error } = Response)
        when is_integer(Status), is_binary(Error) ->
    Details = maps:without([<<"ok">>, <<"status">>, <<"error">>], Response),
    case map_size(Details) of
        0 -> {error, Status, Error};
        _ -> {error, Status, Error, Details}
    end;
response(_) ->
    {error, 500, <<"Invalid Andock execution response.">>}.

-ifdef(TEST).

toolkit_health_is_read_only_test() ->
    Root = filename:join("/tmp", "andock-health-" ++ integer_to_list(erlang:unique_integer([positive]))),
    PreviousRoot = os:getenv("ANDEE_ANDOCK_IMAGE_ROOT"),
    PreviousSocket = os:getenv(?EXECUTION_SOCKET_ENV),
    ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    Opts = #{<<"andock-default-image">> => ID},
    try
        true = os:putenv("ANDEE_ANDOCK_IMAGE_ROOT", Root),
        true = os:putenv(?EXECUTION_SOCKET_ENV, "/tmp/readiness-test-socket"),
        ?assertMatch({ok, #{<<"state">> := <<"missing">>}}, health(#{}, #{}, Opts)),
        ?assertEqual(undefined, whereis(andee_andock_materializer)),
        ?assertMatch({ok, #{<<"status">> := 405}}, prepare(#{}, #{}, Opts)),
        ?assertEqual(undefined, whereis(andee_andock_materializer)),
        ok = filelib:ensure_dir(filename:join(Root, "image")),
        ok = file:write_file(filename:join(Root, binary_to_list(ID) ++ ".simg"), <<"verified-fixture">>),
        {ok, Ready} = health(#{}, #{}, Opts),
        %% A sparse file alone must never claim the native toolkit is ready.
        ?assertEqual(<<"unavailable">>, maps:get(<<"state">>, Ready)),
        ?assertEqual(false, maps:is_key(<<"path">>, Ready)),
        os:unsetenv(?EXECUTION_SOCKET_ENV),
        ?assertMatch({ok, #{<<"state">> := <<"unavailable">>}}, health(#{}, #{}, Opts))
    after
        case PreviousRoot of false -> os:unsetenv("ANDEE_ANDOCK_IMAGE_ROOT"); _ -> os:putenv("ANDEE_ANDOCK_IMAGE_ROOT", PreviousRoot) end,
        case PreviousSocket of false -> os:unsetenv(?EXECUTION_SOCKET_ENV); _ -> os:putenv(?EXECUTION_SOCKET_ENV, PreviousSocket) end,
        file:del_dir_r(Root)
    end.

toolkit_reports_real_download_state_test() ->
    Progress = #{<<"andock-image-state">> => <<"preparing">>,
        <<"downloaded-bytes">> => 256, <<"total-bytes">> => 1024, <<"last-progress-ms">> => 12},
    ?assertMatch(#{<<"state">> := <<"preparing">>, <<"downloaded-bytes">> := 256,
        <<"total-bytes">> := 1024}, toolkit_state({error, 'andock-default-image-materializing', Progress})),
    ?assertMatch(#{<<"state">> := <<"failed">>, <<"retry-after">> := 60},
        toolkit_state({error, 'download-failed', #{<<"andock-image-state">> => <<"failed">>, <<"retry-after">> => 60}})).

toolkit_waits_for_native_installation_without_creating_a_member_test() ->
    Root = filename:join("/tmp", "andock-install-" ++ integer_to_list(erlang:unique_integer([positive]))),
    SocketPath = filename:join(Root, "execution.sock"),
    ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    ImagePath = filename:join(Root, binary_to_list(ID) ++ ".simg"),
    PreviousRoot = os:getenv("ANDEE_ANDOCK_IMAGE_ROOT"),
    PreviousSocket = os:getenv(?EXECUTION_SOCKET_ENV),
    ok = filelib:ensure_dir(ImagePath),
    ok = file:write_file(ImagePath, <<"sparse">>),
    {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {packet, 4},
        {ifaddr, {local, SocketPath}}]),
    Parent = self(),
    Server = spawn_link(fun() ->
        [begin
            {ok, Socket} = gen_tcp:accept(Listener),
            {ok, Encoded} = gen_tcp:recv(Socket, 0, 1000),
            Request = hb_json:decode(Encoded),
            ?assertEqual(Action, maps:get(<<"action">>, Request)),
            ?assertEqual(?PROTOCOL, maps:get(<<"protocol">>, Request)),
            ?assertNot(maps:is_key(<<"member-id">>, Request)),
            ?assertNot(maps:is_key(<<"command">>, Request)),
            case Action of
                <<"health">> -> ?assertNot(maps:is_key(<<"image-path">>, Request));
                <<"prepare">> -> ?assertEqual(ID, maps:get(<<"image-id">>, Request))
            end,
            ok = gen_tcp:send(Socket, iolist_to_binary(hb_json:encode(#{
                <<"ok">> => true, <<"body">> => Native#{
                    <<"stage">> => <<"installing">>, <<"path">> => <<"private">>}
            }))),
            gen_tcp:close(Socket)
        end || {Action, Native} <- [
            {<<"health">>, #{<<"state">> => <<"missing">>}},
            {<<"prepare">>, #{<<"state">> => <<"preparing">>}},
            {<<"health">>, #{<<"state">> => <<"preparing">>}},
            {<<"health">>, #{<<"state">> => <<"failed">>,
                <<"error">> => <<"insufficient-andock-template-storage">>,
                <<"required-storage-bytes">> => 1000, <<"available-storage-bytes">> => 500}},
            {<<"health">>, #{<<"state">> => <<"ready">>}}
        ]],
        Parent ! native_status_complete
    end),
    try
        true = os:putenv("ANDEE_ANDOCK_IMAGE_ROOT", Root),
        true = os:putenv(?EXECUTION_SOCKET_ENV, SocketPath),
        Opts = #{<<"andock-default-image">> => ID},
        ?assertMatch({ok, #{<<"state">> := <<"missing">>, <<"stage">> := <<"installing">>}},
            health(#{}, #{}, Opts)),
        ?assertMatch({ok, #{<<"state">> := <<"preparing">>}},
            prepare(#{}, #{<<"method">> => <<"POST">>}, Opts)),
        ?assertMatch({ok, #{<<"state">> := <<"preparing">>}}, health(#{}, #{}, Opts)),
        ?assertMatch({ok, #{<<"state">> := <<"failed">>,
            <<"required-storage-bytes">> := 1000, <<"available-storage-bytes">> := 500}},
            health(#{}, #{}, Opts)),
        {ok, Ready} = health(#{}, #{}, Opts),
        ?assertEqual(<<"ready">>, maps:get(<<"state">>, Ready)),
        ?assertEqual(6, maps:get(<<"downloaded-bytes">>, Ready)),
        ?assertNot(maps:is_key(<<"path">>, Ready)),
        ?assertEqual(undefined, whereis(andee_andock_materializer)),
        receive native_status_complete -> ok after 1000 -> error(native_status_incomplete) end
    after
        unlink(Server), exit(Server, kill), gen_tcp:close(Listener),
        case PreviousRoot of false -> os:unsetenv("ANDEE_ANDOCK_IMAGE_ROOT"); _ -> os:putenv("ANDEE_ANDOCK_IMAGE_ROOT", PreviousRoot) end,
        case PreviousSocket of false -> os:unsetenv(?EXECUTION_SOCKET_ENV); _ -> os:putenv(?EXECUTION_SOCKET_ENV, PreviousSocket) end,
        file:del_dir_r(Root)
    end.

local_transport_round_trip_test() ->
    Path = filename:join(
        "/tmp",
        "andock-transport-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    file:delete(Path),
    {ok, Listener} = gen_tcp:listen(
        0,
        [
            binary,
            {active, false},
            {packet, 4},
            {packet_size, ?MAX_FRAME_BYTES},
            {ifaddr, {local, Path}}
        ]
    ),
    Parent = self(),
    Server = spawn(fun() ->
        {ok, Socket} = gen_tcp:accept(Listener),
        {ok, EncodedRequest} = gen_tcp:recv(Socket, 0, 1000),
        Parent ! {andock_request, hb_json:decode(EncodedRequest)},
        ok = gen_tcp:send(
            Socket,
            iolist_to_binary(
                hb_json:encode(
                    #{
                        <<"ok">> => true,
                        <<"body">> => #{ <<"content">> => hb_util:encode(<<"hello">>) }
                    }
                )
            )
        ),
        gen_tcp:close(Socket)
    end),
    try
        ?assertEqual(
            {ok, #{ <<"content">> => hb_util:encode(<<"hello">>) }},
            request_socket(
                Path,
                #{ <<"protocol">> => ?PROTOCOL, <<"action">> => <<"read">> },
                1000
            )
        ),
        receive
            {andock_request, Request} ->
                ?assertEqual(?PROTOCOL, maps:get(<<"protocol">>, Request)),
                ?assertEqual(<<"read">>, maps:get(<<"action">>, Request))
        after 1000 ->
            ?assert(false)
        end
    after
        catch exit(Server, kill),
        gen_tcp:close(Listener),
        file:delete(Path)
    end.

response_validation_test() ->
    ?assertEqual(
        {error, 409, <<"member-busy">>},
        response(#{ <<"status">> => 409, <<"error">> => <<"member-busy">> })
    ),
    ?assertEqual(
        {error,
            409,
            <<"member-session-active">>,
            #{
                <<"execution-status">> => <<"running">>,
                <<"session-id">> => <<"session-1">>
            }},
        response(
            #{
                <<"ok">> => false,
                <<"status">> => 409,
                <<"error">> => <<"member-session-active">>,
                <<"execution-status">> => <<"running">>,
                <<"session-id">> => <<"session-1">>
            }
        )
    ),
    ?assertEqual(
        {error, 500, <<"Invalid Andock execution response.">>},
        response(#{ <<"ok">> => true })
    ).

content_encoding_test() ->
    Content = <<0, 255, "utf8:", 16#E2, 16#9C, 16#93>>,
    ?assertEqual({ok, Content}, decode_content(hb_util:encode(Content))),
    ?assertEqual(
        {error, 'invalid-execution-content'},
        decode_content(<<"not base64url!">>)
    ).

-endif.
