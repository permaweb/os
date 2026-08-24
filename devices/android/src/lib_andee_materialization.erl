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
-define(MODEL_STATUS_TIMEOUT_MS, 100).
-define(MODEL_FAILURE_TIMEOUT_MS, 60000).

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
        #{id := ID, extension := Extension} = Spec,
        Opts
    ) ->
    case destination(?MODEL_ROOT_ENV, <<ID/binary, Extension/binary>>) of
        {ok, Path} ->
            ensure_model(Spec, Path, Opts);
        Error -> Error
    end.

%% @doc Start one request-independent materializer for a missing model. Large
%% models can take longer than an HTTP or tunnel request is allowed to live, so
%% the writer must not share the request process's lifetime.
ensure_model(#{bytes := Bytes} = Spec, Path, Opts) ->
    case existing(Path, Bytes) of
        {ok, Bytes} ->
            materialized_model(Spec, Path);
        missing ->
            start_model_materializer(Spec, Path, Opts);
        Error -> Error
    end.

%% @doc Deduplicate background writers by their deterministic destination.
start_model_materializer(#{bytes := Bytes} = Spec, Path, Opts) ->
    case existing(Path, Bytes) of
        {ok, Bytes} ->
            materialized_model(Spec, Path);
        missing ->
            Name = {?MODULE, node(), model, Path},
            case global:whereis_name(Name) of
                undefined ->
                    spawn(fun() -> model_materializer(Name, Spec, Path, Opts) end),
                    {error, 'inference-model-materializing'};
                Pid ->
                    model_materializer_status(Pid)
            end;
        Error -> Error
    end.

%% @doc Resolve and atomically write the model outside the caller's lifetime.
model_materializer(Name, #{id := ID, bytes := Bytes} = Spec, Path, Opts) ->
    case global:register_name(Name, self()) of
        yes ->
            try
                process_flag(trap_exit, true),
                Materializer = self(),
                Writer = spawn_link(fun() ->
                    Materializer ! {
                        model_materializer_result,
                        self(),
                        materialize_model_parts(ID, Bytes, Spec, Path, Opts)
                    }
                end),
                coordinate_model_materializer(Writer)
            after
                global:unregister_name(Name)
            end;
        no ->
            ok
    end.

%% @doc Resolve and write the model in a child linked to its registered
%% coordinator, so killing the coordinator cannot leave an unowned writer.
materialize_model_parts(ID, Bytes, Spec, Path, Opts) ->
    cleanup_model_parts(Path),
    case existing(Path, Bytes) of
        {ok, Bytes} -> materialized_model(Spec, Path);
        missing ->
            case model_parts(ID, Bytes, Opts) of
                {ok, Parts} -> write_model_parts(ID, Path, Bytes, Parts, Opts);
                Error -> Error
            end;
        Error -> Error
    end.

%% @doc Answer progress polls while the writer performs blocking cache reads.
coordinate_model_materializer(Writer) ->
    receive
        {model_materializer_status, From, Ref} ->
            From ! {Ref, {error, 'inference-model-materializing'}},
            coordinate_model_materializer(Writer);
        {model_materializer_result, Writer, Result} ->
            unlink(Writer),
            retain_model_failure(Result);
        {'EXIT', Writer, _Reason} ->
            retain_model_failure(
                {error, 'inference-model-materialization-failed'}
            )
    end.

%% @doc Return the registered coordinator's current progress or failure result.
model_materializer_status(Pid) ->
    Monitor = monitor(process, Pid),
    Ref = make_ref(),
    Pid ! {model_materializer_status, self(), Ref},
    receive
        {Ref, Result} ->
            demonitor(Monitor, [flush]),
            Result;
        {'DOWN', Monitor, process, Pid, _Reason} ->
            {error, 'inference-model-materializing'}
    after ?MODEL_STATUS_TIMEOUT_MS ->
        demonitor(Monitor, [flush]),
        {error, 'inference-model-materializing'}
    end.

%% @doc Keep a failed result only long enough for a retrying request to observe
%% it. Once reported (or expired), the next request may start a fresh writer.
retain_model_failure({error, _} = Error) ->
    receive
        {model_materializer_status, From, Ref} ->
            From ! {Ref, Error},
            ok
    after ?MODEL_FAILURE_TIMEOUT_MS ->
        ok
    end;
retain_model_failure(Result) ->
    Result.

%% @doc Remove abandoned temporary files only when no writer owns this path.
cleanup_model_parts(Path) ->
    Pattern = binary_to_list(<<Path/binary, ".*.part">>),
    lists:foreach(fun file:delete/1, filelib:wildcard(Pattern)).

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
    with_lock(
        Path,
        fun() ->
            case existing(Path, positive) of
                {ok, Bytes} ->
                    materialized(ID, Path, Bytes);
                missing ->
                    case whereis(andee_andock_materializer) of
                        undefined ->
                            Pid = spawn(fun() ->
                                receive
                                    materialize -> materialize_direct(ID, Path, Opts)
                                end
                            end),
                            true = register(andee_andock_materializer, Pid),
                            Pid ! materialize,
                            {error, 'andock-default-image-materializing'};
                        _ ->
                            {error, 'andock-default-image-materializing'}
                    end;
                Error -> Error
            end
        end
    ).

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
        Destination = filename:join(ModelRoot, <<ManifestID/binary, ".litertlm">>),
        StalePart = <<Destination/binary, ".1.part">>,
        ok = filelib:ensure_dir(StalePart),
        ok = file:write_file(StalePart, <<"stale">>),
        ?assertEqual(
            {error, 'inference-model-materializing'},
            model(<<"local-andee">>, <<"test-model">>, Opts)
        ),
        ?assertMatch(
            {ok, #{<<"id">> := ManifestID, <<"bytes">> := 8}},
            wait_for_model(<<"local-andee">>, <<"test-model">>, Opts, 100)
        ),
        ?assertEqual(false, filelib:is_file(StalePart)),
        ?assertEqual(
            {ok, <<"abcdefgh">>},
            file:read_file(Destination)
        ),
        Providers = maps:get(<<"inference-providers">>, Opts),
        Provider = maps:get(<<"local-andee">>, Providers),
        [ConfiguredModel] = maps:get(<<"models">>, Provider),
        InvalidOpts = Opts#{
            <<"inference-providers">> => Providers#{
                <<"local-andee">> => Provider#{
                    <<"models">> => [ConfiguredModel#{<<"bytes">> => 9}]
                }
            }
        },
        ?assertEqual(
            {error, 'inference-model-materializing'},
            model(<<"local-andee">>, <<"test-model">>, InvalidOpts)
        ),
        ?assertEqual(
            {error, 'model-byte-length-mismatch'},
            wait_for_model(<<"local-andee">>, <<"test-model">>, InvalidOpts, 100)
        )
    after
        restore_env(?ARTIFACT_CACHE_ROOT_ENV, PreviousArtifactRoot),
        restore_env(?MODEL_ROOT_ENV, PreviousModelRoot),
        file:del_dir_r(Root)
    end.

wait_for_model(_Provider, _Model, _Opts, 0) ->
    {error, timeout};
wait_for_model(Provider, Model, Opts, Attempts) ->
    case model(Provider, Model, Opts) of
        {error, 'inference-model-materializing'} ->
            timer:sleep(10),
            wait_for_model(Provider, Model, Opts, Attempts - 1);
        Result -> Result
    end.

restore_env(Name, false) -> os:unsetenv(Name);
restore_env(Name, Value) -> os:putenv(Name, Value).

-endif.
