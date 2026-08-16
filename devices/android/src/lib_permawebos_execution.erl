%%% @doc Backend-neutral PermawebOS Unix-tool execution contract.
-module(lib_permawebos_execution).
-export([handle/5, tool_keys/1, list_files/3, serve_file/3]).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.
-define(DEFAULT_DEVICE, <<"execution@1.0">>).
-define(DEFAULT_HOME, <<"/root">>).
-define(DEFAULT_TIMEOUT_MS, 15 * 60 * 1000).
-define(MAX_OUTPUT_BYTES, 200000).

tool_keys(Action) ->
    lib_permawebos_execution_tools:keys(Action).

handle(Action, Device, Backend, Req0, Opts0) ->
    Opts =
        Opts0#{
            <<"execution-device">> => Device,
            execution_backend => Backend
        },
    ReqView = request_payload_view(Req0, Opts),
    Result = case request_method(ReqView) of
        <<"POST">> ->
            Req = maps:remove(<<"body">>, ReqView),
            handle_action(Action, Req, Opts);
        _ ->
            {ok, error_response(Action, undefined, 405, <<Device/binary, " actions require POST.">>)}
    end,
    case Result of
        {ok, Response} when is_map(Response) ->
            {ok, Response#{ <<"device">> => Device }};
        Other ->
            Other
    end.

handle_action(read_file, Req, Opts) ->
    with_authorized_member(
        read,
        <<"read-file">>,
        Req,
        Opts,
        fun(MemberId, _Member) ->
            Path = required_path(Req),
            case execution_read(MemberId, Path, Opts) of
                {ok, Content} ->
                    success_response(
                        <<"read-file">>,
                        MemberId,
                        #{
                            <<"path">> => Path,
                            <<"size">> => byte_size(Content),
                            <<"content">> => Content
                        }
                    );
                {error, Reason} ->
                    container_file_error_response(
                        <<"read-file">>,
                        MemberId,
                        Path,
                        Reason
                    );
                {error, Status, Message, Details} ->
                    backend_error_response(
                        <<"read-file">>,
                        MemberId,
                        Status,
                        Message,
                        Details,
                        #{ <<"path">> => Path }
                    )
            end
        end
    );
handle_action(write_file, Req, Opts) ->
    with_authorized_member(
        write,
        <<"write-file">>,
        Req,
        Opts,
        fun(MemberId, _Member) ->
            Path = required_path(Req),
            Content =
                required_binary(
                    Req,
                    <<"content">>,
                    <<"content is required.">>
                ),
            case execution_write(MemberId, Path, Content, Opts) of
                ok ->
                    success_response(
                        <<"write-file">>,
                        MemberId,
                        #{
                            <<"path">> => Path,
                            <<"bytes">> => byte_size(Content)
                        }
                    );
                {error, Reason} ->
                    path_error_response(
                        <<"write-file">>,
                        MemberId,
                        500,
                        safe_bin(Reason),
                        Path
                    );
                {error, Status, Message, Details} ->
                    backend_error_response(
                        <<"write-file">>,
                        MemberId,
                        Status,
                        Message,
                        Details,
                        #{ <<"path">> => Path }
                    )
            end
        end
    );
handle_action(list_files, Req, Opts) ->
    with_authorized_member(
        read,
        <<"list-files">>,
        Req,
        Opts,
        fun(MemberId, _Member) ->
            Path =
                require_path_value(
                    maps:get(<<"path">>, Req, ?DEFAULT_HOME),
                    true
                ),
            case list_files(MemberId, Path, Opts) of
                {ok, Response} ->
                    success_response(<<"list-files">>, MemberId, Response);
                {error, Status, Message} ->
                    error_response(
                        <<"list-files">>,
                        MemberId,
                        Status,
                        Message,
                        #{ <<"path">> => Path }
                    );
                {error, Status, Message, Details} ->
                    backend_error_response(
                        <<"list-files">>,
                        MemberId,
                        Status,
                        Message,
                        Details,
                        #{ <<"path">> => Path }
                    )
            end
        end
    );
