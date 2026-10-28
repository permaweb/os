%%% @doc Materializes AO-Core model and image messages for Android backends.
-module(lib_andee_materialization).
-export([model/3, andock/2]).
-include_lib("kernel/include/file.hrl").

-define(MODEL_ROOT_ENV, "ANDEE_INFERENCE_MODEL_ROOT").
-define(ANDOCK_ROOT_ENV, "ANDEE_ANDOCK_IMAGE_ROOT").
-define(ARTIFACT_CACHE_ROOT_ENV, "ANDEE_ARTIFACT_CACHE_ROOT").
-define(MODEL_MANIFEST_FORMAT, <<"permawebos/andee-model/1">>).
-define(MAX_MODEL_MANIFEST_BYTES, 1024 * 1024).
-define(MAX_MODEL_CHUNKS, 128).
-define(ANDOCK_DEADLINE_MS, 30 * 60 * 1000).
-define(ANDOCK_RETRY_DELAY_MS, 60000).
-define(ANDOCK_STATUS_TIMEOUT_MS, 100).

%% @doc Resolve a configured model through `hb_cache' and return its local path.
model(Provider, Model, Opts) ->
    case model_spec(Provider, Model, Opts) of
        {ok, Spec} -> materialize_model(Spec, Opts);
        Error -> Error
    end.

%% @doc Resolve the measured Andock sparse image through `hb_cache'.
andock(ID, Opts) when is_binary(ID), byte_size(ID) =:= 43 ->
    case destination(?ANDOCK_ROOT_ENV, <<ID/binary, ".simg">>) of
        {ok, Path} ->
            case valid_id(ID) of
                true -> ensure_andock(ID, Path, Opts);
                false -> {error, 'invalid-andock-image-id'}
            end;
        Error -> Error
    end;
andock(_, _) ->
    {error, 'invalid-andock-image-id'}.

%% @doc Find the selected model in the measured provider configuration.
model_spec(Provider0, Model0, Opts) ->
    Providers = hb_opts:get(inference_providers, #{}, Opts),
    case select_provider(Provider0, Providers) of
        {ok, Provider, ProviderSpec} ->
            Model = strip_provider(Provider, Model0),
            Models = hb_maps:get(<<"models">>, ProviderSpec, [], Opts),
            case lists:filter(
                fun(Spec) ->
                    hb_maps:get(<<"id">>, Spec, undefined, Opts) =:= Model
                end,
                Models
            ) of
                [Spec] -> validate_model_spec(Provider, Model, Spec, Opts);
                _ -> {error, 'unknown-inference-model'}
            end;
        Error -> Error
    end.

%% @doc Select an explicit provider, or the sole configured provider.
select_provider(undefined, Providers) when map_size(Providers) =:= 1 ->
    [{Provider, Spec}] = maps:to_list(Providers),
    {ok, Provider, Spec};
select_provider(Provider, Providers) when is_binary(Provider) ->
    case maps:find(Provider, Providers) of
        {ok, Spec} -> {ok, Provider, Spec};
        error -> {error, 'unknown-inference-provider'}
    end;
select_provider(_, _) ->
    {error, 'inference-provider-required'}.

%% @doc Remove the provider prefix accepted by the public inference API.
strip_provider(Provider, Model) ->
    Prefix = <<Provider/binary, "/">>,
    PrefixBytes = byte_size(Prefix),
    case Model of
        <<Prefix:PrefixBytes/binary, Unprefixed/binary>> -> Unprefixed;
        _ -> Model
    end.

%% @doc Validate the network and runtime fields needed for materialization.
validate_model_spec(Provider, Model, Spec, Opts) ->
    ID = hb_maps:get(<<"model-id">>, Spec, undefined, Opts),
    Bytes = hb_maps:get(<<"bytes">>, Spec, undefined, Opts),
    Runtime = hb_maps:get(<<"runtime">>, Spec, undefined, Opts),
    case {
        valid_id(ID),
        is_integer(Bytes) andalso Bytes > 0,
        model_extension(Runtime)
    } of
        {true, true, {ok, Extension}} ->
            {ok, #{
                provider => Provider,
                model => Model,
                id => ID,
                bytes => Bytes,
                extension => Extension
            }};
        _ ->
            {error, 'invalid-inference-model-configuration'}
    end.

%% @doc Map measured runtime names to backend file extensions.
model_extension(<<"litert-lm">>) -> {ok, <<".litertlm">>};
model_extension(<<"llama-cpp">>) -> {ok, <<".gguf">>};
model_extension(_) -> error.

