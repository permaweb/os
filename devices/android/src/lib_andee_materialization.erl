%%% @doc Materializes AO-Core model and image messages for Android backends.
-module(lib_andee_materialization).
-export([model/3, andock/2, andock_status/2]).
-ifdef(TEST).
-export([arweave/3]).
-endif.
-include_lib("kernel/include/file.hrl").

-define(MODEL_ROOT_ENV, "ANDEE_INFERENCE_MODEL_ROOT").
-define(ANDOCK_ROOT_ENV, "ANDEE_ANDOCK_IMAGE_ROOT").
-define(ARTIFACT_CACHE_ROOT_ENV, "ANDEE_ARTIFACT_CACHE_ROOT").
-define(MODEL_MANIFEST_FORMAT, <<"permawebos/andee-model/1">>).
-define(MAX_MODEL_MANIFEST_BYTES, 1024 * 1024).
-define(MAX_MODEL_CHUNKS, 128).
-define(ANDOCK_DEADLINE_MS, 2 * 60 * 60 * 1000).
-define(ANDOCK_RETRY_DELAY_MS, 60000).
-define(ANDOCK_STATUS_TIMEOUT_MS, 100).
-define(ANDOCK_CHUNK_BYTES, 256 * 1024).
-define(ANDOCK_RECEIPT_BYTES, 512 * 1024).
-define(ANDOCK_INDEXED_IMAGE, <<"rd2ybWz0XPr29kSWL2OYoTLmz7IhemE51XlsRseOSJk">>).
-define(ANDOCK_IMAGE_BLOCK, 1984725).

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

%% @doc Observe the existing image job without starting or retrying a download.
andock_status(ID, _Opts) when is_binary(ID), byte_size(ID) =:= 43 ->
    case {valid_id(ID), destination(?ANDOCK_ROOT_ENV, <<ID/binary, ".simg">>)} of
        {true, {ok, Path}} ->
            case existing(Path, positive) of
                {ok, Bytes} -> materialized(ID, Path, Bytes);
                missing ->
                    case whereis(andee_andock_materializer) of
                        undefined -> {error, 'andock-default-image-missing'};
                        Pid -> andock_materializer_status(Pid)
                    end;
                Error -> Error
            end;
        {false, _} -> {error, 'invalid-andock-image-id'};
        {_, Error} -> Error
    end;
andock_status(_, _) -> {error, 'invalid-andock-image-id'}.

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
            Coordinator = self(),
            ProgressRef = make_ref(),
            Fetch = fun() ->
                case existing(Path, positive) of
                    {ok, Bytes} -> materialized(ID, Path, Bytes);
                    missing ->
                        DownloadOpts = andock_download_opts(Opts),
                        case andock_prepare_index(ID, DownloadOpts) of
                            ok -> materialize_direct(ID, Path, andock_progress_opts(
                                ID, DownloadOpts, Coordinator, ProgressRef));
                            Error -> Error
                        end;
                    Error -> Error
                end
            end,
            run_andock_materializer(
                Fetch, Path, ?ANDOCK_DEADLINE_MS, ?ANDOCK_RETRY_DELAY_MS, ProgressRef
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
    {Deadline, Retries} = case Module of
        hb_store_arweave -> {60000, 2};
        hb_store_gateway -> {?ANDOCK_DEADLINE_MS, 0}
    end,
    Store#{
        <<"http-client-connect-timeout">> => 5000,
        <<"http-client-send-timeout">> => Deadline,
        <<"http-client-hackney-recv-timeout">> => 60000,
        <<"http-retry">> => Retries,
        <<"http-retry-response">> => [failure]
    };
andock_store_opts(Store) -> Store.

%% @doc Index the shipped image's block through its canonical owner before a
%% cold native read. The ID/block pair is fixed to the measured default image;
%% alternate images keep their operator-selected store behavior.
andock_prepare_index(ID, Opts) ->
    andock_prepare_index(ID, Opts, fun hb_ao:resolve/2).

andock_prepare_index(?ANDOCK_INDEXED_IMAGE = ID, Opts, Resolve) ->
    case andock_indexed_range(ID, Opts) of
        {ok, _, _} -> ok;
        unknown ->
            Block = integer_to_binary(?ANDOCK_IMAGE_BLOCK),
            case Resolve(<<"~copycat@1.0/arweave&from=", Block/binary,
                "&to=", Block/binary, "&mode=shallow&include-proofs=false">>, Opts) of
                {ok, _} ->
                    case andock_indexed_range(ID, Opts) of
                        {ok, _, _} -> ok;
                        unknown -> {error, 'andock-image-index-unavailable'}
                    end;
                {error, Reason} -> {error, Reason}
            end
    end;
