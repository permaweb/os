%%% @doc Durable, member-scoped background Bash session lifecycle.
%%%
%%% Commands execute inside the configured PermawebOS execution environment.
%%% The public handle is an opaque session ID; process IDs and backend
%%% mechanics remain private to the execution device.
-module(lib_permawebos_bash_session).
-export([start/8, poll/6]).
-ifdef(TEST).
-export([retention_policy/0, timeout_ms/1, wait_ms/1]).
-endif.

-define(DEFAULT_WAIT_MS, 10000).
-define(MAX_WAIT_MS, 30000).
-define(MAX_RESPONSE_BYTES, 200000).
-define(MAX_OUTPUT_BYTES, 2 * 1024 * 1024).
-define(MAX_TERMINAL_SESSIONS, 32).
-define(TERMINAL_RETENTION_SECONDS, 24 * 60 * 60).
-define(ROOT, <<"/root/.permawebos/bash">>).

-ifdef(TEST).
%% @doc Return the bounded retention policy used by terminal sessions.
retention_policy() ->
    #{
        <<"max-terminal-sessions">> => ?MAX_TERMINAL_SESSIONS,
        <<"terminal-retention-seconds">> => ?TERMINAL_RETENTION_SECONDS
    }.
-endif.

%% @doc Start or replay an idempotent Bash command and await its first result.
start(
    MemberId,
    Cwd,
    Command,
    Timeout0,
    Wait0,
    DisableNetwork,
    ExecutionId,
    Opts
) ->
    case timeout_ms(Timeout0) of
        {ok, Timeout} ->
            SessionId = new_id(MemberId, Cwd, Command, ExecutionId),
            Wait = wait_ms(Wait0),
            case backend_callback(start_session, 8, Opts) of
                {ok, Backend} ->
                    Backend:start_session(
                        MemberId,
                        SessionId,
                        Cwd,
                        Command,
                        Timeout,
                        Wait,
                        DisableNetwork,
                        Opts
                    );
                false ->
                    portable_start_session(
                        MemberId,
                        SessionId,
                        Cwd,
                        Command,
                        Timeout,
                        Wait,
                        DisableNetwork,
                        Opts
                    )
            end;
        Error ->
            Error
    end.

%% @doc Bind a command to its deterministic session and format the result.
portable_start_session(
    MemberId,
    SessionId,
    Cwd,
    Command,
    Timeout,
    Wait,
    DisableNetwork,
    Opts
) ->
    case ensure_session(
        MemberId,
        SessionId,
        Cwd,
        Command,
        Timeout,
        DisableNetwork,
        Opts
    ) of
        ok ->
            case session_result(
                MemberId,
                SessionId,
                0,
                Wait,
                false,
                Opts
            ) of
                {ok, Result} ->
                    {ok,
                        compact_map(
                            maps:merge(
                                Result,
                                #{
                                    <<"cwd">> => Cwd,
                                    <<"command">> => Command,
                                    <<"timeout-ms">> => Timeout,
                                    <<"waited-ms">> => Wait
                                }
                            )
                        )};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Read incremental output or terminate a member-owned session.
