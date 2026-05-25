%%% @doc Zone-unsealed encrypted non-volatile store for AndEE.
%%%
%%% The store keeps HyperBEAM's normal `hb_store' interface at the boundary,
%%% keeps live state in ETS, and persists encrypted append-only operation log
%%% records under app-private storage. The zone AES secret is registered in
%%% memory by `dev_zone' after successful measurement/secret-recipient
%%% admission; it is never placed in the store message itself.
-module(hb_store_andee_encrypted).

-export([register_secret/2, forget_secret/1, flush/1]).
-export([start/3, stop/3, reset/3, scope/0, scope/1]).
-export([write/3, read/3, list/3, type/3, link/3, group/3, resolve/3]).

-include_lib("hb/include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ROOT_GROUP, <<"/">>).
-define(DATA_FILE, <<"store.bin">>).
-define(HEAD_FILE, <<"store.head">>).
-define(MAGIC, <<"andee-encrypted-store-log-v1">>).
-define(HEAD_MAGIC, <<"andee-encrypted-store-head-v1">>).
-define(MAX_REDIRECTS, 32).
-define(DEFAULT_FLUSH_INTERVAL_MS, 50).

register_secret(SecretRef, AES) when is_binary(SecretRef), byte_size(AES) =:= 32 ->
    persistent_term:put(secret_term(SecretRef), AES),
    ok.

forget_secret(SecretRef) when is_binary(SecretRef) ->
    try persistent_term:erase(secret_term(SecretRef))
    catch error:badarg -> ok
    end.

start(StoreOpts = #{<<"name">> := _Name}, _Req, _NodeOpts) ->
    DataFile = data_file(StoreOpts),
    ok = filelib:ensure_dir(DataFile),
    case load_log(StoreOpts, DataFile) of
        {ok, Entries, NextSeq, ValidBytes, Tip} ->
            case truncate_log(DataFile, ValidBytes) of
                ok ->
                    Parent = self(),
                    {Pid, MonitorRef} = spawn_monitor(fun() ->
                        Table = ets:new(?MODULE, [
                            set,
                            public,
                            {read_concurrency, true},
                            {write_concurrency, true}
                        ]),
                        maps:foreach(
                            fun(Key, Entry) ->
                                ets:insert(Table, {Key, Entry})
                            end,
                            ensure_root_group(Entries)
                        ),
                        case file:open(DataFile, [append, binary, raw]) of
                            {ok, Fd} ->
                                Parent ! {ok, self(), #{
                                    <<"pid">> => self(),
                                    <<"ets-table">> => Table
                                }},
                                owner_loop(#{
                                    opts => StoreOpts,
                                    fd => Fd,
                                    next_seq => NextSeq,
                                    bytes => ValidBytes,
                                    tip => Tip,
                                    pending => [],
                                    timer => undefined
                                });
                            {error, Reason} ->
                                Parent ! {error, self(), Reason}
                        end
                    end),
                    receive
                        {ok, Pid, InstanceMessage} ->
                            erlang:demonitor(MonitorRef, [flush]),
                            {ok, InstanceMessage};
                        {error, Pid, Reason} ->
                            erlang:demonitor(MonitorRef, [flush]),
                            {failure, Reason};
                        {'DOWN', MonitorRef, process, Pid, Reason} ->
                            {failure, Reason}
                    after 5000 ->
                        exit(Pid, kill),
                        {failure, encrypted_store_start_timeout}
                    end;
                {error, Reason} ->
                    {failure, Reason}
            end;
        {error, Reason} ->
            {failure, Reason}
    end.

stop(Opts, _Req, _NodeOpts) ->
    #{<<"pid">> := Pid} = hb_store:find(Opts),
    Pid ! {stop, self(), Ref = make_ref()},
    receive
        {ok, Ref} -> ok;
        {error, Ref, Reason} -> {error, Reason}
    after 5000 ->
        ok
    end.

reset(Opts, _Req, _NodeOpts) ->
    #{<<"ets-table">> := Table} = hb_store:find(Opts),
    ets:delete_all_objects(Table),
    ets:insert(Table, {?ROOT_GROUP, {group, []}}),
    append_op(Opts, reset),
    ok.

flush(Opts) ->
    #{<<"pid">> := Pid} = hb_store:find(Opts),
    Pid ! {flush, self(), Ref = make_ref()},
    receive
        {ok, Ref} -> ok;
        {error, Ref, Reason} -> {error, Reason}
    after 5000 ->
        {error, flush_timeout}
    end.

scope() -> local.
scope(_) -> scope().

write(Opts, Req, _NodeOpts) when is_map(Req) ->
    maps:fold(
        fun(Key, Value, ok) ->
            write_path(Opts, Key, Value);
           (_Key, _Value, Error) ->
            Error
        end,
        ok,
        Req
    ).

read(Opts, #{<<"read">> := RawKey}, _NodeOpts) ->
    read_path(Opts, RawKey).

list(Opts, #{<<"list">> := RawPath}, _NodeOpts) ->
    list_path(Opts, RawPath).

type(Opts, #{<<"type">> := RawKey}, _NodeOpts) ->
    type_path(Opts, RawKey).

group(Opts, #{<<"group">> := RawKey}, _NodeOpts) ->
    Key = hb_path:to_binary(RawKey),
    #{<<"ets-table">> := Table} = hb_store:find(Opts),
    ensure_dir(Table, Key),
    append_op(Opts, {group, Key}),
    ok.

link(Opts, Req, _NodeOpts) when is_map(Req) ->
    maps:fold(
        fun(NewPath, ExistingPath, ok) ->
            link_path(Opts, NewPath, ExistingPath);
           (_NewPath, _ExistingPath, Error) ->
            Error
        end,
        ok,
        Req
    ).

resolve(Opts, #{<<"resolve">> := Key}, _NodeOpts) ->
    {ok, resolve_path(Opts, Key)}.

owner_loop(State) ->
    receive
        {stop, From, Ref} ->
            _ = maybe_cancel_timer(maps:get(timer, State)),
            case flush_pending(State) of
                {ok, FlushedState} ->
                    file:close(maps:get(fd, FlushedState)),
                    From ! {ok, Ref},
                    exit(normal);
                {{error, Reason}, FlushedState} ->
                    file:close(maps:get(fd, FlushedState)),
                    From ! {error, Ref, Reason},
                    exit({encrypted_store_flush_failed, Reason})
            end;
        {append, Op} ->
            owner_loop(schedule_flush(
                State#{pending := [Op | maps:get(pending, State)]}
            ));
        flush ->
            case flush_pending(State) of
                {ok, FlushedState} ->
                    owner_loop(FlushedState);
                {{error, Reason}, FlushedState} ->
                    exit({encrypted_store_flush_failed, Reason, FlushedState})
            end;
        {flush, From, Ref} ->
            case flush_pending(State) of
                {ok, FlushedState} ->
                    From ! {ok, Ref},
                    owner_loop(FlushedState);
                {{error, Reason}, FlushedState} ->
                    From ! {error, Ref, Reason},
                    exit({encrypted_store_flush_failed, Reason, FlushedState})
            end;
        _ ->
            owner_loop(State)
    end.

write_path(Opts, RawKey, Value) ->
    Key = hb_path:to_binary(RawKey),
    #{<<"ets-table">> := Table} = hb_store:find(Opts),
    ensure_parent_groups(Table, Key),
    ets:insert(Table, {Key, {raw, Value}}),
    append_op(Opts, {write, Key, Value}),
    ok.

read_path(Opts, RawKey) ->
    read_resolved(Opts, resolve_path(Opts, RawKey), 0).

read_resolved(_Opts, _Key, Depth) when Depth > ?MAX_REDIRECTS ->
    {error, not_found};
read_resolved(Opts, Key, Depth) ->
    case lookup_entry(Opts, Key) of
        {raw, Value} ->
            {ok, Value};
        {group, Children} ->
            {composite, Children};
        {link, Link} ->
            read_resolved(Opts, hb_path:to_binary(Link), Depth + 1);
        _ ->
            {error, not_found}
    end.

list_path(Opts, RawPath) ->
    Path =
        case hb_path:to_binary(RawPath) of
            <<"">> -> ?ROOT_GROUP;
            <<"/">> -> ?ROOT_GROUP;
            Other -> resolve_path(Opts, Other)
        end,
    case lookup_entry(Opts, Path) of
        {group, Children} ->
            {ok, Children};
        {link, Link} ->
            list_path(Opts, Link);
        {raw, Value} when is_map(Value) ->
            {ok, maps:keys(Value)};
        {raw, Value} when is_list(Value) ->
            {ok, Value};
        _ ->
            {error, not_found}
    end.

type_path(Opts, RawKey) ->
    Key = resolve_path(Opts, RawKey),
    case lookup_entry(Opts, Key) of
        {raw, _} -> {ok, simple};
        {group, _} -> {ok, composite};
        {link, Link} -> type_path(Opts, Link);
        _ -> {error, not_found}
    end.

link_path(_Opts, LinkPath, LinkPath) ->
    ok;
link_path(Opts, RawNew, RawExisting) ->
    New = hb_path:to_binary(RawNew),
    Existing = hb_path:to_binary(RawExisting),
    #{<<"ets-table">> := Table} = hb_store:find(Opts),
    ensure_parent_groups(Table, New),
    ets:insert(Table, {New, {link, Existing}}),
    append_op(Opts, {link, New, Existing}),
    ok.

resolve_path(Opts, Key) ->
    case hb_path:to_binary(Key) of
        <<"/">> -> ?ROOT_GROUP;
        <<"">> -> ?ROOT_GROUP;
        Path ->
            resolve_path(
                Opts,
                <<>>,
                hb_path:term_to_path_parts(Path, Opts),
                0
            )
    end.

resolve_path(_Opts, CurrPath, [], _Depth) ->
    hb_path:to_binary(CurrPath);
resolve_path(_Opts, CurrPath, _Rest, Depth) when Depth > ?MAX_REDIRECTS ->
    hb_path:to_binary(CurrPath);
resolve_path(Opts, CurrPath, [Next | Rest], Depth) ->
    PathPart = join_path(CurrPath, Next),
    case lookup_entry(Opts, PathPart) of
        {link, Link} ->
            resolve_path(Opts, hb_path:to_binary(Link), Rest, Depth + 1);
        _ ->
            resolve_path(Opts, PathPart, Rest, Depth)
    end.

lookup_entry(Opts, Key) when is_map(Opts) ->
    #{<<"ets-table">> := Table} = hb_store:find(Opts),
    lookup_entry(Table, Key);
lookup_entry(Table, Key) ->
    case ets:lookup(Table, Key) of
        [{_, Entry}] -> Entry;
        [] -> nil
    end.

ensure_parent_groups(Table, Key) ->
    case filename:dirname(Key) of
        <<".">> ->
            add_group_child(Table, ?ROOT_GROUP, filename:basename(Key));
        ParentDir ->
            ensure_dir(Table, ParentDir),
            add_group_child(Table, ParentDir, filename:basename(Key))
    end.

ensure_dir(Table, RawPath) ->
    case hb_path:to_binary(RawPath) of
        <<"/">> ->
            ensure_group(Table, ?ROOT_GROUP);
        <<"">> ->
            ensure_group(Table, ?ROOT_GROUP);
        Path ->
            ensure_dir(Table, ?ROOT_GROUP, hb_path:term_to_path_parts(Path))
    end.

ensure_dir(_Table, _CurrentGroup, []) ->
    ok;
ensure_dir(Table, CurrentGroup, [Next | Rest]) ->
    add_group_child(Table, CurrentGroup, Next),
    NextGroup = next_group_path(CurrentGroup, Next),
    ensure_group(Table, NextGroup),
    ensure_dir(Table, NextGroup, Rest).

ensure_group(Table, Key) ->
    case lookup_entry(Table, Key) of
        {group, _} -> ok;
        _ -> ets:insert(Table, {Key, {group, []}})
    end.

add_group_child(Table, Group, Child) ->
    ensure_group(Table, Group),
    {group, Children} = lookup_entry(Table, Group),
    ets:insert(Table, {Group, {group, lists:usort([Child | Children])}}),
    ok.

next_group_path(?ROOT_GROUP, Next) ->
    hb_path:to_binary(Next);
next_group_path(CurrentGroup, Next) ->
    hb_path:to_binary([CurrentGroup, Next]).

join_path(<<>>, Next) ->
    hb_path:to_binary(Next);
join_path(CurrPath, Next) ->
    hb_path:to_binary([CurrPath, Next]).

append_op(Opts, Op) ->
    #{<<"pid">> := Pid} = hb_store:find(Opts),
    Pid ! {append, Op},
    ok.

schedule_flush(State = #{timer := undefined}) ->
    case flush_interval_ms(maps:get(opts, State)) of
        0 ->
            self() ! flush,
            State;
        Interval ->
            State#{timer := erlang:send_after(Interval, self(), flush)}
    end;
schedule_flush(State) ->
    State.

flush_interval_ms(Opts) ->
    hb_util:int(hb_maps:get(
        <<"flush-interval-ms">>,
        Opts,
        ?DEFAULT_FLUSH_INTERVAL_MS,
        #{}
    )).

flush_pending(State = #{pending := [], timer := Timer}) ->
    maybe_cancel_timer(Timer),
    {ok, State#{timer := undefined}};
flush_pending(State = #{opts := Opts, fd := Fd, pending := Pending0,
                        next_seq := Seq0, bytes := Bytes0, tip := Tip0}) ->
    maybe_cancel_timer(maps:get(timer, State)),
    Pending = lists:reverse(Pending0),
    {IOData, {NextSeq, Bytes, Tip}} =
        lists:mapfoldl(
            fun(Op, {Seq, Offset, PrevTip}) ->
                {Record, NextTip} = encode_log_record(Opts, Seq, PrevTip, Op),
                {[Record], {Seq + 1, Offset + iolist_size(Record), NextTip}}
            end,
            {Seq0, Bytes0, Tip0},
            Pending
        ),
    case file:write(Fd, IOData) of
        ok ->
            case sync_before_head(Fd, Opts) of
                ok ->
                    case write_head(Opts, Bytes, NextSeq, Tip) of
                        ok ->
                            {ok, State#{
                                pending := [],
                                timer := undefined,
                                next_seq := NextSeq,
                                bytes := Bytes,
                                tip := Tip
                            }};
                        {error, Reason} ->
                            {{error, Reason}, State}
                    end;
                {error, Reason} ->
                    {{error, Reason}, State}
            end;
        {error, Reason} ->
            {{error, Reason}, State}
    end.

maybe_cancel_timer(undefined) ->
    ok;
maybe_cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    ok.

sync_before_head(Fd, _Opts) ->
    file:sync(Fd).

encode_log_record(Opts, Seq, PrevTip, Op) ->
    Frame = encode_log_frame(Opts, Seq, PrevTip, Op),
    FrameLen = byte_size(Frame),
    Record = [<<FrameLen:32/unsigned-big-integer>>, Frame],
    {Record, log_tip(PrevTip, Record)}.

encode_log_frame(Opts, Seq, PrevTip, Op) ->
    Plain = term_to_binary(#{
        <<"version">> => 1,
        <<"seq">> => Seq,
        <<"prev-tip">> => PrevTip,
        <<"op">> => Op
    }, [compressed]),
    IV = crypto:strong_rand_bytes(12),
    AAD = aad(Opts, Seq, PrevTip),
    {CipherText, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            store_key(Opts),
            IV,
            Plain,
            AAD,
            true
        ),
    term_to_binary(#{
        <<"magic">> => ?MAGIC,
        <<"version">> => 1,
        <<"seq">> => Seq,
        <<"iv">> => IV,
        <<"tag">> => Tag,
        <<"ciphertext">> => CipherText
    }).

load_log(Opts, File) ->
    Head = load_head(head_file(Opts)),
    case file:read_file(File) of
        {error, enoent} ->
            reconcile_empty_log(Opts, Head);
        {ok, Bin} ->
            reconcile_log(Opts, Head, Bin);
        {error, Reason} ->
            {error, Reason}
    end.

truncate_log(File, ValidBytes) ->
    case file:open(File, [read, write, binary, raw]) of
        {ok, Fd} ->
            {ok, ValidBytes} = file:position(Fd, ValidBytes),
            ok = file:truncate(Fd),
            file:close(Fd);
        {error, enoent} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

replay_log(Opts, Bin) ->
    replay_log(Opts, Bin, #{}, 0, 0, empty_tip(Opts)).

replay_log(_Opts, <<>>, Entries, LastSeq, Offset, Tip) ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset, Tip};
replay_log(_Opts, Bin, Entries, LastSeq, Offset, Tip) when byte_size(Bin) < 4 ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset, Tip};
replay_log(_Opts, <<Len:32/unsigned-big-integer, Rest/binary>>, Entries, LastSeq,
        Offset, Tip)
        when byte_size(Rest) < Len ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset, Tip};
replay_log(Opts, <<Len:32/unsigned-big-integer, Frame:Len/binary, Rest/binary>>,
        Entries, LastSeq, Offset, Tip) ->
    case decrypt_log_frame(Opts, Tip, Frame) of
        {ok, Seq, Op} when Seq =:= LastSeq + 1 ->
            Record = <<Len:32/unsigned-big-integer, Frame/binary>>,
            NextTip = log_tip(Tip, Record),
            replay_log(
                Opts,
                Rest,
                apply_logged_op(Op, Entries),
                max(Seq, LastSeq),
                Offset + 4 + Len,
                NextTip
            );
        {ok, Seq, _Op} ->
            {error, {bad_encrypted_store_log_sequence, LastSeq, Seq}};
        {error, _} = Error ->
            Error
    end.

decrypt_log_frame(Opts, PrevTip, Bin) ->
    try binary_to_term(Bin, [safe]) of
        #{
            <<"magic">> := ?MAGIC,
            <<"version">> := 1,
            <<"seq">> := Seq,
            <<"iv">> := IV,
            <<"tag">> := Tag,
            <<"ciphertext">> := CipherText
        } ->
            case crypto:crypto_one_time_aead(
                aes_256_gcm,
                store_key(Opts),
                IV,
                CipherText,
                aad(Opts, Seq, PrevTip),
                Tag,
                false
            ) of
                Plain when is_binary(Plain) ->
                    decode_log_plaintext(Plain, Seq, PrevTip);
                error ->
                    {error, decrypt_failed}
            end;
        _ ->
            {error, bad_encrypted_store_log}
    catch
        _:_ -> {error, bad_encrypted_store_log}
    end.

decode_log_plaintext(Plain, EnvelopeSeq, PrevTip) ->
    try binary_to_term(Plain, [safe]) of
        #{
            <<"version">> := 1,
            <<"seq">> := EnvelopeSeq,
            <<"prev-tip">> := PrevTip,
            <<"op">> := Op
        } ->
            {ok, EnvelopeSeq, Op};
        _ ->
            {error, bad_encrypted_store_log}
    catch
        _:_ -> {error, bad_encrypted_store_log}
    end.

apply_logged_op(reset, _Entries) ->
    #{?ROOT_GROUP => {group, []}};
apply_logged_op({group, Key}, Entries) ->
    ensure_dir_entries(Entries, Key);
apply_logged_op({write, Key, Value}, Entries0) ->
    Entries = ensure_parent_groups_entries(Entries0, Key),
    Entries#{Key => {raw, Value}};
apply_logged_op({link, LinkPath, LinkPath}, Entries) ->
    Entries;
apply_logged_op({link, New, Existing}, Entries0) ->
    Entries = ensure_parent_groups_entries(Entries0, New),
    Entries#{New => {link, Existing}}.

ensure_parent_groups_entries(Entries, Key) ->
    case filename:dirname(Key) of
        <<".">> ->
            add_group_child_entries(Entries, ?ROOT_GROUP, filename:basename(Key));
        ParentDir ->
            add_group_child_entries(
                ensure_dir_entries(Entries, ParentDir),
                ParentDir,
                filename:basename(Key)
            )
    end.

ensure_dir_entries(Entries, RawPath) ->
    case hb_path:to_binary(RawPath) of
        <<"/">> -> ensure_group_entries(Entries, ?ROOT_GROUP);
        <<"">> -> ensure_group_entries(Entries, ?ROOT_GROUP);
        Path ->
            ensure_dir_entries(
                ensure_group_entries(Entries, ?ROOT_GROUP),
                ?ROOT_GROUP,
                hb_path:term_to_path_parts(Path)
            )
    end.

ensure_dir_entries(Entries, _CurrentGroup, []) ->
    Entries;
ensure_dir_entries(Entries0, CurrentGroup, [Next | Rest]) ->
    Entries1 = add_group_child_entries(Entries0, CurrentGroup, Next),
    NextGroup = next_group_path(CurrentGroup, Next),
    ensure_dir_entries(ensure_group_entries(Entries1, NextGroup), NextGroup, Rest).

ensure_group_entries(Entries, Key) ->
    case maps:get(Key, Entries, nil) of
        {group, _} -> Entries;
        _ -> Entries#{Key => {group, []}}
    end.

add_group_child_entries(Entries0, Group, Child) ->
    Entries = ensure_group_entries(Entries0, Group),
    {group, Children} = maps:get(Group, Entries),
    Entries#{Group => {group, lists:usort([Child | Children])}}.

ensure_root_group(Entries) ->
    case maps:is_key(?ROOT_GROUP, Entries) of
        true -> Entries;
        false -> Entries#{?ROOT_GROUP => {group, []}}
    end.

store_key(Opts) ->
    crypto:mac(hmac, sha256, secret(Opts), key_context(Opts)).

secret(#{<<"secret-ref">> := SecretRef}) ->
    try persistent_term:get(secret_term(SecretRef)) of
        AES when is_binary(AES), byte_size(AES) =:= 32 -> AES;
        _ -> erlang:error({missing_andee_store_secret, SecretRef})
    catch
        error:badarg -> erlang:error({missing_andee_store_secret, SecretRef})
    end.

key_context(Opts) ->
    term_to_binary({
        ?MAGIC,
        hb_maps:get(<<"zone">>, Opts, null, #{}),
        hb_maps:get(<<"ring-address">>, Opts, null, #{})
    }).

aad(Opts, Seq, PrevTip) ->
    term_to_binary({
        ?MAGIC,
        hb_maps:get(<<"zone">>, Opts, null, #{}),
        hb_maps:get(<<"ring-address">>, Opts, null, #{}),
        hb_maps:get(<<"store-id">>, Opts, null, #{}),
        Seq,
        PrevTip
    }).

load_head(File) ->
    case file:read_file(File) of
        {error, enoent} ->
            no_head;
        {ok, Bin} ->
            try binary_to_term(Bin, [safe]) of
                #{
                    <<"magic">> := ?HEAD_MAGIC,
                    <<"version">> := 1,
                    <<"next-seq">> := NextSeq,
                    <<"valid-bytes">> := ValidBytes,
                    <<"tip">> := Tip
                } when is_integer(NextSeq), NextSeq >= 1,
                       is_integer(ValidBytes), ValidBytes >= 0,
                       is_binary(Tip), byte_size(Tip) =:= 32 ->
                    {ok, #{
                        <<"next-seq">> => NextSeq,
                        <<"valid-bytes">> => ValidBytes,
                        <<"tip">> => Tip
                    }};
                _ ->
                    {error, bad_encrypted_store_head}
            catch
                _:_ -> {error, bad_encrypted_store_head}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

reconcile_empty_log(Opts, no_head) ->
    Tip = empty_tip(Opts),
    case write_head(Opts, 0, 1, Tip) of
        ok -> {ok, #{}, 1, 0, Tip};
        {error, Reason} -> {error, Reason}
    end;
reconcile_empty_log(Opts, {ok, Head}) ->
    assert_committed_head(#{}, 1, 0, empty_tip(Opts), Head);
reconcile_empty_log(_Opts, {error, Reason}) ->
    {error, Reason}.

reconcile_log(Opts, no_head, <<>>) ->
    reconcile_empty_log(Opts, no_head);
reconcile_log(_Opts, no_head, _Bin) ->
    {error, encrypted_store_missing_head};
reconcile_log(_Opts, {error, Reason}, _Bin) ->
    {error, Reason};
reconcile_log(Opts, {ok, Head}, Bin) ->
    HeadBytes = maps:get(<<"valid-bytes">>, Head),
    case HeadBytes =< byte_size(Bin) of
        true ->
            reconcile_committed_head(Opts, Head, Bin, HeadBytes);
        false ->
            {error, encrypted_store_rollback_detected}
    end.

reconcile_committed_head(Opts, Head, Bin, HeadBytes) ->
    case replay_exact_log(Opts, binary_part(Bin, 0, HeadBytes), HeadBytes) of
        {ok, Entries, NextSeq, HeadBytes, Tip} ->
            case assert_committed_head(Entries, NextSeq, HeadBytes, Tip, Head) of
                {ok, _, _, _, _} ->
                    recover_valid_tail(Opts, HeadBytes, Bin, Entries, NextSeq, Tip);
                Error ->
                    Error
            end;
        {ok, _Entries, _NextSeq, _OtherBytes, _Tip} ->
            {error, bad_encrypted_store_head};
        {error, _} = Error ->
            Error
    end.

recover_valid_tail(Opts, HeadBytes, Bin, Entries, NextSeq, Tip) ->
    TailBytes = byte_size(Bin) - HeadBytes,
    Tail = binary_part(Bin, HeadBytes, TailBytes),
    LastSeq = NextSeq - 1,
    case replay_uncommitted_tail(Opts, Tail, Entries, LastSeq, HeadBytes, Tip) of
        {ok, FullEntries, FullNextSeq, FullBytes, FullTip}
                when FullBytes > HeadBytes ->
            case write_head(Opts, FullBytes, FullNextSeq, FullTip) of
                ok ->
                    {ok, FullEntries, FullNextSeq, FullBytes, FullTip};
                {error, Reason} ->
                    {error, Reason}
            end;
        _ ->
            {ok, Entries, NextSeq, HeadBytes, Tip}
    end.

replay_uncommitted_tail(_Opts, <<>>, Entries, LastSeq, Offset, Tip) ->
    {ok, Entries, LastSeq + 1, Offset, Tip};
replay_uncommitted_tail(_Opts, Bin, Entries, LastSeq, Offset, Tip)
        when byte_size(Bin) < 4 ->
    {ok, Entries, LastSeq + 1, Offset, Tip};
replay_uncommitted_tail(_Opts, <<Len:32/unsigned-big-integer, Rest/binary>>,
        Entries, LastSeq, Offset, Tip)
        when byte_size(Rest) < Len ->
    {ok, Entries, LastSeq + 1, Offset, Tip};
replay_uncommitted_tail(Opts,
        <<Len:32/unsigned-big-integer, Frame:Len/binary, Rest/binary>>,
        Entries, LastSeq, Offset, Tip) ->
    case decrypt_log_frame(Opts, Tip, Frame) of
        {ok, Seq, Op} when Seq =:= LastSeq + 1 ->
            Record = <<Len:32/unsigned-big-integer, Frame/binary>>,
            NextTip = log_tip(Tip, Record),
            replay_uncommitted_tail(
                Opts,
                Rest,
                apply_logged_op(Op, Entries),
                Seq,
                Offset + 4 + Len,
                NextTip
            );
        _ ->
            {ok, Entries, LastSeq + 1, Offset, Tip}
    end.

replay_exact_log(Opts, Bin, ExpectedBytes) ->
    case replay_log(Opts, Bin) of
        {ok, _Entries, _NextSeq, ExpectedBytes, _Tip} = OK ->
            OK;
        {ok, Entries, NextSeq, OtherBytes, Tip} ->
            {ok, Entries, NextSeq, OtherBytes, Tip};
        {error, _} = Error ->
            Error
    end.

assert_committed_head(Entries, NextSeq, ValidBytes, Tip, Head) ->
    case
        maps:get(<<"next-seq">>, Head) =:= NextSeq andalso
        maps:get(<<"valid-bytes">>, Head) =:= ValidBytes andalso
        maps:get(<<"tip">>, Head) =:= Tip
    of
        true -> {ok, Entries, NextSeq, ValidBytes, Tip};
        false -> {error, encrypted_store_head_mismatch}
    end.

write_head(Opts, ValidBytes, NextSeq, Tip) ->
    File = head_file(Opts),
    Tmp = <<File/binary, ".tmp">>,
    ok = filelib:ensure_dir(File),
    Head = term_to_binary(#{
        <<"magic">> => ?HEAD_MAGIC,
        <<"version">> => 1,
        <<"next-seq">> => NextSeq,
        <<"valid-bytes">> => ValidBytes,
        <<"tip">> => Tip
    }),
    case file:open(Tmp, [write, binary, raw]) of
        {ok, Fd} ->
            case file:write(Fd, Head) of
                ok ->
                    Sync = file:sync(Fd),
                    Close = file:close(Fd),
                    case {Sync, Close} of
                        {ok, ok} -> file:rename(Tmp, File);
                        {{error, Reason}, _} -> {error, Reason};
                        {_, {error, Reason}} -> {error, Reason}
                    end;
                {error, Reason} ->
                    file:close(Fd),
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

empty_tip(Opts) ->
    crypto:hash(sha256, term_to_binary({
        ?HEAD_MAGIC,
        hb_maps:get(<<"zone">>, Opts, null, #{}),
        hb_maps:get(<<"ring-address">>, Opts, null, #{}),
        hb_maps:get(<<"store-id">>, Opts, null, #{}),
        empty
    })).

log_tip(PrevTip, Record) ->
    crypto:hash(sha256, [PrevTip, Record]).

data_file(#{<<"name">> := Name}) ->
    hb_util:bin(filename:join([hb_util:list(Name), hb_util:list(?DATA_FILE)])).

head_file(#{<<"name">> := Name}) ->
    hb_util:bin(filename:join([hb_util:list(Name), hb_util:list(?HEAD_FILE)])).

secret_term(SecretRef) ->
    {?MODULE, secret, SecretRef}.

-ifdef(TEST).
encrypted_store_reopens_with_same_secret_test() ->
    Root = test_root(<<"roundtrip">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"alpha/beta">> => <<"value">>}, #{}),
    ?assertEqual({ok, <<"value">>}, hb_store:read(Store, <<"alpha/beta">>, #{})),
    ok = hb_store:stop(Store),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"value">>}, hb_store:read(Store, <<"alpha/beta">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_rejects_wrong_secret_test() ->
    Root = test_root(<<"wrong-secret">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-wrong">>,
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, crypto:strong_rand_bytes(32)),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"k">> => <<"v">>}, #{}),
    ok = hb_store:stop(Store),
    register_secret(SecretRef, crypto:strong_rand_bytes(32)),
    ?assertMatch({failure, _}, start(Store, #{}, #{})),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_appends_records_test() ->
    Root = test_root(<<"append-log">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-append-log">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"a">> => <<"one">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size1 = filelib:file_size(data_file(Store)),
    ok = hb_store:write(Store, #{<<"b">> => <<"two">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size2 = filelib:file_size(data_file(Store)),
    ?assert(Size2 > Size1),
    ok = hb_store:stop(Store),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"one">>}, hb_store:read(Store, <<"a">>, #{})),
    ?assertEqual({ok, <<"two">>}, hb_store:read(Store, <<"b">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_truncates_partial_tail_test() ->
    Root = test_root(<<"partial-tail">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-partial-tail">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"a">> => <<"one">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size1 = filelib:file_size(File),
    ok = hb_store:stop(Store),
    ok = file:write_file(File, <<0, 0, 0, 100, "partial">>, [append]),
    ok = hb_store:start(Store),
    ?assertEqual(Size1, filelib:file_size(File)),
    ok = hb_store:write(Store, #{<<"b">> => <<"two">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    ok = hb_store:stop(Store),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"one">>}, hb_store:read(Store, <<"a">>, #{})),
    ?assertEqual({ok, <<"two">>}, hb_store:read(Store, <<"b">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_truncates_invalid_uncommitted_tail_test() ->
    Root = test_root(<<"invalid-tail">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-invalid-tail">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"a">> => <<"one">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size = filelib:file_size(File),
    ok = hb_store:stop(Store),
    ok = file:write_file(File, <<0, 0, 0, 1, 0>>, [append]),
    ok = hb_store:start(Store),
    ?assertEqual(Size, filelib:file_size(File)),
    ?assertEqual({ok, <<"one">>}, hb_store:read(Store, <<"a">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_recovers_first_flush_when_empty_head_survives_test() ->
    Root = test_root(<<"empty-head-recovery">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-empty-head-recovery">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    {ok, EmptyHead} = file:read_file(head_file(Store)),
    ok = hb_store:write(Store, #{<<"k">> => <<"value">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    ok = hb_store:stop(Store),
    ok = file:write_file(head_file(Store), EmptyHead),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"value">>}, hb_store:read(Store, <<"k">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_materializes_head_for_empty_file_test() ->
    Root = test_root(<<"empty-file">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-empty-file">>,
    Store = test_store(Root, SecretRef),
    ok = filelib:ensure_dir(data_file(Store)),
    ok = file:write_file(data_file(Store), <<>>),
    register_secret(SecretRef, crypto:strong_rand_bytes(32)),
    ok = hb_store:start(Store),
    ?assert(filelib:is_regular(head_file(Store))),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_rejects_store_bin_rollback_test() ->
    Root = test_root(<<"rollback">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-rollback">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"k">> => <<"old">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    {ok, Prefix} = file:read_file(File),
    ok = hb_store:write(Store, #{<<"k">> => <<"new">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    ?assertEqual({ok, <<"new">>}, hb_store:read(Store, <<"k">>, #{})),
    ok = hb_store:stop(Store),
    ok = file:write_file(File, Prefix),
    ?assertMatch({failure, encrypted_store_rollback_detected}, start(Store, #{}, #{})),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_rejects_malformed_head_prefix_test() ->
    Root = test_root(<<"malformed-head">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-malformed-head">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"k">> => <<"old">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size1 = filelib:file_size(File),
    ok = hb_store:write(Store, #{<<"k">> => <<"new">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    Size2 = filelib:file_size(File),
    ok = hb_store:stop(Store),
    {ok, HeadBin} = file:read_file(head_file(Store)),
    Head = binary_to_term(HeadBin, [safe]),
    ok = file:write_file(
        head_file(Store),
        term_to_binary(Head#{<<"valid-bytes">> := Size1 + 2})
    ),
    ?assertMatch({failure, bad_encrypted_store_head}, start(Store, #{}, #{})),
    ?assertEqual(Size2, filelib:file_size(File)),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_recovers_head_rollback_when_log_is_current_test() ->
    Root = test_root(<<"head-rollback">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-head-rollback">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"k">> => <<"old">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    {ok, OldHead} = file:read_file(head_file(Store)),
    ok = hb_store:write(Store, #{<<"k">> => <<"new">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    ok = hb_store:stop(Store),
    ok = file:write_file(head_file(Store), OldHead),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"new">>}, hb_store:read(Store, <<"k">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

encrypted_store_recovers_valid_tail_before_invalid_tail_test() ->
    Root = test_root(<<"valid-then-invalid-tail">>),
    file:del_dir_r(Root),
    SecretRef = <<"test-secret-valid-then-invalid-tail">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"k">> => <<"old">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    {ok, OldHead} = file:read_file(head_file(Store)),
    ok = hb_store:write(Store, #{<<"k">> => <<"new">>}, #{}),
    ok = hb_store_andee_encrypted:flush(Store),
    CurrentSize = filelib:file_size(File),
    ok = hb_store:stop(Store),
    ok = file:write_file(head_file(Store), OldHead),
    ok = file:write_file(File, <<0, 0, 0, 1, 0>>, [append]),
    ok = hb_store:start(Store),
    ?assertEqual(CurrentSize, filelib:file_size(File)),
    ?assertEqual({ok, <<"new">>}, hb_store:read(Store, <<"k">>, #{})),
    ok = hb_store:stop(Store),
    forget_secret(SecretRef),
    file:del_dir_r(Root).

test_store(Root, SecretRef) ->
    #{
        <<"store-module">> => ?MODULE,
        <<"name">> => Root,
        <<"zone">> => <<"zone-a">>,
        <<"ring-address">> => <<"ring-a">>,
        <<"store-id">> => <<"store-a">>,
        <<"secret-ref">> => SecretRef
    }.

test_root(Name) ->
    Base = hb_util:bin(os:getenv("TMPDIR", "/tmp")),
    hb_util:bin(filename:join([
        hb_util:list(Base),
        "andee-encrypted-store-tests",
        hb_util:list(Name)
    ])).
-endif.