andock_prepare_index(_ID, _Opts, _Resolve) -> ok.

%% @doc Observe the existing HTTP receipt hook only for an indexed image.
%% The private closure cannot be addressed through a public device action.
%% Received bytes are informational: canonical stores still verify the image.
andock_progress_opts(ID, Opts, Coordinator, Ref) ->
    case andock_indexed_range(ID, Opts) of
        {ok, Start, End} ->
            Coordinator ! {andock_progress, Ref, {range, Start, End}},
            Hook = <<"http-client-admissible-receipt">>,
            Existing = hb_hook:find(Hook, Opts),
            On = hb_opts:get(on, #{}, Opts),
            Observer = #{
                <<"path">> => <<"observe">>,
                <<"device">> => #{observe => fun(_Base, Req, HookOpts) ->
                    andock_chunk_receipt(Req, HookOpts, Coordinator, Ref),
                    {ok, Req}
                end}
            },
            Opts#{<<"on">> => On#{Hook => Existing ++ [Observer]}};
        unknown -> Opts
    end.

%% @doc Use the canonical local index; progress never makes a network lookup.
andock_indexed_range(ID, Opts) ->
    try hb_store_arweave:read_index_offset(
            hb_store_arweave:store_from_opts(Opts), ID) of
        {ok, #{<<"codec">> := <<"tx@1.0">>, <<"start">> := Start,
                <<"length">> := Length}}
                when is_integer(Start), Start >= 0, is_integer(Length), Length > 0 ->
            {ok, Start + 1, Start + Length};
        _ -> unknown
    catch _:_ -> unknown
    end.

andock_chunk_receipt(Req, Opts, Coordinator, Ref) ->
    try
        Receipt = hb_maps:get(<<"body">>, Req, Opts),
        <<"GET">> = hb_maps:get(<<"request-method">>, Receipt, Opts),
        Path = hb_maps:get(<<"request-path">>, Receipt, Opts),
        Offset = andock_chunk_offset(Path),
        Response = hb_maps:get(<<"response">>, Receipt, Opts),
        200 = hb_util:int(hb_maps:get(<<"status">>, Response, Opts)),
        Body = hb_maps:get(<<"body">>, Response, Opts),
        true = is_binary(Body) andalso byte_size(Body) =< ?ANDOCK_RECEIPT_BYTES,
        JSON = hb_json:decode(Body),
        Chunk = hb_util:decode(maps:get(<<"chunk">>, JSON)),
        Size = byte_size(Chunk),
        true = Size > 0 andalso Size =< ?ANDOCK_CHUNK_BYTES,
        End = hb_util:int(maps:get(<<"absolute_end_offset">>, JSON)),
        Start = End - Size + 1,
        true = Start >= 0 andalso Start =< Offset andalso Offset =< End,
        Coordinator ! {andock_progress, Ref, {chunk, Start, End}},
        ok
    catch _:_ -> ok
    end.

andock_chunk_offset(<<"/arweave/chunk/", Offset/binary>>) -> binary_to_integer(Offset);
andock_chunk_offset(<<"/chunk/", Offset/binary>>) -> binary_to_integer(Offset).

andock_progress({range, Start, End}, Progress) when not is_map_key(range, Progress) ->
    Progress#{range => {Start, End}, intervals => [], bytes => 0};
andock_progress({chunk, Start, End}, Progress = #{range := {First, Last}}) ->
    case {max(Start, First), min(End, Last)} of
        {From, To} when From =< To ->
            Intervals = andock_merge_intervals(
                lists:sort([{From, To} | maps:get(intervals, Progress)]), []),
            Bytes = lists:sum([B - A + 1 || {A, B} <- Intervals]),
            case Bytes > maps:get(bytes, Progress) of
                true -> Progress#{intervals => Intervals, bytes => Bytes,
                    last => erlang:monotonic_time(millisecond)};
                false -> Progress
            end;
        _ -> Progress
    end;
andock_progress(_, Progress) -> Progress.