handle_action(Action, Req, Opts) ->
    with_authorized_member(
        authorization_action(Action),
        Action,
        Req,
        Opts,
        fun(MemberId, Member) ->
            case Action of
                read   -> handle_read(MemberId, Req, Opts);
                write  -> handle_write(MemberId, Req, Opts);
                append -> handle_append(MemberId, Req, Opts);
                edit   -> handle_edit(MemberId, Req, Opts);
                glob   ->
                    handle_search(
                        glob,
                        MemberId,
                        Req,
                        Opts,
                        fun glob_command/1
                    );
                grep   ->
                    handle_search(
                        grep,
                        MemberId,
                        Req,
                        Opts,
                        fun grep_command/1
                    );
                bash   -> handle_bash(MemberId, Member, Req, Opts);
                bash_session ->
                    handle_bash_session(MemberId, Member, Req, Opts)
            end
        end
    ).

%% @doc Authorize session control through the existing Bash capability.
authorization_action(bash_session) -> bash;
authorization_action(Action) -> Action.

with_authorized_member(AuthAction, ResponseAction, Req, Opts, Fun) ->
    case member_context(AuthAction, Req, Opts) of
        {error, Status, Message} ->
            {ok,
                error_response(
                    ResponseAction,
                    undefined,
                    Status,
                    Message
                )};
        {ok, MemberId, Member} ->
            {ok,
                try
                    with_member_lock(
                        MemberId,
                        fun() -> Fun(MemberId, Member) end
                    )
                catch
                    throw:{tool_error, Status, Message} ->
                        error_response(
                            ResponseAction,
                            MemberId,
                            Status,
                            Message
                        )
                end}
    end.

with_member_lock(MemberId, Fun) ->
    global:trans(
        {{?MODULE, MemberId}, self()},
        Fun
    ).

request_method(Req) when is_map(Req) ->
    Method = maps:get(<<"method">>, request_view(Req), undefined),
    hb_util:bin(string:uppercase(binary_to_list(hb_util:bin(Method))));
request_method(_) ->
    undefined.

handle_read(MemberId, Req, Opts) ->
    CanonicalPath = required_path(Req),
    with_file_content(read, MemberId, CanonicalPath, Opts,
        fun(Content0) ->
            output_response(read, MemberId, Content0, fun(Content) ->
                #{
                    <<"path">> => CanonicalPath,
                    <<"size">> => byte_size(Content0),
                    <<"content">> => Content
                }
            end)
        end).

handle_write(MemberId, Req, Opts) ->
    handle_write_like(
        write,
        MemberId,
        Req,
        fun(Path, Content) ->
            {<<"Wrote ">>, <<"write">>, execution_write(MemberId, Path, Content, Opts)}
        end
    ).

handle_append(MemberId, Req, Opts) ->
    handle_write_like(
        append,
        MemberId,
        Req,
        fun(Path, Content) ->
            Clear = normalize_boolean(maps:get(<<"clear">>, Req, false), false),
            {
                case Clear of true -> <<"Rebuilt ">>; false -> <<"Appended ">> end,
                case Clear of true -> <<"replace">>; false -> <<"append">> end,
                append_content(MemberId, Path, Content, Clear, Opts)
            }
        end
    ).