%% @doc Materialize either a direct model message or its authenticated chunks.
materialize_model(
        #{id := ID, bytes := Bytes, extension := Extension} = Spec,
        Opts
    ) ->
    case destination(?MODEL_ROOT_ENV, <<ID/binary, Extension/binary>>) of
        {ok, Path} ->
            with_lock(
                Path,
                fun() ->
                    case existing(Path, Bytes) of
                        {ok, Bytes} ->
                            materialized_model(Spec, Path);
                        missing ->
                            case model_parts(ID, Bytes, Opts) of
                                {ok, Parts} ->
                                    case write_model_parts(ID, Path, Bytes, Parts, Opts) of
                                        {ok, _} -> materialized_model(Spec, Path);
                                        Error -> Error
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end
                end
            );
        Error -> Error
    end.

%% @doc Interpret the configured ID as a model manifest only when it says so.
model_parts(ID, Bytes, Opts) ->
    case read_body(ID, Opts) of
        {ok, Body} when byte_size(Body) =< ?MAX_MODEL_MANIFEST_BYTES ->
            case decode_manifest(Body) of
                not_manifest when byte_size(Body) =:= Bytes ->
                    {ok, [{body, Body}]};
                not_manifest ->
                    {error, 'model-byte-length-mismatch'};
                {ok, Manifest} ->
                    parse_manifest(Manifest, Bytes);
                Error -> Error
            end;
        {ok, Body} when byte_size(Body) =:= Bytes ->
            {ok, [{body, Body}]};
        {ok, _Body} ->
            {error, 'model-byte-length-mismatch'};
        Error -> Error
    end.

%% @doc Decode only the PermawebOS model manifest format.
decode_manifest(Body) ->
    try hb_json:decode(Body) of
        #{ <<"format">> := ?MODEL_MANIFEST_FORMAT } = Manifest ->
            {ok, Manifest};
        _ ->
            not_manifest
    catch
        _:_ -> not_manifest
    end.

%% @doc Validate the authenticated manifest's ordered chunk list.
parse_manifest(Manifest, ExpectedBytes) ->
    ManifestBytes = maps:get(<<"model-bytes">>, Manifest, undefined),
    Chunks = maps:get(<<"chunks">>, Manifest, undefined),
    case is_list(Chunks) andalso length(Chunks) > 0 andalso
        length(Chunks) =< ?MAX_MODEL_CHUNKS
    of
        true ->
            case parse_chunks(Chunks, [], []) of
                {ok, Parts, ExpectedBytes} when ManifestBytes =:= ExpectedBytes ->
                    {ok, Parts};
                {ok, _, _} ->
                    {error, 'model-byte-length-mismatch'};
                Error -> Error
            end;
        false ->
            {error, 'invalid-model-manifest'}
    end.

%% @doc Normalize and validate unique chunk IDs and positive byte lengths.
parse_chunks([], Parts, _IDs) ->
    Bytes = lists:sum([Size || {chunk, _, Size} <- Parts]),
    {ok, lists:reverse(Parts), Bytes};
parse_chunks([Chunk | Rest], Parts, IDs) when is_map(Chunk) ->
    ID = maps:get(<<"id">>, Chunk, undefined),
    Bytes = maps:get(<<"bytes">>, Chunk, undefined),
    case valid_id(ID) andalso
        is_integer(Bytes) andalso Bytes > 0 andalso not lists:member(ID, IDs)
    of
        true -> parse_chunks(Rest, [{chunk, ID, Bytes} | Parts], [ID | IDs]);
        false -> {error, 'invalid-model-manifest'}
    end;
parse_chunks(_, _, _) ->
    {error, 'invalid-model-manifest'}.

%% @doc Write direct or chunked model bodies without a second aggregate copy.
write_model_parts(ID, Path, Bytes, Parts, Opts) ->
    write_materialized(
        ID,
        Path,
        Bytes,
        fun(File) -> write_parts(File, Parts, Opts, 0) end
    ).

%% @doc Stream each cache-resolved chunk into the destination file.
write_parts(_File, [], _Opts, Written) ->
    {ok, Written};
write_parts(File, [{body, Body} | Rest], Opts, Written) ->
    case file:write(File, Body) of
        ok -> write_parts(File, Rest, Opts, Written + byte_size(Body));
        {error, Reason} -> {error, Reason}
    end;
write_parts(File, [{chunk, ID, Bytes} | Rest], Opts, Written) ->
    case read_body(ID, Opts) of
        {ok, Body} when byte_size(Body) =:= Bytes ->
            case file:write(File, Body) of
                ok -> write_parts(File, Rest, Opts, Written + Bytes);
                {error, Reason} -> {error, Reason}
            end;
        {ok, _} -> {error, 'model-chunk-length-mismatch'};
        Error -> Error
    end.