poll(MemberId, Session0, Cursor0, Wait0, Terminate0, Opts) ->
    case valid_session_id(Session0) of
        {ok, SessionId} ->
            case cursor(Cursor0) of
                {ok, Cursor} ->
                    Wait = wait_ms(Wait0),
                    Terminate = normalize_boolean(
                        Terminate0,
                        false
                    ),
                    Result = case backend_callback(poll_session, 6, Opts) of
                        {ok, Backend} ->
                            Backend:poll_session(
                                MemberId,
                                SessionId,
                                Cursor,
                                Wait,
                                Terminate,
                                Opts
                            );
                        false ->
                            session_result(
                                MemberId,
                                SessionId,
                                Cursor,
                                Wait,
                                Terminate,
                                Opts
                            )
                    end,
                    case Result of
                        {ok, Result} ->
                            {ok, Result#{ <<"waited-ms">> => Wait }};
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Validate an optional positive runtime deadline without imposing one.
timeout_ms(Value) when Value =:= undefined; Value =:= null; Value =:= <<>> ->
    {ok, undefined};
timeout_ms(Value) ->
    case safe_int(Value, invalid) of
        Int when Int > 0 -> {ok, Int};
        _ -> {error, 400, <<"timeout-ms must be a positive integer when provided.">>}
    end.

%% @doc Normalize a bounded foreground or polling wait.
wait_ms(Value) ->
    case safe_int(Value, ?DEFAULT_WAIT_MS) of
        Int when Int >= 0 -> erlang:min(Int, ?MAX_WAIT_MS);
        _ -> ?DEFAULT_WAIT_MS
    end.

%% @doc Validate a non-negative output cursor.
cursor(Value) ->
    case safe_int(Value, -1) of
        Int when Int >= 0 -> {ok, Int};
        _ -> {error, 400, <<"cursor must be a non-negative integer.">>}
    end.

%% @doc Validate an opaque base64url session identifier.
valid_session_id(Value) ->
    case maybe_bin(Value) of
        undefined ->
            {error, 400, <<"session-id is required.">>};
        SessionId ->
            case re:run(
                SessionId,
                <<"^[A-Za-z0-9_-]{20,64}$">>,
                [{capture, none}]
            ) of
                match ->
                    {ok, SessionId};
                nomatch ->
                    {error,
                        400,
                        <<"session-id must be an opaque base64url identifier returned by Bash.">>}
            end
    end.

%% @doc Derive a member-bound session ID from the provider execution identity.
new_id(MemberId, Cwd, Command, ExecutionId0) ->
    ExecutionId =
        case maybe_bin(ExecutionId0) of
            undefined -> crypto:strong_rand_bytes(16);
            Value -> Value
        end,
    hb_util:human_id(
        crypto:hash(
            sha256,
            <<
                MemberId/binary,
                0,
                ExecutionId/binary,
                0,
                (crypto:hash(sha256, <<Cwd/binary, 0, Command/binary>>))/binary
            >>
        )
    ).

%% @doc Create session metadata once or verify an idempotent replay.
ensure_session(
    MemberId,
    SessionId,
    Cwd,
    Command,
    Timeout,
    DisableNetwork,
    Opts
) ->
    Paths = paths(SessionId),
    Request =
        compact_map(
            #{
                <<"command-sha256">> =>
                    hb_util:human_id(crypto:hash(sha256, Command)),
                <<"cwd">> => Cwd,
                <<"timeout-ms">> => Timeout,
                <<"disable-network">> => DisableNetwork
            }
        ),
    case read(MemberId, maps:get(request, Paths), Opts) of
        {ok, ExistingBytes} ->
            case decode_json_map(ExistingBytes) of
                {ok, Request} ->
                    launch(MemberId, Paths, DisableNetwork, Opts);
                {ok, _Other} ->
                    {error, 409, <<"session-id is already bound to a different Bash command.">>};
                error ->
                    {error, 500, <<"Bash session metadata is invalid.">>}
            end;
        {error, enoent} ->
            case write_files(
                MemberId,
                [
                    {maps:get(run, Paths), run_script(Paths, Cwd, Command, Timeout)},
                    {maps:get(sink, Paths), sink_script(Paths)},
                    {maps:get(poll, Paths), poll_script()},
                    {maps:get(request, Paths), hb_json:encode(Request)}
                ],
                Opts
            ) of
                ok -> launch(MemberId, Paths, DisableNetwork, Opts);
                {error, Reason} ->
                    {error, 500, safe_bin(Reason)}
            end;
        {error, Reason} ->
            {error, 500, safe_bin(Reason)}
    end.

%% @doc Write the private scripts and metadata required by a new session.
write_files(_MemberId, [], _Opts) ->
    ok;
write_files(MemberId, [{Path, Content} | Rest], Opts) ->
    case write(MemberId, Path, Content, Opts) of
        ok -> write_files(MemberId, Rest, Opts);
        Error -> Error
    end.

