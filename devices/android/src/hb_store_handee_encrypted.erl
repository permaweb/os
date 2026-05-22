%%% @doc Zone-unsealed encrypted non-volatile store for HandEE.
%%%
%%% The store keeps HyperBEAM's normal `hb_store' interface at the boundary,
%%% keeps live state in ETS, and persists encrypted append-only operation log
%%% records under app-private storage. The zone AES secret is registered in
%%% memory by `dev_zone' after successful measurement/secret-recipient
%%% admission; it is never placed in the store message itself.
-module(hb_store_handee_encrypted).

-export([register_secret/2, forget_secret/1, flush/1]).
-export([start/3, stop/3, reset/3, scope/0, scope/1]).
-export([write/3, read/3, list/3, type/3, link/3, group/3, resolve/3]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(ROOT_GROUP, <<"/">>).
-define(DATA_FILE, <<"store.bin">>).
-define(MAGIC, <<"handee-encrypted-store-log-v1">>).
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
        {ok, Entries, NextSeq, ValidBytes} ->
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
                        next_seq := Seq0}) ->
    maybe_cancel_timer(maps:get(timer, State)),
    Pending = lists:reverse(Pending0),
    {IOData, NextSeq} =
        lists:mapfoldl(
            fun(Op, Seq) ->
                Frame = encode_log_frame(Opts, Seq, Op),
                FrameLen = byte_size(Frame),
                {[<<FrameLen:32/unsigned-big-integer>>, Frame], Seq + 1}
            end,
            Seq0,
            Pending
        ),
    case file:write(Fd, IOData) of
        ok ->
            case maybe_sync(Fd, Opts) of
                ok ->
                    {ok, State#{
                        pending := [],
                        timer := undefined,
                        next_seq := NextSeq
                    }};
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

maybe_sync(Fd, Opts) ->
    case hb_maps:get(<<"sync-on-flush">>, Opts, false, #{}) of
        true -> file:sync(Fd);
        _ -> ok
    end.

encode_log_frame(Opts, Seq, Op) ->
    Plain = term_to_binary(#{
        <<"version">> => 1,
        <<"seq">> => Seq,
        <<"op">> => Op
    }, [compressed]),
    IV = crypto:strong_rand_bytes(12),
    AAD = aad(Opts, Seq),
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
    case file:read_file(File) of
        {error, enoent} ->
            {ok, #{}, 1, 0};
        {ok, Bin} ->
            replay_log(Opts, Bin, #{}, 0, 0);
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

replay_log(_Opts, <<>>, Entries, LastSeq, Offset) ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset};
replay_log(_Opts, Bin, Entries, LastSeq, Offset) when byte_size(Bin) < 4 ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset};
replay_log(_Opts, <<Len:32/unsigned-big-integer, Rest/binary>>, Entries, LastSeq,
        Offset)
        when byte_size(Rest) < Len ->
    {ok, ensure_root_group(Entries), LastSeq + 1, Offset};
replay_log(Opts, <<Len:32/unsigned-big-integer, Frame:Len/binary, Rest/binary>>,
        Entries, LastSeq, Offset) ->
    case decrypt_log_frame(Opts, Frame) of
        {ok, Seq, Op} when Seq =:= LastSeq + 1 ->
            replay_log(
                Opts,
                Rest,
                apply_logged_op(Op, Entries),
                max(Seq, LastSeq),
                Offset + 4 + Len
            );
        {ok, Seq, _Op} ->
            {error, {bad_encrypted_store_log_sequence, LastSeq, Seq}};
        {error, _} = Error ->
            Error
    end.

decrypt_log_frame(Opts, Bin) ->
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
                aad(Opts, Seq),
                Tag,
                false
            ) of
                Plain when is_binary(Plain) ->
                    decode_log_plaintext(Plain, Seq);
                error ->
                    {error, decrypt_failed}
            end;
        _ ->
            {error, bad_encrypted_store_log}
    catch
        _:_ -> {error, bad_encrypted_store_log}
    end.

decode_log_plaintext(Plain, EnvelopeSeq) ->
    try binary_to_term(Plain, [safe]) of
        #{<<"version">> := 1, <<"seq">> := EnvelopeSeq, <<"op">> := Op} ->
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
        _ -> erlang:error({missing_handee_store_secret, SecretRef})
    catch
        error:badarg -> erlang:error({missing_handee_store_secret, SecretRef})
    end.

key_context(Opts) ->
    term_to_binary({
        ?MAGIC,
        hb_maps:get(<<"zone">>, Opts, null, #{}),
        hb_maps:get(<<"ring-address">>, Opts, null, #{})
    }).

aad(Opts, Seq) ->
    term_to_binary({
        ?MAGIC,
        hb_maps:get(<<"zone">>, Opts, null, #{}),
        hb_maps:get(<<"ring-address">>, Opts, null, #{}),
        hb_maps:get(<<"store-id">>, Opts, null, #{}),
        Seq
    }).

data_file(#{<<"name">> := Name}) ->
    hb_util:bin(filename:join([hb_util:list(Name), hb_util:list(?DATA_FILE)])).

secret_term(SecretRef) ->
    {?MODULE, secret, SecretRef}.

-ifdef(TEST).
encrypted_store_reopens_with_same_secret_test() ->
    Root = test_root(<<"roundtrip">>),
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
    SecretRef = <<"test-secret-append-log">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"a">> => <<"one">>}, #{}),
    ok = hb_store_handee_encrypted:flush(Store),
    Size1 = filelib:file_size(data_file(Store)),
    ok = hb_store:write(Store, #{<<"b">> => <<"two">>}, #{}),
    ok = hb_store_handee_encrypted:flush(Store),
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
    SecretRef = <<"test-secret-partial-tail">>,
    AES = crypto:strong_rand_bytes(32),
    Store = test_store(Root, SecretRef),
    File = data_file(Store),
    register_secret(SecretRef, AES),
    ok = hb_store:start(Store),
    ok = hb_store:write(Store, #{<<"a">> => <<"one">>}, #{}),
    ok = hb_store_handee_encrypted:flush(Store),
    Size1 = filelib:file_size(File),
    ok = hb_store:stop(Store),
    ok = file:write_file(File, <<0, 0, 0, 100, "partial">>, [append]),
    ok = hb_store:start(Store),
    ?assertEqual(Size1, filelib:file_size(File)),
    ok = hb_store:write(Store, #{<<"b">> => <<"two">>}, #{}),
    ok = hb_store_handee_encrypted:flush(Store),
    ok = hb_store:stop(Store),
    ok = hb_store:start(Store),
    ?assertEqual({ok, <<"one">>}, hb_store:read(Store, <<"a">>, #{})),
    ?assertEqual({ok, <<"two">>}, hb_store:read(Store, <<"b">>, #{})),
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
        "handee-encrypted-store-tests",
        hb_util:list(Name)
    ])).
-endif.