%% @doc Resolve a direct message and install its body at the backend path.
materialize_direct(ID, Path, Opts) ->
    case read_body(ID, Opts) of
        {ok, Body} -> write_materialized(ID, Path, byte_size(Body), [{body, Body}]);
        Error -> Error
    end.

%% @doc Keep the established non-blocking Andock cold-start contract. The
%% first request starts one BEAM-side cache materializer and returns a stable
%% retryable response; Android is not invoked until the sparse image exists.
ensure_andock(ID, Path, Opts) ->
    with_lock(Path, fun() -> andock_state(ID, Path, Opts) end).

%% @doc Return a complete image or query its sole background worker.
andock_state(ID, Path, Opts) ->
    case existing(Path, positive) of
        {ok, Bytes} -> materialized(ID, Path, Bytes);
        missing ->
            case whereis(andee_andock_materializer) of
                undefined ->
                    spawn(fun() -> andock_materializer(ID, Path, Opts) end),
                    {error, 'andock-default-image-materializing'};
                Pid -> andock_materializer_status(Pid)
            end;
        Error -> Error
    end.

%% @doc Claim the existing image worker before starting any network or disk work.
andock_materializer(ID, Path, Opts) ->
    Claimed = try register(andee_andock_materializer, self()) of
        true -> true
    catch error:badarg -> false
    end,
    case Claimed of
        true ->
            Fetch = fun() ->
                case existing(Path, positive) of
                    {ok, Bytes} -> materialized(ID, Path, Bytes);
                    missing -> materialize_direct(ID, Path, andock_download_opts(Opts));
                    Error -> Error
                end
            end,
            run_andock_materializer(
                Fetch, Path, ?ANDOCK_DEADLINE_MS, ?ANDOCK_RETRY_DELAY_MS
            );
        false -> ok
    end.

%% @doc Bound small Arweave reads and allow a large gateway body to make progress.
%% HTTP transport, verification and caching remain owned by the configured stores.
andock_download_opts(Opts) ->
    Stores = hb_opts:get(store, [], Opts),
    StoreList = case is_list(Stores) of true -> Stores; false -> [Stores] end,
    Opts#{<<"store">> => [andock_store_opts(Store) || Store <- StoreList]}.

andock_store_opts(#{<<"store-module">> := Module} = Store)
        when Module =:= hb_store_arweave; Module =:= hb_store_gateway ->
    Deadline = case Module of
        hb_store_arweave -> 60000;
        hb_store_gateway -> ?ANDOCK_DEADLINE_MS
    end,
    Store#{
        <<"http-client-connect-timeout">> => 5000,
        <<"http-client-send-timeout">> => Deadline,
        <<"http-client-hackney-recv-timeout">> => 60000,
        <<"http-retry">> => 0
    };
andock_store_opts(Store) -> Store.

%% @doc Keep a request-independent writer under a bounded lifetime and retain
%% its terminal failure so polling callers do not silently restart downloads.
run_andock_materializer(Fetch, Path, Timeout, RetryDelay) ->
    process_flag(trap_exit, true),
    Started = erlang:monotonic_time(millisecond),
    Coordinator = self(),
    Writer = spawn_link(fun() -> Coordinator ! {andock_result, self(), Fetch()} end),
    Result = try
        await_andock_materializer(Writer, Started, Started + Timeout)
    after
        unlink(Writer),
        exit(Writer, kill)
    end,
    case Result of
        {ok, _} -> ok;
        _ ->
            cleanup_andock_parts(Path),
            retain_andock_failure(Result, Started, RetryDelay)
    end.

%% @doc Polls do not extend the absolute deadline of the existing image job.
await_andock_materializer(Writer, Started, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    await_andock_materializer(Writer, Started, Deadline, Remaining).

await_andock_materializer(Writer, _Started, _Deadline, 0) ->
    stop_andock_writer(Writer);
await_andock_materializer(Writer, Started, Deadline, Remaining) ->
    receive
        {andock_status, Reply} ->
            Reply ! {Reply, {error, 'andock-default-image-materializing', #{
                <<"andock-image-state">> => <<"preparing">>,
                <<"andock-image-elapsed-ms">> => elapsed(Started)
            }}},
            await_andock_materializer(Writer, Started, Deadline);
        {andock_result, Writer, Result} -> Result;
        {'EXIT', Writer, normal} -> {error, 'image-worker-exited'};
        {'EXIT', Writer, _Reason} -> {error, 'image-worker-failed'}
    after Remaining ->
        stop_andock_writer(Writer)
    end.

%% @doc Wait for cancellation before allowing another writer or removing parts.
stop_andock_writer(Writer) ->
    exit(Writer, kill),
    receive {'EXIT', Writer, _} -> ok end,
    {error, 'download-deadline-exceeded'}.

