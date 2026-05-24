%%% @doc LapEE retention scheduler for completed bundler data items.
%%%
%%% The upstream bundler emits `bundled-message-complete' only after the bundle
%%% TX and chunks have completed. This hook records only item IDs plus cache
%%% paths and schedules a later GC pass, so the retention queue does not keep
%%% full dataitems alive.
%%%
%%% Purge is intentionally delete-only. If the active store cannot physically
%%% delete individual keys, we skip cleanup rather than writing tombstones or
%%% empty values that would satisfy future reads ahead of remote gateway stores.
-module(dev_lapee_bundler_gc).
-implements(<<"lapee-bundler-gc@1.0">>).
-export([info/1, bundled_message_complete/3, status/3]).

-include_lib("hb/include/hb.hrl").

-define(DEFAULT_RETENTION_MS, 15 * 60 * 1000).
-define(BUNDLER_PREFIX, <<"~bundler@1.0">>).

info(_) ->
    #{exports => [<<"bundled-message-complete">>, <<"status">>]}.

bundled_message_complete(_Base, Req, Opts) ->
    case {retention_ms(Opts), item_purge_targets(Req, Opts)} of
        {RetentionMs, {ok, ItemID, Targets}} when RetentionMs > 0 ->
            ensure_worker(Opts) !
                {
                    schedule,
                    ItemID,
                    RetentionMs,
                    Targets,
                    hb_opts:get(store, no_viable_store, Opts)
                },
            {ok, Req};
        _ ->
            {ok, Req}
    end.

status(_Base, _Req, Opts) ->
    Worker = ensure_worker(Opts),
    Ref = make_ref(),
    Worker ! {status, self(), Ref},
    receive
        {status, Ref, Status} ->
            {ok, #{<<"status">> => 200, <<"body">> => Status}}
    after 1000 ->
        {error, #{
            <<"status">> => 504,
            <<"body">> => <<"LapEE bundler GC status timed out.">>
        }}
    end.

ensure_worker(Opts) ->
    hb_name:singleton(server_name(Opts), fun() -> loop(initial_state(Opts)) end).

server_name(Opts) ->
    case hb_opts:get(priv_wallet, undefined, Opts) of
        undefined ->
            {?MODULE, hb_opts:get(port, default, Opts)};
        Wallet ->
            {?MODULE, hb_util:human_id(ar_wallet:to_address(Wallet))}
    end.

initial_state(Opts) ->
    #{
        items => #{},
        timer => undefined,
        scheduled => 0,
        expired => 0,
        failed => 0,
        last_error => undefined,
        retention_ms => retention_ms(Opts),
        purged_targets => 0,
        purge_mode => <<"delete-only-no-tombstones">>
    }.

loop(State) ->
    receive
        {schedule, ItemID, RetentionMs, Targets, Store} ->
            Now = erlang:monotonic_time(millisecond),
            Due = Now + RetentionMs,
            Items0 = maps:get(items, State),
            WasKnown = maps:is_key(ItemID, Items0),
            State1 =
                State#{
                    items =>
                        Items0#{
                            ItemID =>
                                #{
                                    due_at => Due,
                                    targets => Targets,
                                    store => Store
                                }
                        },
                    retention_ms => RetentionMs,
                    scheduled =>
                        maps:get(scheduled, State) + case WasKnown of
                            true -> 0;
                            false -> 1
                        end
                },
            loop(schedule_timer(State1));
        gc_tick ->
            loop(schedule_timer(expire_due(State)));
        {status, From, Ref} ->
            From ! {status, Ref, status_body(State)},
            loop(State);
        stop ->
            ok;
        _Other ->
            loop(State)
    end.

schedule_timer(State = #{items := Items, timer := Timer}) ->
    case is_reference(Timer) of
        true -> erlang:cancel_timer(Timer);
        false -> ok
    end,
    case next_due(Items) of
        none ->
            State#{timer => undefined};
        Due ->
            Delay = max(0, Due - erlang:monotonic_time(millisecond)),
            State#{timer => erlang:send_after(Delay, self(), gc_tick)}
    end.

next_due(Items) when map_size(Items) =:= 0 ->
    none;
next_due(Items) ->
    lists:min([maps:get(due_at, Entry) || Entry <- maps:values(Items)]).

expire_due(State = #{items := Items}) ->
    Now = erlang:monotonic_time(millisecond),
    {Due, Pending} =
        maps:fold(
            fun(ItemID, Entry, {DueAcc, PendingAcc}) ->
                case maps:get(due_at, Entry) =< Now of
                    true -> {[{ItemID, Entry} | DueAcc], PendingAcc};
                    false -> {DueAcc, PendingAcc#{ItemID => Entry}}
                end
            end,
            {[], #{}},
            Items
        ),
    expire_items(Due, State#{items => Pending}).

expire_items([], State) ->
    State;
expire_items([{_ItemID, Entry} | Rest], State) ->
    Targets = maps:get(targets, Entry),
    Store = maps:get(store, Entry),
    case purge_item(Targets, Store) of
        {ok, PurgedTargets} ->
            expire_items(
                Rest,
                State#{
                    expired => maps:get(expired, State) + 1,
                    purged_targets =>
                        maps:get(purged_targets, State) + PurgedTargets
                }
            );
        {error, Reason} ->
            expire_items(
                Rest,
                State#{
                    failed => maps:get(failed, State) + 1,
                    last_error => Reason
                }
            )
    end.

purge_item(Targets, no_viable_store) ->
    case map_size(Targets) of
        0 -> {ok, 0};
        _ -> {error, no_viable_store}
    end;
purge_item(Targets, Store) when map_size(Targets) =:= 0 ->
    _ = Store,
    {ok, 0};
purge_item(Targets, Store) ->
    purge_delete_stores(delete_capable_stores(Store), maps:keys(Targets)).

delete_capable_stores(no_viable_store) ->
    [];
delete_capable_stores(Stores) when is_list(Stores) ->
    [Store || Store <- Stores, delete_capable_store(Store)];
delete_capable_stores(Store) ->
    case delete_capable_store(Store) of
        true -> [Store];
        false -> []
    end.

delete_capable_store(#{<<"store-module">> := hb_store_fs}) -> true;
delete_capable_store(_) -> false.

purge_delete_stores([], _Paths) ->
    {ok, 0};
purge_delete_stores([Store | Rest], Paths) ->
    case purge_fs_targets(Store, Paths) of
        {ok, Count} ->
            case purge_delete_stores(Rest, Paths) of
                {ok, RestCount} -> {ok, Count + RestCount};
                Error -> Error
            end;
        Error ->
            Error
    end.

purge_fs_targets(Store, Paths) ->
    lists:foreach(
        fun(Path) ->
            FullPath = fs_add_prefix(Store, Path),
            case filelib:is_dir(FullPath) of
                true -> _ = file:del_dir_r(FullPath);
                false -> _ = file:delete(FullPath)
            end
        end,
        Paths
    ),
    {ok, length(Paths)}.

fs_add_prefix(#{<<"name">> := Prefix}, Path) ->
    Joined = hb_path:to_binary([Prefix, Path]),
    case is_abs_path(Prefix) andalso binary:first(Joined) =/= $/ of
        true -> <<"/", Joined/binary>>;
        false -> Joined
    end.

is_abs_path(Prefix) when is_binary(Prefix), byte_size(Prefix) > 0 ->
    binary:first(Prefix) =:= $/;
is_abs_path([$/ | _]) ->
    true;
is_abs_path(_) ->
    false.

status_body(State) ->
    #{
        <<"retention-ms">> => maps:get(retention_ms, State),
        <<"pending-items">> => map_size(maps:get(items, State)),
        <<"pending-purge-targets">> => pending_target_count(State),
        <<"scheduled-items">> => maps:get(scheduled, State),
        <<"retention-expired-items">> => maps:get(expired, State),
        <<"purged-targets">> => maps:get(purged_targets, State),
        <<"failed-items">> => maps:get(failed, State),
        <<"purge-mode">> => maps:get(purge_mode, State),
        <<"last-error">> => format_error(maps:get(last_error, State))
    }.

pending_target_count(State) ->
    maps:fold(
        fun(_ItemID, Entry, Count) ->
            Count + map_size(maps:get(targets, Entry))
        end,
        0,
        maps:get(items, State)
    ).

format_error(undefined) -> <<>>;
format_error(Reason) -> hb_util:bin(io_lib:format("~0p", [Reason])).

item_purge_targets(Req, Opts) ->
    case hb_maps:get(<<"body">>, Req, undefined, Opts) of
        Item when is_map(Item) ->
            try
                ItemID = hb_message:id(Item, signed, Opts),
                CacheTargets = cache_purge_targets(Item, Opts),
                {ok,
                    ItemID,
                    CacheTargets#{
                        item_path(ItemID, Opts) => <<>>
                    }}
            catch _:_ -> error
            end;
        _ ->
            error
    end.

item_path(ItemID, _Opts) ->
    hb_path:to_binary([
        ?BUNDLER_PREFIX,
        <<"item">>,
        ItemID,
        <<"bundle">>
    ]).

cache_purge_targets(RawMsg, Opts) when is_map(RawMsg) ->
    {ok, Msg} = hb_message:with_only_committed(RawMsg, Opts),
    TABM = hb_message:convert(Msg, tabm, <<"structured@1.0">>, Opts),
    maps:from_list([{Path, <<>>} || Path <- collect_cache_paths(TABM, Opts)]);
cache_purge_targets(RawMsg, Opts) ->
    maps:from_list([{Path, <<>>} || Path <- collect_cache_paths(RawMsg, Opts)]).

collect_cache_paths(Bin, Opts) when is_binary(Bin) ->
    [<<"data/", (hb_path:hashpath(Bin, Opts))/binary>>];
collect_cache_paths(List, Opts) when is_list(List) ->
    collect_cache_paths(
        hb_message:convert(List, tabm, <<"structured@1.0">>, Opts),
        Opts
    );
collect_cache_paths(Msg, Opts) when is_map(Msg) ->
    UncommittedID = hb_message:id(
        Msg,
        none,
        Opts#{<<"linkify-mode">> => discard}
    ),
    AllIDs = calculate_all_ids(Msg, Opts),
    AltIDs = AllIDs -- [UncommittedID],
    MsgHashpathAlg = hb_path:hashpath_alg(Msg, Opts),
    MessagePaths = [UncommittedID | AltIDs],
    KeyPaths =
        lists:flatmap(
            fun({Key, Value}) ->
                collect_key_paths(
                    UncommittedID,
                    Key,
                    MsgHashpathAlg,
                    Value,
                    Opts
                )
            end,
            maps:to_list(maps:without([<<"priv">>], Msg))
        ),
    lists:usort(MessagePaths ++ KeyPaths).

collect_key_paths(Base, <<"commitments">>, _HPAlg, RawCommitments, Opts) ->
    Commitments = prepare_commitments(RawCommitments, Opts),
    CommitmentsBase = commitment_path(Base, Opts),
    CommitmentPaths =
        lists:flatmap(
            fun({BaseCommID, Commitment}) ->
                collect_cache_paths(Commitment, Opts) ++
                    [<<CommitmentsBase/binary, "/", BaseCommID/binary>>]
            end,
            maps:to_list(Commitments)
        ),
    [
        CommitmentsBase,
        <<Base/binary, "/commitments">>
        | CommitmentPaths
    ];
collect_key_paths(Base, Key, HPAlg, Value, Opts) ->
    KeyHashPath =
        hb_path:hashpath(
            Base,
            hb_path:to_binary(Key),
            HPAlg,
            Opts
        ),
    [KeyHashPath | collect_cache_paths(Value, Opts)].

prepare_commitments(RawCommitments, Opts) ->
    Commitments = hb_cache:ensure_all_loaded(RawCommitments, Opts),
    maps:map(
        fun(_, StructuredCommitment) ->
            hb_message:convert(StructuredCommitment, tabm, Opts)
        end,
        Commitments
    ).

commitment_path(Base, Opts) ->
    hb_path:hashpath(<<Base/binary, "/commitments">>, Opts).

calculate_all_ids(Bin, _Opts) when is_binary(Bin) ->
    [];
calculate_all_ids(Msg, Opts) ->
    Commitments =
        hb_maps:without(
            [<<"priv">>],
            hb_maps:get(<<"commitments">>, Msg, #{}, Opts),
            Opts
        ),
    CommIDs = hb_maps:keys(Commitments, Opts),
    All = hb_message:id(Msg, all, Opts#{<<"linkify-mode">> => discard}),
    case lists:member(All, CommIDs) of
        true -> CommIDs;
        false -> [All | CommIDs]
    end.

retention_ms(Opts) ->
    opt_int(
        lapee_bundler_completed_item_retention_ms,
        ?DEFAULT_RETENTION_MS,
        Opts
    ).

opt_int(Key, Default, Opts) ->
    try hb_util:int(hb_opts:get(Key, Default, Opts))
    catch _:_ -> Default
    end.
