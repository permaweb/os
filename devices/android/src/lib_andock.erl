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

tool_keys(Action) ->
    lib_permawebos_execution:tool_keys(Action).

list_files(MemberId, Path, Opts) ->
    lib_permawebos_execution:list_files(MemberId, Path, force_backend(Opts)).

serve_file(MemberId, Path, Opts) ->
    lib_permawebos_execution:serve_file(MemberId, Path, force_backend(Opts)).

container_read(MemberId, Path, _Opts) ->
    case request(
        #{
            <<"action">> => <<"read">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path
        },
        ?DEFAULT_TIMEOUT_MS
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

container_write(MemberId, Path, Content, _Opts) ->
    case request(
        #{
            <<"action">> => <<"write">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path,
            <<"content">> => hb_util:encode(Content)
        },
        ?DEFAULT_TIMEOUT_MS
    ) of
        {ok, _} -> ok;
        {error, Status, Reason, Details} ->
            {error, Status, Reason, Details};
        {error, _Status, Reason} -> {error, Reason}
    end.

container_list_dir(MemberId, Path, _Opts) ->
    case request(
        #{
            <<"action">> => <<"list">>,
            <<"member-id">> => MemberId,
            <<"path">> => Path
        },
        ?DEFAULT_TIMEOUT_MS
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

exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, _Opts) ->
    case request(
        #{
            <<"action">> => <<"exec">>,
            <<"member-id">> => MemberId,
            <<"cwd">> => Cwd,
            <<"command">> => Command,
            <<"timeout-ms">> => TimeoutMs,
            <<"allow-network">> => not DisableNetwork
        },
        TimeoutMs + 5000
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
    _Opts
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
        WaitMs + 15000
    ) of
        {ok, Body} -> decode_session_result(Body);
        Error -> Error
    end.

poll_session(MemberId, SessionId, Cursor, WaitMs, Terminate, _Opts) ->
    case request(
        #{
            <<"action">> => <<"session-poll">>,
            <<"member-id">> => MemberId,
            <<"session-id">> => SessionId,
            <<"cursor">> => Cursor,
            <<"wait-ms">> => WaitMs,
            <<"terminate">> => Terminate
        },
        WaitMs + 15000
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

stop(MemberId, _Opts) ->
    request(
        #{ <<"action">> => <<"stop">>, <<"member-id">> => MemberId },
        10000
    ).

destroy(MemberId, _Opts) ->
    request(
        #{ <<"action">> => <<"destroy">>, <<"member-id">> => MemberId },
        10000
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

request(Message, Timeout) ->
    case os:getenv(?EXECUTION_SOCKET_ENV) of
        false ->
            {error, 503, <<"Andock execution runtime is unavailable.">>};
        [] ->
            {error, 503, <<"Andock execution runtime is unavailable.">>};
        SocketPath ->
            request_socket(SocketPath, Message#{ <<"protocol">> => ?PROTOCOL }, Timeout)
    end.

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