%% @doc A monitor alias drops late replies after a caller stops waiting.
andock_materializer_status(Pid) ->
    Ref = monitor(process, Pid, [{alias, reply_demonitor}]),
    Pid ! {andock_status, Ref},
    receive
        {Ref, Result} -> Result;
        {'DOWN', Ref, process, Pid, _} -> {error, 'andock-default-image-materializing'}
    after ?ANDOCK_STATUS_TIMEOUT_MS ->
        demonitor(Ref, [flush]),
        {error, 'andock-default-image-materializing'}
    end.

%% @doc Return the same failure throughout a cooldown; only a later tool call
%% can start another attempt after the worker exits. Never retry on a status poll.
retain_andock_failure(Result, Started, RetryDelay) ->
    Cause = case Result of
        {error, Reason} when is_atom(Reason) -> atom_to_binary(Reason);
        _ -> <<"image-materialization-failed">>
    end,
    Error = {error, <<"andock-default-image-unavailable: ", Cause/binary>>, #{
        <<"andock-image-state">> => <<"failed">>,
        <<"andock-image-elapsed-ms">> => elapsed(Started),
        <<"cause">> => Cause,
        <<"retry-after">> => (RetryDelay + 999) div 1000
    }},
    retain_andock_failure_until(Error, erlang:monotonic_time(millisecond) + RetryDelay).

retain_andock_failure_until(Error, Until) ->
    Remaining = max(0, Until - erlang:monotonic_time(millisecond)),
    retain_andock_failure_until(Error, Until, Remaining).

retain_andock_failure_until(_Error, _Until, 0) -> ok;
retain_andock_failure_until({error, Reason, Details} = Error, Until, Remaining) ->
    receive
        {andock_status, Reply} ->
            Reply ! {Reply, {error, Reason,
                Details#{<<"retry-after">> => (Remaining + 999) div 1000}}},
            retain_andock_failure_until(Error, Until)
    after Remaining -> ok
    end.

elapsed(Started) -> max(0, erlang:monotonic_time(millisecond) - Started).

%% @doc Remove incomplete output only after the sole image writer has stopped.
cleanup_andock_parts(Path) ->
    Pattern = binary_to_list(<<Path/binary, ".*.part">>),
    lists:foreach(fun file:delete/1, filelib:wildcard(Pattern)).

%% @doc Read through a private disk-backed view of the configured remote stores.
read_body(ID, Opts) ->
    case artifact_opts(Opts) of
        {ok, ArtifactOpts} -> body(hb_cache:read(ID, ArtifactOpts), ArtifactOpts);
        Error -> Error
    end.

%% @doc Replace remote caches with app-private filesystem storage. This keeps
%% multi-gigabyte model bodies out of the node's volatile global cache while
%% retaining the configured Arweave-first, gateway-fallback ordering.
artifact_opts(Opts) ->
    case os:getenv(?ARTIFACT_CACHE_ROOT_ENV) of
        false ->
            {error, 'artifact-cache-root-unavailable'};
        Root ->
            case filename:pathtype(Root) of
                absolute ->
                    Cache = #{
                        <<"store-module">> => hb_store_fs,
                        <<"name">> => filename:join(hb_util:bin(Root), <<"cache">>)
                    },
                    Stores = artifact_stores(hb_opts:get(store, [], Opts), Cache),
                    case Stores of
                        [] ->
                            {error, 'artifact-store-unavailable'};
                        _ ->
                            ok = hb_store:start(Cache),
                            {ok, Opts#{
                                <<"store">> => Stores,
                                <<"match-index">> => false
                            }}
                    end;
                _ ->
                    {error, 'invalid-artifact-cache-root'}
            end
    end.