%% @doc Launch one detached process group unless the session already exists.
launch(MemberId, Paths, DisableNetwork, Opts) ->
    Root = maps:get(root, Paths),
    Launcher =
        <<
            "umask 077\n",
            "if [ ! -f ", (quote(maps:get(pid, Paths)))/binary,
            " ] && [ ! -f ", (quote(maps:get(status, Paths)))/binary,
            " ]; then\n",
            "  : > ", (quote(maps:get(output, Paths)))/binary, "\n",
            "  /usr/bin/python3 - ", (quote(maps:get(run, Paths)))/binary,
            " ", (quote(<<Root/binary, "/pid.tmp">>))/binary,
            " ", (quote(maps:get(pid, Paths)))/binary, " <<'PERMAWEBOS_LAUNCH'\n",
            "import os, subprocess, sys\n",
            "run_path, pid_tmp, pid_path = sys.argv[1:4]\n",
            "with open(os.devnull, 'rb') as stdin, open(os.devnull, 'ab') as output:\n",
            "    child = subprocess.Popen(\n",
            "        ['/bin/bash', run_path],\n",
            "        stdin=stdin, stdout=output, stderr=output,\n",
            "        start_new_session=True\n",
            "    )\n",
            "with open(pid_tmp, 'w') as pid_file:\n",
            "    pid_file.write(str(child.pid) + '\\n')\n",
            "os.replace(pid_tmp, pid_path)\n",
            "PERMAWEBOS_LAUNCH\n",
            "fi"
        >>,
    case exec(
        MemberId,
        <<"/">>,
        Launcher,
        10000,
        DisableNetwork,
        Opts#{ background_launch => true }
    ) of
        {ok, _Output, 0} ->
            ok;
        {ok, Output, Code} ->
            {error,
                500,
                with_output(
                    <<"Unable to start Bash session (exit ",
                      (integer_to_binary(Code))/binary, ").">>,
                    Output
                )};
        Error ->
            Error
    end.

%% @doc Inspect one session and merge its immutable request metadata.
session_result(MemberId, SessionId, Cursor, Wait, Terminate, Opts) ->
    Paths = paths(SessionId),
    case read(MemberId, maps:get(request, Paths), Opts) of
        {ok, RequestBytes} ->
            case decode_json_map(RequestBytes) of
                {ok, Request} ->
                    case inspect(
                        MemberId,
                        Paths,
                        Cursor,
                        Wait,
                        Terminate,
                        maps:get(<<"disable-network">>, Request, true),
                        Opts
                    ) of
                        {ok, Result} ->
                            {ok,
                                compact_map(
                                    maps:merge(
                                        Request,
                                        (maps:remove(<<"status">>, Result))#{
                                            <<"session-id">> => SessionId,
                                            <<"execution-status">> =>
                                                maps:get(<<"status">>, Result)
                                        }
                                    )
                                )};
                        Error ->
                            Error
                    end;
                error ->
                    {error, 500, <<"Bash session metadata is invalid.">>}
            end;
        {error, enoent} ->
            {error, 404, <<"Unknown Bash session for this member.">>};
        {error, Reason} ->
            {error, 500, safe_bin(Reason)}
    end.

%% @doc Run the private polling script inside the owning environment.
inspect(MemberId, Paths, Cursor, Wait, Terminate, DisableNetwork, Opts) ->
    Command =
        <<
            "/usr/bin/python3 ", (quote(maps:get(poll, Paths)))/binary,
            " ", (quote(maps:get(root, Paths)))/binary,
            " ", (integer_to_binary(Cursor))/binary,
            " ", (integer_to_binary(Wait))/binary,
            " ", (case Terminate of true -> <<"1">>; false -> <<"0">> end)/binary
        >>,
    case exec(
        MemberId,
        <<"/">>,
        Command,
        Wait + 10000,
        DisableNetwork,
        Opts
    ) of
        {ok, Json, 0} ->
            decode_poll(Json);
        {ok, Output, Code} ->
            {error,
                500,
                with_output(
                    <<"Unable to inspect Bash session (exit ",
                      (integer_to_binary(Code))/binary, ").">>,
                    Output
                )};
        Error ->
            Error
    end.

%% @doc Decode a poll result and preserve ordinary device error semantics.
decode_poll(Json) ->
    case decode_json_map(trim(Json)) of
        {ok, #{ <<"status">> := <<"invalid-cursor">> }} ->
            {error, 400, <<"cursor is beyond the available Bash session output.">>};
        {ok, #{ <<"status">> := <<"lost">> }} ->
            {error, 410, <<"The Bash session no longer has a live process or terminal result.">>};
        {ok, Result0} ->
            try
                Output = base64:decode(maps:get(<<"output-base64">>, Result0, <<>>)),
                {ok,
                    (maps:remove(<<"output-base64">>, Result0))#{
                        <<"output">> => Output
                    }}
            catch
                _:_ ->
                    {error, 500, <<"Bash session returned invalid output encoding.">>}
            end;
        error ->
            {error, 500, <<"Bash session returned invalid status data.">>}
    end.

%% @doc Return all private paths owned by one session.
paths(SessionId) ->
    Root = <<?ROOT/binary, "/", SessionId/binary>>,
    #{
        root => Root,
        request => <<Root/binary, "/request.json">>,
        run => <<Root/binary, "/run.sh">>,
        sink => <<Root/binary, "/sink.py">>,
        poll => <<Root/binary, "/poll.py">>,
        output => <<Root/binary, "/output">>,
        pid => <<Root/binary, "/pid">>,
        status => <<Root/binary, "/status">>
    }.