andock_merge_intervals([], Acc) -> Acc;
andock_merge_intervals([{Start, End} | Rest], [{First, Last} | Acc])
        when Start =< Last + 1 ->
    andock_merge_intervals(Rest, [{First, max(End, Last)} | Acc]);
andock_merge_intervals([Interval | Rest], Acc) ->
    andock_merge_intervals(Rest, [Interval | Acc]).

andock_progress_details(#{range := {First, Last}, bytes := Bytes, last := LastProgress}) ->
    #{<<"downloaded-bytes">> => Bytes, <<"total-bytes">> => Last - First + 1,
        <<"last-progress-ms">> => elapsed(LastProgress)};
andock_progress_details(_) -> #{}.

%% @doc Keep a request-independent writer under a bounded lifetime and retain
%% its terminal failure so polling callers do not silently restart downloads.
run_andock_materializer(Fetch, Path, Timeout, RetryDelay, ProgressRef) ->
    process_flag(trap_exit, true),
    Started = erlang:monotonic_time(millisecond),
    Coordinator = self(),
    Writer = spawn_link(fun() -> Coordinator ! {andock_result, self(), Fetch()} end),
    {Result, Progress} = try
        await_andock_materializer(Writer, Started, Started + Timeout,
            #{ref => ProgressRef, last => Started})
    after
        unlink(Writer),
        exit(Writer, kill)
    end,
    case Result of
        {ok, _} -> ok;
        _ ->
            cleanup_andock_parts(Path),
            retain_andock_failure(Result, Started, RetryDelay, Progress)
    end.

%% @doc Polls do not extend the absolute deadline of the existing image job.
await_andock_materializer(Writer, Started, Deadline, Progress) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    await_andock_materializer(Writer, Started, Deadline, Progress, Remaining).

await_andock_materializer(Writer, _Started, _Deadline, Progress, 0) ->
    {stop_andock_writer(Writer), Progress};
await_andock_materializer(Writer, Started, Deadline, Progress = #{ref := Ref}, Remaining) ->
    receive
        {andock_status, Reply} ->
            Reply ! {Reply, {error, 'andock-default-image-materializing', maps:merge(#{
                <<"andock-image-state">> => <<"preparing">>,
                <<"andock-image-elapsed-ms">> => elapsed(Started)
            }, andock_progress_details(Progress))}},
            await_andock_materializer(Writer, Started, Deadline, Progress);
        {andock_progress, Ref, Update} ->
            await_andock_materializer(Writer, Started, Deadline,
                andock_progress(Update, Progress));
        {andock_progress, _OtherRef, _Update} ->
            await_andock_materializer(Writer, Started, Deadline, Progress);
        {andock_result, Writer, Result} -> {Result, Progress};
        {'EXIT', Writer, normal} -> {{error, 'image-worker-exited'}, Progress};
        {'EXIT', Writer, _Reason} -> {{error, 'image-worker-failed'}, Progress}
    after Remaining ->
        {stop_andock_writer(Writer), Progress}
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
retain_andock_failure(Result, Started, RetryDelay, Progress) ->
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
    retain_andock_failure_until(Error, erlang:monotonic_time(millisecond) + RetryDelay, Progress).

retain_andock_failure_until(Error, Until, Progress) ->
    Remaining = max(0, Until - erlang:monotonic_time(millisecond)),
    retain_andock_failure_until(Error, Until, Progress, Remaining).

retain_andock_failure_until(_Error, _Until, _Progress, 0) -> ok;
retain_andock_failure_until({error, Reason, Details} = Error, Until, Progress, Remaining) ->
    receive
        {andock_status, Reply} ->
            RetryIn = max(0, Until - erlang:monotonic_time(millisecond)),
            Reply ! {Reply, {error, Reason,
                maps:merge(Details#{<<"retry-after">> => (RetryIn + 999) div 1000},
                    andock_progress_details(Progress))}},
            retain_andock_failure_until(Error, Until, Progress)
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

%% A test-only copycat receiver: the real singleton parser and AO resolver must
%% deliver the range on Request. No network or installed node is involved.
arweave(_Base, Req, Opts) ->
    ?assertEqual(?ANDOCK_IMAGE_BLOCK, hb_util:int(maps:get(<<"from">>, Req))),
    ?assertEqual(?ANDOCK_IMAGE_BLOCK, hb_util:int(maps:get(<<"to">>, Req))),
    ?assertEqual(<<"shallow">>, maps:get(<<"mode">>, Req)),
    ?assertEqual(<<"false">>, maps:get(<<"include-proofs">>, Req)),
    ok = hb_store_arweave:write_offset(hb_store_arweave:store_from_opts(Opts),
        ?ANDOCK_INDEXED_IMAGE, <<"tx@1.0">>, 100, 100),
    {ok, ?ANDOCK_IMAGE_BLOCK}.

andock_index_request_reaches_existing_device_through_real_resolver_test() ->
    Root = filename:dirname(test_image_path()),
    Index = #{<<"store-module">> => hb_store_fs, <<"name">> => Root},
    Store = #{<<"store-module">> => hb_store_arweave, <<"index-store">> => Index},
    Key = {hb_device_load, <<"copycat@1.0">>},
    Previous = erlang:put(Key, ?MODULE),
    try
        ok = hb_store:start(Index),
        Opts = #{<<"store">> => [Store]},
        ?assertEqual(ok, andock_prepare_index(?ANDOCK_INDEXED_IMAGE, Opts)),
        ?assertEqual({ok, 101, 200}, andock_indexed_range(?ANDOCK_INDEXED_IMAGE, Opts))
    after
        case Previous of undefined -> erlang:erase(Key); _ -> erlang:put(Key, Previous) end,
        file:del_dir_r(Root)
    end.

andock_indexes_only_the_missing_shipped_image_test() ->
    Root = filename:dirname(test_image_path()),
    Index = #{<<"store-module">> => hb_store_fs, <<"name">> => Root},
    Store = #{<<"store-module">> => hb_store_arweave, <<"index-store">> => Index},
    Opts = #{<<"store">> => [Store]},
    Unexpected = fun(_, _) -> error(unexpected_index_request) end,
    try
        ok = hb_store:start(Index),
        ?assertEqual(ok, andock_prepare_index(
            <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>, Opts, Unexpected)),
        Seed = fun(Request, PassedOpts) ->
            ?assertEqual(Opts, PassedOpts),
            %% Exercise f76 singleton parsing, not a copy of its expected wire
            %% string: copycat reads these fields from Request, never Base.
            [{as, <<"copycat@1.0">>, Base}, Req] = hb_singleton:from(Request, Opts),
            ?assertNot(maps:is_key(<<"from">>, Base)),
            ?assertEqual(?ANDOCK_IMAGE_BLOCK, hb_util:int(maps:get(<<"from">>, Req))),
            ?assertEqual(?ANDOCK_IMAGE_BLOCK, hb_util:int(maps:get(<<"to">>, Req))),
            ?assertEqual(<<"shallow">>, maps:get(<<"mode">>, Req)),
            ?assertEqual(<<"false">>, maps:get(<<"include-proofs">>, Req)),
            ok = hb_store_arweave:write_offset(
                Store, ?ANDOCK_INDEXED_IMAGE, <<"tx@1.0">>, 100, 100),
            {ok, ?ANDOCK_IMAGE_BLOCK}
        end,
        ?assertEqual(ok, andock_prepare_index(?ANDOCK_INDEXED_IMAGE, Opts, Seed)),
        ?assertEqual(ok, andock_prepare_index(?ANDOCK_INDEXED_IMAGE, Opts, Unexpected)),
        %% The ordinary store read now selects its native offset without any
        %% remote-index/gateway request, including on the next preparation.
        ?assertMatch({ok, #{<<"start">> := 100, <<"length">> := 100,
            <<"codec">> := <<"tx@1.0">>}},
            hb_store_arweave:read_offset(Store, ?ANDOCK_INDEXED_IMAGE, #{}))
    after file:del_dir_r(Root)
    end.

andock_index_failure_never_falls_through_to_gateway_test() ->
    ?assertEqual({error, unavailable}, andock_prepare_index(?ANDOCK_INDEXED_IMAGE,
        #{}, fun(_, _) -> {error, unavailable} end)),
    ?assertEqual({error, 'andock-image-index-unavailable'},
        andock_prepare_index(?ANDOCK_INDEXED_IMAGE, #{},
            fun(_, _) -> {ok, ?ANDOCK_IMAGE_BLOCK} end)).

run_andock_materializer(Fetch, Path, Timeout, RetryDelay) ->
    run_andock_materializer(Fetch, Path, Timeout, RetryDelay, make_ref()).

retain_andock_failure(Result, Started, RetryDelay) ->
    retain_andock_failure(Result, Started, RetryDelay, #{}).

andock_progress_counts_union_and_preserves_stall_age_test() ->
    Initial = #{last => erlang:monotonic_time(millisecond) - 100},
    ?assertEqual(#{}, andock_progress_details(Initial)),
    P0 = andock_progress({range, 101, 200}, Initial),
    P1 = andock_progress({chunk, 90, 130}, P0),
    P2 = andock_progress({chunk, 120, 150}, P1),
    P3 = andock_progress({chunk, 180, 220}, P2),
    ?assertMatch(#{<<"downloaded-bytes">> := 71, <<"total-bytes">> := 100},
        andock_progress_details(P3)),
    ?assertEqual(P3, andock_progress({chunk, 120, 150}, P3)),
    ?assertEqual(P3, andock_progress({chunk, 300, 400}, P3)),
    P4 = andock_progress({chunk, 140, 190}, P3),
    ?assertMatch(#{<<"downloaded-bytes">> := 100}, andock_progress_details(P4)).

andock_receipt_ignores_unrelated_and_malformed_data_test() ->
    Ref = make_ref(),
    Receipt = test_chunk_receipt(101, 110, <<"ten-bytes!">>),
    ?assertEqual(ok, andock_chunk_receipt(#{<<"body">> => Receipt}, #{}, self(), Ref)),
    receive {andock_progress, Ref, {chunk, 101, 110}} -> ok
    after 100 -> error(no_chunk_observation)
    end,
    [andock_chunk_receipt(#{<<"body">> => Bad}, #{}, self(), Ref) || Bad <- [
        Receipt#{<<"request-method">> => <<"POST">>},
        Receipt#{<<"request-path">> => <<"/arweave/tx/other">>},
        Receipt#{<<"request-path">> => <<"/arweave/chunk/999">>},
        Receipt#{<<"response">> => #{<<"status">> => 503, <<"body">> => <<"{}">>}},
        Receipt#{<<"response">> => #{<<"status">> => 200, <<"body">> => <<"invalid">>}},
        Receipt#{<<"response">> => #{<<"status">> => 200,
            <<"body">> => binary:copy(<<"x">>, ?ANDOCK_RECEIPT_BYTES + 1)}},
        test_chunk_receipt(1, ?ANDOCK_CHUNK_BYTES + 1,
            binary:copy(<<"x">>, ?ANDOCK_CHUNK_BYTES + 1))
    ]],
    receive {andock_progress, Ref, _} -> error(unexpected_chunk_observation)
    after 0 -> ok
    end.

test_chunk_receipt(Offset, End, Chunk) ->
    #{<<"request-method">> => <<"GET">>,
        <<"request-path">> => <<"/arweave/chunk/", (integer_to_binary(Offset))/binary>>,
        <<"response">> => #{<<"status">> => 200,
            <<"body">> => iolist_to_binary(hb_json:encode(#{
                <<"chunk">> => hb_util:encode(Chunk),
                <<"absolute_end_offset">> => integer_to_binary(End)
            }))}}.

andock_progress_uses_only_canonical_index_and_preserves_hooks_test() ->
    Root = filename:dirname(test_image_path()),
    Index = #{<<"store-module">> => hb_store_fs, <<"name">> => Root},
    Store = #{<<"store-module">> => hb_store_arweave, <<"index-store">> => Index},
    ID = <<"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA">>,
    Hook = <<"http-client-admissible-receipt">>,
    Existing = #{<<"device">> => <<"existing-observer">>},
    Opts = #{<<"store">> => [Store], <<"on">> => #{Hook => Existing}},
    Ref = make_ref(),
    try
        ok = hb_store:start(Index),
        ?assertEqual(Opts, andock_progress_opts(ID, Opts, self(), Ref)),
        ok = hb_store_arweave:write_offset(Store, ID, <<"tx@1.0">>, 100, 100),
        ?assertEqual({ok, 101, 200}, andock_indexed_range(ID, Opts)),
        WithObserver = andock_progress_opts(ID, Opts, self(), Ref),
        [Existing, #{<<"device">> := #{observe := Observer}}] =
            hb_hook:find(Hook, WithObserver),
        receive {andock_progress, Ref, {range, 101, 200}} -> ok
        after 100 -> error(no_canonical_range)
        end,
        Req = #{<<"body">> => test_chunk_receipt(101, 110, <<"ten-bytes!">>)},
        ?assertEqual({ok, Req}, Observer(#{}, Req, #{})),
        receive {andock_progress, Ref, {chunk, 101, 110}} -> ok
        after 100 -> error(private_observer_failed)
        end
    after file:del_dir_r(Root)
    end.

andock_progress_is_job_scoped_and_retained_on_failure_test() ->
    Ref = make_ref(),
    {Coordinator, Monitor} = spawn_monitor(fun() ->
        run_andock_materializer(fun() -> receive finish -> {ok, done} end end,
            test_image_path(), 100, 150, Ref)
    end),
    try
        Coordinator ! {andock_progress, Ref, {range, 101, 200}},
        Coordinator ! {andock_progress, make_ref(), {chunk, 101, 200}},
        Coordinator ! {andock_progress, Ref, {chunk, 101, 125}},
        ?assertMatch({error, _, #{<<"downloaded-bytes">> := 25,
            <<"total-bytes">> := 100}}, andock_materializer_status(Coordinator)),
        timer:sleep(20),
        Coordinator ! {andock_progress, Ref, {chunk, 101, 125}},
        {error, _, #{<<"last-progress-ms">> := Age}} = andock_materializer_status(Coordinator),
        ?assert(Age >= 20),
        ?assertMatch({error, _, #{<<"downloaded-bytes">> := 25,
            <<"cause">> := <<"download-deadline-exceeded">>}},
            poll_test_materializer(Coordinator, 500)),
        receive {'DOWN', Monitor, process, Coordinator, normal} -> ok
        after 1000 -> error(cooldown_not_released)
        end
    after stop_test_process(Coordinator)
    end.

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

andock_retry_delay_counts_time_without_polls_test() ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! cooldown_started,
        retain_andock_failure({error, timeout}, erlang:monotonic_time(millisecond), 1100)
    end),
    try
        receive cooldown_started -> ok after 1000 -> error(no_cooldown) end,
        timer:sleep(250),
        ?assertMatch({error, _, #{<<"retry-after">> := 1}},
            andock_materializer_status(Pid)),
        receive {'DOWN', Monitor, process, Pid, normal} -> ok
        after 1500 -> error(cooldown_not_released)
        end
    after
        stop_test_process(Pid)
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
    ?assertEqual(2, maps:get(<<"http-retry">>, Arweave)),
    ?assertEqual(60000, maps:get(<<"http-client-send-timeout">>, Arweave)),
    ?assertEqual(?ANDOCK_DEADLINE_MS, maps:get(<<"http-client-send-timeout">>, Gateway)),
    ?assertEqual(60000, maps:get(<<"http-client-hackney-recv-timeout">>, Gateway)),
    ?assertEqual(0, maps:get(<<"http-retry">>, Gateway)).

andock_recovers_from_transient_chunk_response_test_() ->
    {timeout, 10, fun() ->
        {ok, _} = application:ensure_all_started(hackney),
        {ok, Listener} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
        {ok, Port} = inet:port(Listener),
        Parent = self(),
        Peer = spawn_link(fun() ->
            lists:foreach(fun({Status, Body}) ->
                {ok, Socket} = gen_tcp:accept(Listener),
                {ok, _} = gen_tcp:recv(Socket, 0, 1000),
                ok = gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, Status,
                    <<"\r\nConnection: close\r\nContent-Length: ">>,
                    integer_to_binary(byte_size(Body)), <<"\r\n\r\n">>, Body]),
                gen_tcp:close(Socket)
            end, [{<<"503 Unavailable">>, <<"retry">>}, {<<"200 OK">>, <<"chunk">>}]),
            Parent ! recovered
        end),
        Options = (andock_store_opts(#{<<"store-module">> => hb_store_arweave}))#{
            <<"http-client">> => hackney, <<"prometheus">> => false,
            <<"http-retry-time">> => 1
        },
        try
            ?assertMatch({ok, 200, _, <<"chunk">>}, hb_http_client:request(#{
                peer => <<"http://127.0.0.1:", (integer_to_binary(Port))/binary>>,
                path => <<"/chunk/1">>, method => <<"GET">>, headers => #{}, body => <<>>
            }, Options)),
            receive recovered -> ok after 1000 -> error(retry_not_received) end
        after
            unlink(Peer), exit(Peer, kill), gen_tcp:close(Listener)
        end
    end}.

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