handle_write_like(Action, MemberId, Req, Fun) ->
    Path = required_path(Req),
    Content = required_binary(Req, <<"content">>, <<"content is required.">>),
    case Fun(Path, Content) of
        {Verb, DeltaOp, ok} ->
            Bytes = byte_size(Content),
            success_response(
                Action,
                MemberId,
                #{
                    <<"path">> => Path,
                    <<"bytes">> => Bytes,
                    <<"output">> => <<Verb/binary, Path/binary>>,
                    <<"deltas">> => [delta(DeltaOp, Path, #{ <<"bytes">> => Bytes })]
                }
            );
        {_Verb, _DeltaOp, {error, Reason}} ->
            path_error_response(Action, MemberId, 500, safe_bin(Reason), Path);
        {_Verb, _DeltaOp, {error, Status, Message, Details}} ->
            backend_error_response(
                Action,
                MemberId,
                Status,
                Message,
                Details,
                #{ <<"path">> => Path }
            )
    end.

append_content(MemberId, CanonicalPath, Content, true, Opts) ->
    execution_write(MemberId, CanonicalPath, Content, Opts);
append_content(MemberId, CanonicalPath, Content, false, Opts) ->
    case execution_read(MemberId, CanonicalPath, Opts) of
        {ok, Existing} ->
            execution_write(MemberId, CanonicalPath, <<Existing/binary, Content/binary>>, Opts);
        {error, enoent} ->
            execution_write(MemberId, CanonicalPath, Content, Opts);
        {error, _} = Error ->
            Error;
        {error, _, _, _} = Error ->
            Error
    end.

handle_edit(MemberId, Req, Opts) ->
    CanonicalPath = required_path(Req),
    OldString = required_binary(Req, <<"old-string">>, <<"old-string is required.">>),
    NewString = required_binary(Req, <<"new-string">>, <<"new-string is required.">>),
    with_file_content(edit, MemberId, CanonicalPath, Opts,
        fun(Content) ->
            Matches = binary:matches(Content, OldString),
            ReplaceAll = normalize_boolean(maps:get(<<"replace-all">>, Req, false), false),
            case Matches of
                [] ->
                    path_error_response(edit, MemberId, 400, <<"old-string not found.">>, CanonicalPath);
                [_ | _] when ReplaceAll =:= false, length(Matches) > 1 ->
                    path_error_response(edit, MemberId, 400, <<"old-string matched more than once; use replace-all to edit every match.">>, CanonicalPath);
                _ ->
                    ReplaceOpts = case ReplaceAll of true -> [global]; false -> [] end,
                    Next = binary:replace(Content, OldString, NewString, ReplaceOpts),
                    case execution_write(MemberId, CanonicalPath, Next, Opts) of
                        ok ->
                            Count = length(Matches),
                            CountBin = integer_to_binary(Count),
                            Suffix = case Count of 1 -> <<>>; _ -> <<"s">> end,
                            success_response(
                                edit,
                                MemberId,
                                #{
                                    <<"path">> => CanonicalPath,
                                    <<"replacements">> => Count,
                                    <<"output">> =>
                                        <<"Edited ", CanonicalPath/binary, " (", CountBin/binary,
                                            " replacement", Suffix/binary, ")">>,
                                    <<"deltas">> => [delta(<<"edit">>, CanonicalPath, #{ <<"replacements">> => Count })]
                                }
                            );
                        {error, Reason} ->
                            path_error_response(edit, MemberId, 500, safe_bin(Reason), CanonicalPath);
                        {error, Status, Message, Details} ->
                            backend_error_response(
                                edit,
                                MemberId,
                                Status,
                                Message,
                                Details,
                                #{ <<"path">> => CanonicalPath }
                            )
                    end
            end
        end).

with_file_content(Action, MemberId, CanonicalPath, Opts, Fun) ->
    case execution_read(MemberId, CanonicalPath, Opts) of
        {ok, Content} -> Fun(Content);
        {error, Reason} ->
            container_file_error_response(Action, MemberId, CanonicalPath, Reason);
        {error, Status, Message, Details} ->
            backend_error_response(
                Action,
                MemberId,
                Status,
                Message,
                Details,
                #{ <<"path">> => CanonicalPath }
            )
    end.

handle_search(Action, MemberId, Req, Opts, CommandFun) ->
    with_required_cwd(Req, <<"pattern">>, <<"pattern is required.">>,
        fun(Pattern, CwdCanonical) ->
            run_command_tool(Action, MemberId, CwdCanonical, <<"pattern">>,
                Pattern, CommandFun(Pattern), ?DEFAULT_TIMEOUT_MS, true,
                fun(Output) ->
                    #{ <<"matches">> => [Line || Line <- binary:split(trim_bin(Output), <<"\n">>, [global]), Line =/= <<>>] }
                end, Opts)
        end
    ).

with_required_cwd(Req, Key, RequiredMessage, Fun) ->
    Fun(
        required_binary(Req, Key, RequiredMessage),
        require_path_value(maps:get(<<"cwd">>, Req, ?DEFAULT_HOME), true)
    ).

glob_command(Pattern) ->
    <<"python3 - <<'PY'\nimport glob\nfor match in sorted(glob.glob(",
      (hb_json:encode(Pattern))/binary, ", recursive=True)):\n    print(match)\nPY">>.

grep_command(Pattern) ->
    <<"rg -n --hidden --glob '!node_modules' ", (shell_quote(Pattern))/binary, " . || true">>.

handle_bash(MemberId, Member, Req, Opts) ->
    with_required_cwd(Req, <<"command">>, <<"command is required.">>,
        fun(Command, CwdCanonical) ->
            DisableNetwork = not member_allows_network(Member),
            case lib_permawebos_bash_session:start(
                MemberId,
                CwdCanonical,
                Command,
                maps:get(<<"timeout-ms">>, Req, undefined),
                maps:get(<<"yield-ms">>, Req, undefined),
                DisableNetwork,
                maps:get(<<"execution-id">>, Req, undefined),
                Opts
            ) of
                {ok, Result} ->
                    success_response(bash, MemberId, Result);
                {error, Status, Message} ->
                    error_response(
                        bash,
                        MemberId,
                        Status,
                        Message,
                        #{ <<"cwd">> => CwdCanonical, <<"command">> => Command }
                    );
                {error, Status, Message, Details} ->
                    backend_error_response(
                        bash,
                        MemberId,
                        Status,
                        Message,
                        Details,
                        #{ <<"cwd">> => CwdCanonical, <<"command">> => Command }
                    )
            end
        end
    ).

%% @doc Poll or terminate a member-scoped background Bash session.
handle_bash_session(MemberId, _Member, Req, Opts) ->
    SessionId = maps:get(<<"session-id">>, Req, undefined),
    case lib_permawebos_bash_session:poll(
        MemberId,
        SessionId,
        maps:get(<<"cursor">>, Req, 0),
        maps:get(<<"wait-ms">>, Req, undefined),
        maps:get(<<"terminate">>, Req, false),
        Opts
    ) of
        {ok, Result} ->
            success_response(<<"bash-session">>, MemberId, Result);
        {error, Status, Message} ->
            error_response(
                <<"bash-session">>,
                MemberId,
                Status,
                Message,
                #{ <<"session-id">> => SessionId }
            );
        {error, Status, Message, Details} ->
            backend_error_response(
                <<"bash-session">>,
                MemberId,
                Status,
                Message,
                Details,
                #{ <<"session-id">> => SessionId }
            )
    end.

run_command_tool(Action, MemberId, Cwd, InputKey, InputValue, Command, TimeoutMs, DisableNetwork, ExtraFun, Opts) ->
    case execution_exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, Opts) of
        {ok, Output0, ExitCode} ->
            output_response(Action, MemberId, Output0, fun(Output) ->
                maps:merge(#{ <<"cwd">> => Cwd, InputKey => InputValue, <<"exit-code">> => ExitCode }, ExtraFun(Output))
            end);
        {error, Status, Message} ->
            error_response(
                Action,
                MemberId,
                Status,
                Message,
                #{ <<"cwd">> => Cwd, InputKey => InputValue }
            );
        {error, Status, Message, Details} ->
            backend_error_response(
                Action,
                MemberId,
                Status,
                Message,
                Details,
                #{ <<"cwd">> => Cwd, InputKey => InputValue }
            )
    end.

output_response(Action, MemberId, Output0, ExtraFun) ->
    {Output, Truncated} = clip_output(Output0, ?MAX_OUTPUT_BYTES),
    success_response(
        Action,
        MemberId,
        maps:merge(
            #{ <<"output">> => Output, <<"truncated">> => Truncated },
            ExtraFun(Output)
        )
    ).

member_context(Action, Req, Opts) ->
    try
        MemberId = required_binary(Req, <<"member-id">>, <<"member-id is required.">>),
            case request_member_context(MemberId, Req) of
                {ok, Member} ->
                    authorize_member_context(Action, MemberId, Member, Opts);
                missing ->
                    {error, 400, <<"member-context is required.">>};
                {error, Message} ->
                    {error, 400, Message}
            end
    catch
        throw:{tool_error, Status, ErrorMessage} ->
            {error, Status, ErrorMessage}
    end.

request_member_context(MemberId, Req) ->
    case maps:get(<<"member-context">>, Req, undefined) of
        Missing when Missing =:= undefined; Missing =:= null ->
            missing;
        Context when is_map(Context) ->
            case member_context_id(Context, MemberId) of
                {ok, MemberId} ->
                    {ok, normalize_member_context(MemberId, Context)};
                {ok, _OtherId} ->
                    {error, <<"member-context id does not match member-id.">>};
                error ->
                    {error, <<"member-context id must be a string.">>}
            end;
        _ ->
            {error, <<"member-context must be an object.">>}
    end.

member_context_id(Context, DefaultId) ->
    case maps:get(<<"id">>, Context, DefaultId) of
        Missing when Missing =:= undefined; Missing =:= null ->
            {ok, DefaultId};
        Value when is_binary(Value); is_list(Value); is_atom(Value); is_integer(Value) ->
            {ok, hb_util:bin(Value)};
        _ ->
            error
    end.

authorize_member_context(Action, MemberId, Member, _Opts) ->
    Tool = lib_permawebos_execution_tools:name(Action),
    case lists:member(Tool, maps:get(<<"tools">>, Member, [])) of
        true ->
            {ok, MemberId, Member};
        false ->
            {error, 403, <<Tool/binary, " is not enabled for this member.">>}
    end.

normalize_member_context(MemberId, Context) ->
    Context#{
        <<"id">> => MemberId,
        <<"tools">> => string_list(maps:get(<<"tools">>, Context, [])),
        <<"metadata">> => ensure_map(maps:get(<<"metadata">>, Context, #{}))
    }.

required_path(Req) ->
    require_path_value(required_binary(Req, <<"path">>, <<"path is required.">>), false).

required_binary(Req, Key, Message) ->
    case maybe_bin(maps:get(Key, Req, undefined)) of
        undefined -> throw({tool_error, 400, Message});
        Value -> Value
    end.

require_path_value(Value, AllowEmpty) ->
    case normalize_requested_path(Value, AllowEmpty) of
        {ok, Path} -> Path;
        {error, Message} -> throw({tool_error, 400, Message})
    end.

normalize_requested_path(Value, AllowEmpty) ->
    Bin0 = hb_util:bin(Value),
    Bin1 = trim_bin(Bin0),
    case Bin1 of
        <<>> when AllowEmpty =:= true ->
            {ok, ?DEFAULT_HOME};
        <<>> ->
            {error, <<"path is required.">>};
        _ ->
            case binary:match(Bin1, <<0>>) of
                nomatch ->
                    Resolved = case Bin1 of
                        <<"/", _/binary>> -> Bin1;
                        _ -> <<?DEFAULT_HOME/binary, "/", Bin1/binary>>
                    end,
                    case lists:member(<<"..">>, binary:split(Resolved, <<"/">>, [global])) of
                        true ->
                            {error, <<"Paths cannot contain '..' segments.">>};
                        false ->
                            {ok, normalize_slashes(Resolved)}
                    end;
                _ ->
                    {error, <<"path cannot contain null bytes.">>}
            end
    end.

normalize_slashes(Path) ->
    Parts = [P || P <- binary:split(Path, <<"/">>, [global]), P =/= <<>>, P =/= <<".">>],
    case Parts of
        [] -> <<"/">>;
        _  -> iolist_to_binary([<<"/">>, lists:join(<<"/">>, Parts)])
    end.


execution_read(MemberId, Path, Opts) ->
    Backend = execution_backend(Opts),
    Backend:container_read(MemberId, Path, Opts).

execution_write(MemberId, Path, Content, Opts) ->
    Backend = execution_backend(Opts),
    Backend:container_write(MemberId, Path, Content, Opts).

execution_exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, Opts) ->
    Backend = execution_backend(Opts),
    Backend:exec(
        MemberId,
        Cwd,
        Command,
        TimeoutMs,
        DisableNetwork,
        Opts
    ).

execution_list_dir(MemberId, Path, Opts) ->
    Backend = execution_backend(Opts),
    Backend:container_list_dir(MemberId, Path, Opts).

execution_backend(Opts) ->
    maps:get(execution_backend, Opts, ?MODULE).
success_response(Action, MemberId, Extra) ->
    response(true, Action, MemberId, Extra).

error_response(Action, MemberId, Status, Message) ->
    error_response(Action, MemberId, Status, Message, #{}).

error_response(Action, MemberId, Status, Message, Extra) ->
    response(false, Action, MemberId, Extra#{
        <<"status">> => Status,
        <<"error">> => hb_util:bin(Message)
    }).

backend_error_response(Action, MemberId, Status, Message, Details, Extra) ->
    error_response(
        Action,
        MemberId,
        Status,
        Message,
        maps:merge(Extra, Details)
    ).

response(Ok, Action, MemberId, Extra) ->
    maps:merge(
        #{ <<"ok">> => Ok, <<"device">> => ?DEFAULT_DEVICE, <<"action">> => hb_util:bin(Action),
           <<"member-id">> => MemberId, <<"artifacts">> => [], <<"deltas">> => [] },
        Extra
    ).

path_error_response(Action, MemberId, Status, Message, Path) ->
    error_response(Action, MemberId, Status, Message, #{ <<"path">> => Path }).

container_file_error_response(Action, MemberId, Path, enoent) ->
    path_error_response(Action, MemberId, 404, <<"File not found.">>, Path);
container_file_error_response(Action, MemberId, Path, eisdir)
  when Action =:= read; Action =:= <<"read-file">> ->
    path_error_response(
        Action,
        MemberId,
        400,
        <<"Path is a directory, not a file.">>,
        Path
    );
container_file_error_response(Action, MemberId, Path, Reason) ->
    path_error_response(Action, MemberId, 500, safe_bin(Reason), Path).

delta(Op, Path, Extra) ->
    maps:merge(
        #{ <<"op">> => Op, <<"path">> => Path },
        Extra
    ).

member_allows_network(Member) ->
    normalize_boolean(
        maps:get(<<"allow-network">>, maps:get(<<"metadata">>, Member, #{}), true),
        true
    ).

clip_output(Output, _Limit) when Output =:= undefined; Output =:= null ->
    {<<>>, false};
clip_output(Output, Limit) when is_binary(Output), byte_size(Output) > Limit ->
    {binary:part(Output, 0, Limit), true};
clip_output(Output, _Limit) when is_binary(Output) ->
    {Output, false};
clip_output(Output, Limit) ->
    clip_output(hb_util:bin(Output), Limit).

shell_quote(Value) ->
    Escaped =
        lists:flatmap(
            fun
                ($') -> "'\\''";
                (Char) -> [Char]
            end,
            binary_to_list(hb_util:bin(Value))
        ),
    hb_util:bin(["'", Escaped, "'"]).

trim_bin(Bin) when is_binary(Bin) ->
    hb_util:bin(string:trim(binary_to_list(Bin)));
trim_bin(Value) ->
    trim_bin(hb_util:bin(Value)).

list_files(MemberId, RawPath, Opts) ->
    with_member_path(MemberId, RawPath, true,
        fun(Id, CanonicalPath) ->
            case execution_list_dir(Id, CanonicalPath, Opts) of
                {ok, Entries0} ->
                    {ok, list_files_response(Id, CanonicalPath, Entries0)};
                {error, enoent} ->
                    {ok, list_files_response(Id, CanonicalPath, [])};
                {error, Reason} ->
                    {error, 500, safe_bin(Reason)};
                {error, Status, Message, Details} ->
                    {error, Status, Message, Details}
            end
        end
    ).

list_files_response(MemberId, CanonicalPath, Entries0) ->
    PathPrefix =
        case CanonicalPath of
            <<"/">> -> <<>>;
            _ -> CanonicalPath
        end,
    Entries =
        [
            E#{ <<"path">> => <<PathPrefix/binary, "/", (maps:get(<<"name">>, E))/binary>> }
         || E <- lists:sort(
                fun(A, B) -> maps:get(<<"name">>, A) =< maps:get(<<"name">>, B) end,
                Entries0
            )
        ],
    #{ <<"member-id">> => MemberId, <<"path">> => CanonicalPath, <<"entries">> => Entries }.

serve_file(MemberId, RawPath, Opts) ->
    with_member_path(MemberId, RawPath, false,
        fun(Id, CanonicalPath) ->
            case execution_read(Id, CanonicalPath, Opts) of
                {ok, Bytes} ->
                    {ok,
                        #{
                            <<"status">> => 200,
                            <<"content-type">> => add_text_charset(mimerl:filename(hb_util:bin(CanonicalPath))),
                            <<"content-length">> => integer_to_binary(byte_size(Bytes)),
                            <<"content-disposition">> => explorer_content_disposition(CanonicalPath),
                            <<"body">> => Bytes
                        }};
                {error, enoent} ->
                    {error, 404, <<"File not found.">>};
                {error, eisdir} ->
                    {error, 400, <<"Path is a directory, not a file.">>};
                {error, Reason} ->
                    {error, 500, safe_bin(Reason)};
                {error, Status, Message, Details} ->
                    {error, Status, Message, Details}
            end
        end
    ).

with_member_path(MemberId, RawPath, AllowEmpty, Fun) ->
    case {maybe_bin(MemberId), normalize_requested_path(RawPath, AllowEmpty)} of
        {undefined, _} -> {error, 400, <<"member-id is required.">>};
        {_Id, {error, Message}} -> {error, 400, Message};
        {Id, {ok, CanonicalPath}} -> Fun(Id, CanonicalPath)
    end.

explorer_content_disposition(CanonicalPath) ->
    Filename = hb_util:bin(first_defined([filename:basename(CanonicalPath), <<"download">>])),
    <<"inline; filename=\"", Filename/binary, "\"">>.

add_text_charset(<<"text/", _/binary>> = Mime) ->
    <<Mime/binary, "; charset=utf-8">>;
add_text_charset(<<"application/json">>) ->
    <<"application/json; charset=utf-8">>;
add_text_charset(<<"application/xml">>) ->
    <<"application/xml; charset=utf-8">>;
add_text_charset(Mime) ->
    Mime.


ensure_loaded(Value, Opts) ->
    case hb_cache:ensure_all_loaded(Value, Opts) of
        {ok, Loaded} -> Loaded;
        Loaded -> Loaded
    end.

request_view(Req) when is_map(Req) ->
    case maps:get(<<"body">>, Req, undefined) of
        Body when is_map(Body) -> maps:merge(Req, Body);
        _ -> Req
    end;
request_view(Req) ->
    Req.

request_payload_view(Req) when is_map(Req) ->
    View = request_view(Req),
    maps:merge(View, request_json_map(View));
request_payload_view(Req) ->
    Req.

request_payload_view(Req = #{ <<"body">> := RawBody }, Opts) ->
    LoadedBody = ensure_loaded(RawBody, Opts),
    ResolvedReq =
        case LoadedBody of
            Body when is_map(Body) -> maps:merge(Req, Body);
            _ -> Req
        end,
    request_payload_view(ensure_loaded(ResolvedReq, Opts));
request_payload_view(Req, Opts) when is_map(Req) ->
    request_payload_view(ensure_loaded(Req, Opts));
request_payload_view(Req, _Opts) ->
    request_payload_view(Req).

request_json_map(Req) when is_map(Req) ->
    View = request_view(Req),
    case maps:get(<<"body">>, View, undefined) of
        Value when is_map(Value) ->
            case decode_json_map(
                first_present(request_view(Value), [<<"data">>, <<"body">>])
            ) of
                {ok, Decoded} -> Decoded;
                error -> Value
            end;
        Value when is_binary(Value), Value =/= <<>> ->
            decode_json_map_or_empty(Value);
        _ ->
            decode_json_map_or_empty(
                first_present(View, [<<"data">>, <<"body">>])
            )
    end;
request_json_map(_Req) ->
    #{}.

first_present(Map, Keys) when is_map(Map) ->
    first_defined([maps:get(Key, Map, undefined) || Key <- Keys]);
first_present(_Map, _Keys) ->
    undefined.

first_defined([Value | Rest])
        when Value =:= undefined; Value =:= null; Value =:= <<>> ->
    first_defined(Rest);
first_defined([Value | _Rest]) ->
    Value;
first_defined([]) ->
    undefined.

decode_json_map(Value) when is_binary(Value), Value =/= <<>> ->
    try hb_json:decode(Value) of
        Decoded when is_map(Decoded) -> {ok, Decoded};
        _ -> error
    catch
        _:_ -> error
    end;
decode_json_map(_Value) ->
    error.

decode_json_map_or_empty(Value) ->
    case decode_json_map(Value) of
        {ok, Decoded} -> Decoded;
        error -> #{}
    end.

ensure_map(Value) when is_map(Value) ->
    Value;
ensure_map(_) ->
    #{}.

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

nullable_bin(Value) when Value =:= undefined; Value =:= null; Value =:= <<>> ->
    null;
nullable_bin(Value) when is_binary(Value) ->
    hb_util:bin(string:trim(hb_util:list(Value)));
nullable_bin(Value) when is_list(Value) ->
    hb_util:bin(string:trim(Value));
nullable_bin(Value) ->
    hb_util:bin(Value).

string_list(Value) when is_list(Value) ->
    [
        Item
     || Item <- lists:map(fun nullable_bin/1, Value),
        Item =/= null
    ];
string_list(_) ->
    [].

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

-ifdef(TEST).

clip_output_omits_absent_output_test() ->
    ?assertEqual({<<>>, false}, clip_output(undefined, 1024)),
    ?assertEqual({<<>>, false}, clip_output(null, 1024)).

-endif.