%% @doc Render the command runner that records exactly one terminal outcome.
run_script(Paths, Cwd, Command, Timeout) ->
    Status = quote(maps:get(status, Paths)),
    StatusTmp = <<Status/binary, ".tmp.$$">>,
    Output = quote(maps:get(output, Paths)),
    InnerCommand = quote(<<"exec 2>&1\n", Command/binary>>),
    <<
        "#!/usr/bin/env bash\n",
        "set +e\n",
        "cd -- ", (quote(Cwd))/binary, " 2>>", Output/binary, "\n",
        "cd_code=$?\n",
        "if [ \"$cd_code\" -ne 0 ]; then\n",
        "  if [ ! -f ", Status/binary, " ]; then\n",
        "    printf 'exited\\t%s\\n' \"$cd_code\" > ", StatusTmp/binary, "\n",
        "    mv ", StatusTmp/binary, " ", Status/binary, "\n",
        "  fi\n",
        "  exit \"$cd_code\"\n",
        "fi\n",
        "set -o pipefail\n",
        (execution_pipeline(Paths, InnerCommand, Timeout))/binary,
        "if [ ! -f ", Status/binary, " ]; then\n",
        "  printf '%s\\t%s\\n' \"$outcome\" \"$code\" > ", StatusTmp/binary, "\n",
        "  mv ", StatusTmp/binary, " ", Status/binary, "\n",
        "fi\n",
        "exit \"$code\"\n"
    >>.

%% @doc Render a command pipeline with an optional explicit runtime deadline.
execution_pipeline(Paths, InnerCommand, undefined) ->
    <<
        "/bin/bash -lc ", InnerCommand/binary, " 2>&1",
        " | /usr/bin/python3 ", (quote(maps:get(sink, Paths)))/binary, "\n",
        "code=${PIPESTATUS[0]}\n",
        "outcome=exited\n"
    >>;
execution_pipeline(Paths, InnerCommand, Timeout) ->
    TimeoutMarker = quote(<<(maps:get(root, Paths))/binary, "/timeout-reached">>),
    <<
        "rm -f -- ", TimeoutMarker/binary, "\n",
        "LC_ALL=C /usr/bin/timeout --verbose --signal=TERM --kill-after=5s ",
        (timeout_seconds(Timeout))/binary, " /bin/bash -lc ", InnerCommand/binary,
        " 2>", TimeoutMarker/binary,
        " | /usr/bin/python3 ", (quote(maps:get(sink, Paths)))/binary, "\n",
        "code=${PIPESTATUS[0]}\n",
        "if [ -s ", TimeoutMarker/binary,
        " ]; then outcome=timed-out; else outcome=exited; fi\n"
    >>.

%% @doc Render the bounded output sink that continues draining discarded data.
sink_script(Paths) ->
    Output = hb_json:encode(maps:get(output, Paths)),
    LimitReached = hb_json:encode(<<(maps:get(root, Paths))/binary, "/output-limit-reached">>),
    <<
        "import os, sys\n",
        "output_path = ", Output/binary, "\n",
        "limit_path = ", LimitReached/binary, "\n",
        "limit = ", (integer_to_binary(?MAX_OUTPUT_BYTES))/binary, "\n",
        "written = os.path.getsize(output_path) if os.path.exists(output_path) else 0\n",
        "with open(output_path, 'ab', buffering=0) as output:\n",
        "    while True:\n",
        "        chunk = os.read(sys.stdin.fileno(), 65536)\n",
        "        if not chunk:\n",
        "            break\n",
        "        remaining = max(0, limit - written)\n",
        "        if remaining:\n",
        "            kept = chunk[:remaining]\n",
        "            output.write(kept)\n",
        "            written += len(kept)\n",
        "        if len(chunk) > remaining:\n",
        "            open(limit_path, 'ab').close()\n"
    >>.