artifact_stores(Stores, Cache) when is_list(Stores) ->
    lists:filtermap(
        fun
            (Store = #{ <<"store-module">> := hb_store_arweave }) ->
                {true, Store#{ <<"local-store">> => Cache }};
            (Store = #{ <<"store-module">> := hb_store_gateway }) ->
                {true, Store#{ <<"local-store">> => Cache }};
            (_) ->
                false
        end,
        Stores
    );
artifact_stores(Store, Cache) ->
    artifact_stores([Store], Cache).

body({ok, Body}, _Opts) when is_binary(Body) ->
    {ok, Body};
body({ok, Message}, Opts) when is_map(Message) ->
    try hb_maps:get(<<"data">>, Message, not_found, Opts) of
        Data when is_binary(Data) -> {ok, Data};
        _ ->
            case hb_maps:get(<<"body">>, Message, not_found, Opts) of
                Body when is_binary(Body) -> {ok, Body};
                _ -> {error, 'materialized-message-has-no-payload'}
            end
    catch
        _:_ -> {error, 'materialized-message-has-no-payload'}
    end;
body({error, _}, _Opts) ->
    {error, 'materialized-message-not-found'};
body(_, _Opts) ->
    {error, 'materialized-message-not-found'}.

%% @doc Construct a backend-owned destination beneath its fixed environment root.
destination(Environment, Name) ->
    case os:getenv(Environment) of
        false -> {error, 'materialization-root-unavailable'};
        Root ->
            case filename:pathtype(Root) of
                absolute -> {ok, filename:join(hb_util:bin(Root), Name)};
                _ -> {error, 'invalid-materialization-root'}
            end
    end.

valid_id(ID) when is_binary(ID), byte_size(ID) =:= 43 ->
    lists:all(
        fun(Character) ->
            (Character >= $A andalso Character =< $Z) orelse
                (Character >= $a andalso Character =< $z) orelse
                (Character >= $0 andalso Character =< $9) orelse
                Character =:= $_ orelse Character =:= $-
        end,
        binary_to_list(ID)
    );
valid_id(_) ->
    false.

%% @doc Return an existing complete file without mutating invalid output.
existing(Path, ExpectedBytes) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Bytes}}
                when ExpectedBytes =:= positive, Bytes > 0 ->
            {ok, Bytes};
        {ok, #file_info{type = regular, size = ExpectedBytes}}
                when is_integer(ExpectedBytes) ->
            {ok, ExpectedBytes};
        {ok, #file_info{type = regular}} ->
            missing;
        {ok, _} ->
            {error, 'invalid-materialization-destination'};
        {error, enoent} ->
            missing;
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Serialize materialization of one deterministic backend path.
with_lock(Path, Fun) ->
    global:trans({?MODULE, Path}, Fun).

%% @doc Atomically install a resolved body or a writer callback's output.
write_materialized(ID, Path, ExpectedBytes, Bodies) when is_list(Bodies) ->
    write_materialized(
        ID,
        Path,
        ExpectedBytes,
        fun(File) -> write_parts(File, Bodies, #{}, 0) end
    );
write_materialized(ID, Path, ExpectedBytes, Writer) ->
    ok = filelib:ensure_dir(Path),
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Temporary = <<Path/binary, ".", Suffix/binary, ".part">>,
    try
        case file:open(Temporary, [write, binary, raw, exclusive]) of
            {ok, File} ->
                Result =
                    try
                        case Writer(File) of
                            {ok, ExpectedBytes} = Written ->
                                case file:change_mode(Temporary, 8#400) of
                                    ok ->
                                        case file:sync(File) of
                                            ok -> Written;
                                            {error, SyncReason} -> {error, SyncReason}
                                        end;
                                    {error, ModeReason} ->
                                        {error, ModeReason}
                                end;
                            Other -> Other
                        end
                    after
                        file:close(File)
                    end,
                case Result of
                    {ok, ExpectedBytes} ->
                        case file:rename(Temporary, Path) of
                            ok -> materialized(ID, Path, ExpectedBytes);
                            {error, RenameReason} -> {error, RenameReason}
                        end;
                    {ok, _} -> {error, 'materialized-byte-length-mismatch'};
                    Error -> Error
                end;
            {error, Reason} ->
                {error, Reason}
        end
    after
        file:delete(Temporary)
    end.

%% @doc Describe a fully installed materialization for the Android transport.
materialized(ID, Path, Bytes) ->
    {ok, #{<<"id">> => ID, <<"path">> => Path, <<"bytes">> => Bytes}}.

%% @doc Add provider/model identity to a materialized model description.
materialized_model(#{provider := Provider, model := Model, id := ID, bytes := Bytes}, Path) ->
    {ok, #{
        <<"provider">> => Provider,
        <<"model">> => Model,
        <<"id">> => ID,
        <<"path">> => Path,
        <<"bytes">> => Bytes
    }}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

andock_reports_download_failure_test() ->
    PreviousRoot = os:getenv(?ANDOCK_ROOT_ENV),
    PreviousCache = os:getenv(?ARTIFACT_CACHE_ROOT_ENV),
    Root = filename:join("/tmp", "andock-failure-" ++
        integer_to_list(erlang:unique_integer([positive, monotonic]))),
    ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    try
        true = os:putenv(?ANDOCK_ROOT_ENV, Root),
        os:unsetenv(?ARTIFACT_CACHE_ROOT_ENV),
        andock(ID, #{}),
        Result = await_andock_failure(ID, 50),
        ?assertMatch({error, <<"andock-default-image-unavailable: ", _/binary>>,
            #{<<"cause">> := <<"artifact-cache-root-unavailable">>}}, Result),
        ?assertEqual(Result, andock(ID, #{}))
    after
        case whereis(andee_andock_materializer) of
            undefined -> ok;
            Pid -> stop_test_process(Pid)
        end,
        restore_env(?ANDOCK_ROOT_ENV, PreviousRoot),
        restore_env(?ARTIFACT_CACHE_ROOT_ENV, PreviousCache),
        file:del_dir_r(Root)
    end.

await_andock_failure(ID, 0) -> andock(ID, #{});
await_andock_failure(ID, Attempts) ->
    case andock(ID, #{}) of
        {error, <<"andock-default-image-unavailable: ", _/binary>>, _} = Error -> Error;
        _ ->
            timer:sleep(10),
            await_andock_failure(ID, Attempts - 1)
    end.

andock_deadline_stops_writer_despite_status_polls_test() ->
    Parent = self(),
    Root = filename:join(<<"/tmp">>, <<"andock-deadline-",
        (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>),
    Path = filename:join(Root, <<"image.simg">>),
    Part = <<Path/binary, ".1.part">>,
    Fetch = fun() ->
        ok = filelib:ensure_dir(Path),
        ok = file:write_file(Part, <<"incomplete">>),
        Parent ! {writer_started, self()},
        receive finish -> {ok, unused} end
    end,
    {Coordinator, Monitor} = spawn_monitor(fun() ->
        run_andock_materializer(Fetch, Path, 60, 100)
    end),
    try
        Writer = receive {writer_started, Pid} -> Pid after 1000 -> error(no_writer) end,
        Result = poll_test_materializer(Coordinator, 500),
        ?assertMatch({error, _, #{<<"cause">> := <<"download-deadline-exceeded">>}}, Result),
        ?assertNot(is_process_alive(Writer)),
        ?assertNot(filelib:is_file(Part)),
        ?assertNot(filelib:is_file(Path)),
        ?assertMatch({error, _, #{<<"andock-image-state">> := <<"failed">>}},
            andock_materializer_status(Coordinator)),
        receive {'DOWN', Monitor, process, Coordinator, normal} -> ok
        after 1000 -> error(cooldown_never_ended)
        end
    after
        exit(Coordinator, kill),
        file:del_dir_r(Root)
    end.

%% @doc Poll continuously so each message cannot restart the job's time budget.
poll_test_materializer(Pid, Remaining) when Remaining > 0 ->
    case andock_materializer_status(Pid) of
        {error, _, #{<<"andock-image-state">> := <<"failed">>}} = Error -> Error;
        _ ->
            timer:sleep(1),
            poll_test_materializer(Pid, Remaining - 1)
    end;
poll_test_materializer(_, _) -> error(no_terminal_failure).

andock_success_and_crash_release_or_report_test() ->
    Path = test_image_path(),
    {Success, Ref} = spawn_monitor(fun() ->
        run_andock_materializer(fun() -> {ok, done} end, Path, 1000, 100)
    end),
    receive {'DOWN', Ref, process, Success, normal} -> ok
    after 1000 -> error(success_not_released)
    end,
    {Failed, FailedRef} = spawn_monitor(fun() ->
        run_andock_materializer(fun() -> error(synthetic_failure) end, Path, 1000, 100)
    end),
    ?assertMatch({error, _, #{<<"cause">> := <<"image-worker-failed">>}},
        poll_test_materializer(Failed, 100)),
    receive {'DOWN', FailedRef, process, Failed, normal} -> ok
    after 1000 -> error(failure_not_released)
    end.

andock_bounds_existing_http_stores_only_test() ->
    Local = #{<<"store-module">> => hb_store_fs, <<"name">> => <<"/tmp/test">>},
    Opts = #{<<"store">> => [
        Local,
        #{<<"store-module">> => hb_store_arweave, <<"remote-index">> => true},
        #{<<"store-module">> => hb_store_gateway}
    ]},
    #{<<"store">> := [Local, Arweave, Gateway]} = andock_download_opts(Opts),
    ?assertEqual(true, maps:get(<<"remote-index">>, Arweave)),
    ?assertEqual(60000, maps:get(<<"http-client-send-timeout">>, Arweave)),
    ?assertEqual(?ANDOCK_DEADLINE_MS, maps:get(<<"http-client-send-timeout">>, Gateway)),
    ?assertEqual(60000, maps:get(<<"http-client-hackney-recv-timeout">>, Gateway)),
    ?assertEqual(0, maps:get(<<"http-retry">>, Gateway)).

andock_retries_after_failure_and_installs_once_test() ->
    Root = filename:dirname(test_image_path()),
    ImageRoot = filename:join(Root, <<"images">>),
    ArtifactRoot = filename:join(Root, <<"artifacts">>),
    ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    Path = filename:join(ImageRoot, <<ID/binary, ".simg">>),
    Cache = #{<<"store-module">> => hb_store_fs,
        <<"name">> => filename:join(ArtifactRoot, <<"cache">>)},
    Opts = #{<<"store">> => [#{<<"store-module">> => hb_store_arweave,
        <<"index-store">> => Cache, <<"remote-index">> => true}]},
    PreviousRoot = os:getenv(?ANDOCK_ROOT_ENV),
    PreviousCache = os:getenv(?ARTIFACT_CACHE_ROOT_ENV),
    Parent = self(),
    try
        true = os:putenv(?ANDOCK_ROOT_ENV, binary_to_list(ImageRoot)),
        true = os:putenv(?ARTIFACT_CACHE_ROOT_ENV, binary_to_list(ArtifactRoot)),
        {Failed, Monitor} = spawn_monitor(fun() ->
            true = register(andee_andock_materializer, self()),
            Parent ! registered,
            run_andock_materializer(fun() -> {error, timeout} end, Path, 1000, 100)
        end),
        receive registered -> ok after 1000 -> error(not_registered) end,
        ?assertMatch({error, _, #{<<"cause">> := <<"timeout">>}},
            poll_test_materializer(Failed, 100)),
        ?assertMatch({error, _, #{<<"retry-after">> := 1}}, andock(ID, Opts)),
        ?assertNot(filelib:is_file(Path)),
        receive {'DOWN', Monitor, process, Failed, normal} -> ok
        after 1000 -> error(cooldown_not_released)
        end,
        ok = hb_store:start(Cache),
        Body = <<"verified-cache-test-image">>,
        ok = hb_store:write(Cache, #{ID => Body}, #{}),
        Ref = make_ref(),
        [spawn(fun() -> Parent ! {Ref, andock(ID, Opts)} end)
            || _ <- lists:seq(1, 20)],
        [receive {Ref, _} -> ok after 1000 -> error(caller_blocked) end
            || _ <- lists:seq(1, 20)],
        ?assertMatch({ok, #{<<"path">> := Path}}, wait_for_andock(ID, Opts, 100)),
        ?assertEqual({ok, Body}, file:read_file(Path)),
        ?assertEqual([], filelib:wildcard(binary_to_list(<<Path/binary, ".*.part">>)))
    after
        case whereis(andee_andock_materializer) of
            undefined -> ok;
            Pid -> stop_test_process(Pid)
        end,
        restore_env(?ANDOCK_ROOT_ENV, PreviousRoot),
        restore_env(?ARTIFACT_CACHE_ROOT_ENV, PreviousCache),
        file:del_dir_r(Root)
    end.

wait_for_andock(_ID, _Opts, 0) -> error(image_not_installed);
wait_for_andock(ID, Opts, Attempts) ->
    case andock(ID, Opts) of
        {ok, _} = Result -> Result;
        _ -> timer:sleep(10), wait_for_andock(ID, Opts, Attempts - 1)
    end.

andock_stalled_http_is_reported_and_connection_closed_test_() ->
    [{timeout, 10, fun() -> stalled_http_test(ReceiveTimeout, JobTimeout, Cause) end}
        || {ReceiveTimeout, JobTimeout, Cause} <- [
            {50, 3000, <<"timeout">>},
            {5000, 100, <<"download-deadline-exceeded">>}
        ]].

stalled_http_test(ReceiveTimeout, JobTimeout, Cause) ->
        {ok, _} = application:ensure_all_started(hackney),
        {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Listener),
        Parent = self(),
        Peer = spawn_link(fun() ->
            {ok, Socket} = gen_tcp:accept(Listener),
            {ok, _} = gen_tcp:recv(Socket, 0, 1000),
            ok = gen_tcp:send(Socket,
                <<"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\npartial">>),
            Parent ! {peer_closed, gen_tcp:recv(Socket, 0, 2000)},
            gen_tcp:close(Socket)
        end),
        Options = (andock_store_opts(#{<<"store-module">> => hb_store_gateway}))#{
            <<"http-client">> => hackney,
            <<"prometheus">> => false,
            <<"http-client-hackney-recv-timeout">> => ReceiveTimeout,
            <<"http-client-send-timeout">> => 5000
        },
        Fetch = fun() -> hb_http_client:request(#{
            peer => <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
            path => <<"/image">>, method => <<"GET">>, headers => #{}, body => <<>>
        }, Options) end,
        {Coordinator, Monitor} = spawn_monitor(fun() ->
            run_andock_materializer(Fetch, test_image_path(), JobTimeout, 100)
        end),
        try
            ?assertMatch({error, _, #{<<"cause">> := Cause}},
                poll_test_materializer(Coordinator, 2000)),
            receive {peer_closed, Closed} -> ?assertEqual({error, closed}, Closed)
            after 3000 -> error(connection_not_closed)
            end,
            receive {'DOWN', Monitor, process, Coordinator, normal} -> ok
            after 1000 -> error(cooldown_not_released)
            end
        after
            exit(Coordinator, kill),
            unlink(Peer),
            exit(Peer, kill),
            gen_tcp:close(Listener)
        end.

test_image_path() ->
    filename:join(<<"/tmp">>, <<"andock-test-",
        (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary,
        "/image.simg">>).

stop_test_process(Pid) ->
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, _} -> ok
    after 1000 -> error(test_process_not_stopped)
    end.

artifact_store_rewrites_only_remote_stores_test() ->
    Cache = #{<<"store-module">> => hb_store_fs, <<"name">> => <<"/tmp/cache">>},
    Stores = artifact_stores(
        [
            #{<<"store-module">> => hb_store_lmdb},
            #{<<"store-module">> => hb_store_arweave, <<"remote-index">> => true},
            #{<<"store-module">> => hb_store_gateway}
        ],
        Cache
    ),
    ?assertEqual([hb_store_arweave, hb_store_gateway], [
        maps:get(<<"store-module">>, Store) || Store <- Stores
    ]),
    ?assert(lists:all(
        fun(Store) -> maps:get(<<"local-store">>, Store) =:= Cache end,
        Stores
    )).

manifest_is_authenticated_by_its_id_test() ->
    ChunkID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    Manifest = #{
        <<"format">> => ?MODEL_MANIFEST_FORMAT,
        <<"model-bytes">> => 4,
        <<"chunks">> => [#{<<"id">> => ChunkID, <<"bytes">> => 4}]
    },
    ?assertEqual({ok, [{chunk, ChunkID, 4}]}, parse_manifest(Manifest, 4)).

arweave_transaction_data_is_the_artifact_payload_test() ->
    ?assertEqual(
        {ok, <<"artifact">>},
        body({ok, #{ <<"data">> => <<"artifact">> }}, #{})
    ).

chunked_model_uses_disk_backed_hb_cache_test() ->
    Root = filename:join(
        <<"/tmp">>,
        <<"andee-materialization-",
            (integer_to_binary(erlang:unique_integer([positive, monotonic])))/binary>>
    ),
    ArtifactRoot = filename:join(Root, <<"artifacts">>),
    ModelRoot = filename:join(Root, <<"models">>),
    Cache = #{
        <<"store-module">> => hb_store_fs,
        <<"name">> => filename:join(ArtifactRoot, <<"cache">>)
    },
    ManifestID = <<"MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM">>,
    Chunk1ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    Chunk2ID = <<"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB">>,
    Manifest = iolist_to_binary(hb_json:encode(#{
        <<"format">> => ?MODEL_MANIFEST_FORMAT,
        <<"model-bytes">> => 8,
        <<"chunks">> => [
            #{<<"id">> => Chunk1ID, <<"bytes">> => 4},
            #{<<"id">> => Chunk2ID, <<"bytes">> => 4}
        ]
    })),
    PreviousArtifactRoot = os:getenv(?ARTIFACT_CACHE_ROOT_ENV),
    PreviousModelRoot = os:getenv(?MODEL_ROOT_ENV),
    try
        true = os:putenv(?ARTIFACT_CACHE_ROOT_ENV, binary_to_list(ArtifactRoot)),
        true = os:putenv(?MODEL_ROOT_ENV, binary_to_list(ModelRoot)),
        ok = hb_store:start(Cache),
        ok = hb_store:write(
            Cache,
            #{
                ManifestID => Manifest,
                Chunk1ID => <<"abcd">>,
                Chunk2ID => <<"efgh">>
            },
            #{}
        ),
        RemoteStore = #{
            <<"store-module">> => hb_store_arweave,
            <<"index-store">> => Cache,
            <<"remote-index">> => true
        },
        Opts = #{
            <<"store">> => [RemoteStore],
            <<"inference-providers">> => #{
                <<"local-andee">> => #{
                    <<"models">> => [#{
                        <<"id">> => <<"test-model">>,
                        <<"model-id">> => ManifestID,
                        <<"bytes">> => 8,
                        <<"runtime">> => <<"litert-lm">>
                    }]
                }
            }
        },
        ?assertMatch(
            {ok, #{<<"id">> := ManifestID, <<"bytes">> := 8}},
            model(<<"local-andee">>, <<"test-model">>, Opts)
        ),
        ?assertEqual(
            {ok, <<"abcdefgh">>},
            file:read_file(filename:join(ModelRoot, <<ManifestID/binary, ".litertlm">>))
        )
    after
        restore_env(?ARTIFACT_CACHE_ROOT_ENV, PreviousArtifactRoot),
        restore_env(?MODEL_ROOT_ENV, PreviousModelRoot),
        file:del_dir_r(Root)
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

-endif.