%% @doc Render session inspection, termination, and retention management.
poll_script() ->
    <<
        "import base64, json, os, shutil, signal, sys, time\n",
        "root, cursor_s, wait_s, terminate_s = sys.argv[1:5]\n",
        "cursor, wait_ms = int(cursor_s), int(wait_s)\n",
        "pid_path, status_path = os.path.join(root, 'pid'), os.path.join(root, 'status')\n",
        "output_path = os.path.join(root, 'output')\n",
        "def read_pid(path=pid_path):\n",
        "    try:\n",
        "        return int(open(path).read().strip())\n",
        "    except Exception:\n",
        "        return None\n",
        "def alive(pid):\n",
        "    if pid is None:\n",
        "        return False\n",
        "    try:\n",
        "        os.kill(pid, 0)\n",
        "        return True\n",
        "    except ProcessLookupError:\n",
        "        return False\n",
        "def cleanup_sessions(current_terminal):\n",
        "    parent = os.path.dirname(root)\n",
        "    now, terminal = time.time(), []\n",
        "    try:\n",
        "        entries = list(os.scandir(parent))\n",
        "    except FileNotFoundError:\n",
        "        return\n",
        "    for entry in entries:\n",
        "        if not entry.is_dir(follow_symlinks=False) or entry.path == root:\n",
        "            continue\n",
        "        status = os.path.join(entry.path, 'status')\n",
        "        if os.path.exists(status):\n",
        "            modified = os.path.getmtime(status)\n",
        "            if now - modified > ",
            (integer_to_binary(?TERMINAL_RETENTION_SECONDS))/binary,
            ":\n",
        "                shutil.rmtree(entry.path, ignore_errors=True)\n",
        "            else:\n",
        "                terminal.append((modified, entry.path))\n",
        "            continue\n",
        "        pid = read_pid(os.path.join(entry.path, 'pid'))\n",
        "        if not alive(pid) and now - entry.stat().st_mtime > ",
            (integer_to_binary(?TERMINAL_RETENTION_SECONDS))/binary,
            ":\n",
        "            shutil.rmtree(entry.path, ignore_errors=True)\n",
        "    keep = ", (integer_to_binary(?MAX_TERMINAL_SESSIONS))/binary,
            " - (1 if current_terminal else 0)\n",
        "    for _, path in sorted(terminal, reverse=True)[keep:]:\n",
        "        shutil.rmtree(path, ignore_errors=True)\n",
        "def read_status():\n",
        "    try:\n",
        "        status, code = open(status_path).read().strip().split('\\t', 1)\n",
        "        return status, int(code)\n",
        "    except Exception:\n",
        "        return None\n",
        "pid = read_pid()\n",
        "if terminate_s == '1' and read_status() is None:\n",
        "    tmp = status_path + '.terminate'\n",
        "    with open(tmp, 'w') as status_file:\n",
        "        status_file.write('terminated\\t143\\n')\n",
        "    os.replace(tmp, status_path)\n",
        "    if pid is not None:\n",
        "        try:\n",
        "            os.killpg(pid, signal.SIGTERM)\n",
        "        except ProcessLookupError:\n",
        "            pass\n",
        "        time.sleep(0.25)\n",
        "        if alive(pid):\n",
        "            try:\n",
        "                os.killpg(pid, signal.SIGKILL)\n",
        "            except ProcessLookupError:\n",
        "                pass\n",
        "deadline = time.monotonic() + wait_ms / 1000\n",
        "while read_status() is None and alive(pid) and time.monotonic() < deadline:\n",
        "    time.sleep(min(0.1, max(0, deadline - time.monotonic())))\n",
        "terminal = read_status()\n",
        "if terminal is None and not alive(pid):\n",
        "    time.sleep(0.1)\n",
        "    terminal = read_status()\n",
        "size = os.path.getsize(output_path) if os.path.exists(output_path) else 0\n",
        "if cursor > size:\n",
        "    print(json.dumps({'status': 'invalid-cursor'}))\n",
        "    raise SystemExit\n",
        "with open(output_path, 'rb') if os.path.exists(output_path) ",
            "else open(os.devnull, 'rb') as output:\n",
        "    output.seek(cursor)\n",
        "    data = output.read(", (integer_to_binary(?MAX_RESPONSE_BYTES))/binary, ")\n",
        "next_cursor = cursor + len(data)\n",
        "if terminal is not None:\n",
        "    status, exit_code = terminal\n",
        "elif alive(pid):\n",
        "    status, exit_code = 'running', None\n",
        "else:\n",
        "    status, exit_code = 'lost', None\n",
        "result = {\n",
        "    'status': status,\n",
        "    'cursor': cursor,\n",
        "    'next-cursor': next_cursor,\n",
        "    'truncated': size > next_cursor,\n",
        "    'output-limit-reached': os.path.exists(os.path.join(root, 'output-limit-reached')),\n",
        "    'output-base64': base64.b64encode(data).decode('ascii')\n",
        "}\n",
        "if exit_code is not None:\n",
        "    result['exit-code'] = exit_code\n",
        "cleanup_sessions(terminal is not None)\n",
        "print(json.dumps(result, separators=(',', ':')))\n"
    >>.

%% @doc Convert integer milliseconds to the GNU timeout duration syntax.
timeout_seconds(Timeout) ->
    hb_util:bin(io_lib:format("~.3fs", [Timeout / 1000])).

%% @doc Read one private session file through the configured backend.
read(MemberId, Path, Opts) ->
    Backend = backend(Opts),
    Backend:container_read(MemberId, Path, Opts).

%% @doc Write one private session file through the configured backend.
write(MemberId, Path, Content, Opts) ->
    Backend = backend(Opts),
    Backend:container_write(MemberId, Path, Content, Opts).

%% @doc Execute one internal command through the configured backend.
exec(MemberId, Cwd, Command, Timeout, DisableNetwork, Opts) ->
    Backend = backend(Opts),
    Backend:exec(
        MemberId,
        Cwd,
        Command,
        Timeout,
        DisableNetwork,
        Opts
    ).

%% @doc Return the execution backend selected by the public device wrapper.
backend(Opts) ->
    maps:get(execution_backend, Opts).

backend_callback(Function, Arity, Opts) ->
    Backend = backend(Opts),
    case code:ensure_loaded(Backend) of
        {module, Backend} ->
            case erlang:function_exported(Backend, Function, Arity) of
                true -> {ok, Backend};
                false -> false
            end;
        _ ->
            false
    end.

%% @doc Shell-quote one internal path or command argument.
quote(Value) ->
    Escaped =
        lists:flatmap(
            fun
                ($') -> "'\\''";
                (Char) -> [Char]
            end,
            binary_to_list(hb_util:bin(Value))
        ),
    hb_util:bin(["'", Escaped, "'"]).

%% @doc Attach trimmed backend output to an internal error message.
with_output(Message, Output0) ->
    Output = trim(Output0),
    case Output of
        <<>> -> Message;
        _ -> <<Message/binary, " ", Output/binary>>
    end.

%% @doc Normalize surrounding whitespace on backend output.
trim(Bin) when is_binary(Bin) ->
    hb_util:bin(string:trim(binary_to_list(Bin)));
trim(Value) ->
    trim(hb_util:bin(Value)).


compact_map(Map) when is_map(Map) ->
    maps:filter(
        fun(_Key, Value) ->
            Value =/= undefined andalso Value =/= null andalso Value =/= <<>>
        end,
        Map
    ).

normalize_boolean(true, _Default) -> true;
normalize_boolean(false, _Default) -> false;
normalize_boolean(<<"true">>, _Default) -> true;
normalize_boolean(<<"false">>, _Default) -> false;
normalize_boolean(<<"1">>, _Default) -> true;
normalize_boolean(<<"0">>, _Default) -> false;
normalize_boolean(1, _Default) -> true;
normalize_boolean(0, _Default) -> false;
normalize_boolean(_, Default) -> Default.

maybe_bin(Value)
        when Value =:= not_found; Value =:= undefined; Value =:= null;
             Value =:= <<>> ->
    undefined;
maybe_bin(Value) when is_binary(Value) ->
    Value;
maybe_bin(Value) ->
    hb_util:bin(Value).

decode_json_map(Value) when is_binary(Value), Value =/= <<>> ->
    try hb_json:decode(Value) of
        Decoded when is_map(Decoded) -> {ok, Decoded};
        _ -> error
    catch
        _:_ -> error
    end;
decode_json_map(_Value) ->
    error.

safe_bin(Value) when is_binary(Value) ->
    Value;
safe_bin(Value) when is_integer(Value); is_float(Value); is_atom(Value) ->
    hb_util:bin(Value);
safe_bin(Value) when is_map(Value); is_list(Value) ->
    try hb_json:encode(Value)
    catch
        _:_ -> iolist_to_binary(io_lib:format("~p", [Value]))
    end;
safe_bin(Value) ->
    iolist_to_binary(io_lib:format("~p", [Value])).

safe_int(Value, Default) ->
    try hb_util:int(Value) of
        Int when is_integer(Int) -> Int;
        _ -> Default
    catch
        _:_ -> Default
    end.
