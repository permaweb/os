%%% @doc LapEE non-volatile store activation.
%%%
%%% This module is deliberately not an HTTP device. It is called only after a
%%% green-zone key exists, scans for a partition explicitly provisioned as
%%% `LAPEE_NONVOLATILE', and uses the zone AES secret to open or initialize an
%%% encrypted ext4 volume. On success the mounted LMDB becomes the first local
%%% HyperBEAM store; missing keys from the temporary boot LMDB are copied across
%%% so early boot cache entries survive the transition.
-module(lapee_nonvolatile).

-export([activate/3, status/1]).

-define(DEFAULT_LABEL, <<"LAPEE_NONVOLATILE">>).
-define(DEFAULT_MAPPER, <<"lapee-nonvolatile">>).
-define(DEFAULT_MOUNT, <<"/var/lib/lapee/nonvolatile">>).
-define(DEFAULT_STORE, <<"store/cache-mainnet/lmdb">>).
-define(KEY_DIR, "/run/lapee/nonvolatile-keys").
-define(FORMAT_MARKER, <<"LapEE nonvolatile provisioning marker v1\n">>).
-define(VOLUME_ID_FILE, ".lapee-volume-id").
-define(FORMAT_TIMEOUT_MS, 1800000).

activate(Name, AES, Opts) when is_binary(Name), is_binary(AES) ->
    activate_enabled(Name, AES, Opts).

status(Opts) ->
    hb_opts:get(<<"lapee-nonvolatile-status">>, #{}, Opts).

activate_enabled(Name, AES, Opts) ->
    global:trans(
        {?MODULE, activation},
        fun() -> activate_enabled_locked(Name, AES, Opts) end,
        [node()]
    ).

activate_enabled_locked(Name, AES, Opts) ->
    case mounted(Opts) orelse mapper_mounted_at_default() of
        true ->
            Store = persistent_store(?DEFAULT_MOUNT, Opts),
            Migration = migrate_primary_lmdb(Store, Opts),
            Status = mounted_status(
                Name,
                mapper_source_partition(),
                Store,
                false,
                false,
                Migration
            ),
            {ok, set_status(install_store(Store, Opts), Status)};
        false ->
            case do_activate(Name, AES, Opts) of
                {ok, Store, Status} ->
                    Opts1 = install_store(Store, Opts),
                    {ok, set_status(Opts1, Status)};
                {skip, Status} ->
                    {ok, set_status(Opts, Status)};
                {error, Status} ->
                    {ok, set_status(Opts, Status)}
            end
    end.

mounted(Opts) ->
    case status(Opts) of
        #{ <<"mounted">> := true } -> true;
        _ -> false
    end.

do_activate(Name, AES, Opts) ->
    case labeled_partitions(?DEFAULT_LABEL) of
        [] ->
            {skip, #{
                <<"enabled">> => true,
                <<"mounted">> => false,
                <<"partition-label">> => ?DEFAULT_LABEL,
                <<"reason">> => <<"not-provisioned">>
            }};
        [Partition] ->
            activate_partition(Name, AES, Partition, Opts);
        Parts ->
            {error, #{
                <<"enabled">> => true,
                <<"mounted">> => false,
                <<"partition-label">> => ?DEFAULT_LABEL,
                <<"error">> => <<"multiple-nonvolatile-partitions">>,
                <<"partitions">> => [unicode:characters_to_binary(P) || P <- Parts]
            }}
    end.

activate_partition(Name, AES, Partition, Opts) ->
    Key = disk_key(Name, AES),
    with_key_file(Key, fun(KeyFile) ->
        case ensure_luks(Partition, KeyFile) of
            {ok, LuksFormatted} ->
                case ensure_open(Partition, KeyFile) of
                    ok ->
                        MapperDev = <<"/dev/mapper/", ?DEFAULT_MAPPER/binary>>,
                        case ensure_mounted_filesystem(
                            MapperDev, ?DEFAULT_MOUNT, LuksFormatted) of
                            {ok, FsFormatted} ->
                                Store = persistent_store(?DEFAULT_MOUNT, Opts),
                                Migration = migrate_primary_lmdb(Store, Opts),
                                {ok, Store, mounted_status(
                                    Name,
                                    unicode:characters_to_binary(Partition),
                                    Store,
                                    LuksFormatted,
                                    FsFormatted,
                                    Migration
                                )};
                            {error, Reason} ->
                                activation_error(<<"filesystem-failed">>, Reason)
                        end;
                    {error, Reason} ->
                        activation_error(<<"open-failed">>, Reason)
                end;
            {error, Reason} ->
                activation_error(<<"luks-failed">>, Reason)
        end
    end).

mounted_status(Name, Partition, Store, LuksFormatted, FsFormatted, Migration) ->
    Status0 = #{
        <<"enabled">> => true,
        <<"mounted">> => true,
        <<"zone">> => Name,
        <<"partition-label">> => ?DEFAULT_LABEL,
        <<"mapper">> => ?DEFAULT_MAPPER,
        <<"mount-point">> => ?DEFAULT_MOUNT,
        <<"store">> => hb_maps:get(<<"name">>, Store, undefined, #{}),
        <<"volume-id">> => ensure_volume_id(?DEFAULT_MOUNT),
        <<"formatted-luks">> => LuksFormatted,
        <<"formatted-filesystem">> => FsFormatted,
        <<"migration">> => Migration
    },
    case Partition of
        undefined -> Status0;
        _ -> Status0#{<<"partition">> => Partition}
    end.

activation_error(Code, Reason) ->
    {error, #{
        <<"enabled">> => true,
        <<"mounted">> => false,
        <<"error">> => Code,
        <<"detail">> => command_reason(Reason)
    }}.

disk_key(Name, AES) ->
    crypto:hash(
        sha256,
        [<<"LapEE nonvolatile storage v1">>, 0, Name, 0, AES]
    ).

labeled_partitions(Label) ->
    case file:list_dir("/sys/class/block") of
        {ok, Names} ->
            lists:filtermap(
                fun(Name) ->
                    case {partition_label(Name), runtime_partition_ok(Name)} of
                        {Label, true} -> {true, "/dev/" ++ Name};
                        _ -> false
                    end
                end,
                Names
            );
        _ ->
            []
    end.

runtime_partition_ok(Name) ->
    case parent_block(Name) of
        undefined ->
            false;
        Parent ->
            not excluded_block(Parent) andalso
                sysfs_value(["/sys/block/", Parent, "/ro"], <<"1">>) =:= <<"0">> andalso
                sysfs_value(["/sys/block/", Parent, "/removable"], <<"1">>) =:= <<"0">> andalso
                not usb_block(Parent)
    end.

parent_block(Name) ->
    case file:read_file(filename:join(["/sys/class/block", Name, "partition"])) of
        {ok, _} ->
            parent_block_name(unicode:characters_to_binary(Name));
        _ ->
            undefined
    end.

parent_block_name(Name) ->
    case re:replace(Name, <<"p?[0-9]+$">>, <<>>, [{return, binary}]) of
        Name -> undefined;
        Parent -> binary_to_list(Parent)
    end.

excluded_block("loop" ++ _) -> true;
excluded_block("ram" ++ _) -> true;
excluded_block("dm-" ++ _) -> true;
excluded_block("zram" ++ _) -> true;
excluded_block("sr" ++ _) -> true;
excluded_block(_) -> false.

sysfs_value(Path, Default) ->
    case file:read_file(iolist_to_binary(Path)) of
        {ok, Bin} -> string:trim(Bin);
        _ -> Default
    end.

usb_block(Parent) ->
    case file:read_link_all(filename:join(["/sys/block", Parent, "device"])) of
        {ok, Path} -> binary:match(unicode:characters_to_binary(Path), <<"usb">>) =/= nomatch;
        _ -> false
    end.

partition_label(Name) ->
    Dir = filename:join("/sys/class/block", Name),
    case file:read_file(filename:join(Dir, "partition")) of
        {ok, _} ->
            case file:read_file(filename:join(Dir, "uevent")) of
                {ok, UEvent} ->
                    uevent_value(<<"PARTNAME">>, UEvent);
                _ ->
                    undefined
            end;
        _ ->
            undefined
    end.

uevent_value(Key, UEvent) ->
    Prefix = <<Key/binary, "=">>,
    Lines = binary:split(UEvent, <<"\n">>, [global]),
    case [binary:part(Line, byte_size(Prefix), byte_size(Line) - byte_size(Prefix))
          || Line <- Lines,
             byte_size(Line) >= byte_size(Prefix),
             binary:part(Line, 0, byte_size(Prefix)) =:= Prefix] of
        [Value | _] -> Value;
        [] -> undefined
    end.

ensure_luks(Partition, KeyFile) ->
    case run(<<"cryptsetup">>, [<<"isLuks">>, Partition]) of
        {ok, _} ->
            {ok, false};
        {error, _} ->
            case has_format_marker(Partition) of
                true ->
                    case run(
                        <<"cryptsetup">>,
                        [
                            <<"luksFormat">>,
                            <<"--batch-mode">>,
                            <<"--type">>, <<"luks2">>,
                            <<"--label">>, ?DEFAULT_LABEL,
                            <<"--cipher">>, <<"aes-xts-plain64">>,
                            <<"--key-size">>, <<"256">>,
                            <<"--hash">>, <<"sha256">>,
                            <<"--key-file">>, KeyFile,
                            Partition
                        ],
                        ?FORMAT_TIMEOUT_MS
                    ) of
                        {ok, _} ->
                            sync_storage(),
                            {ok, true};
                        Error -> Error
                    end;
                false ->
                    {error, <<"missing-provisioning-marker">>}
            end
    end.

has_format_marker(Partition) ->
    case file:open(Partition, [read, raw, binary]) of
        {ok, FD} ->
            try
                case file:pread(FD, 0, byte_size(?FORMAT_MARKER)) of
                    {ok, ?FORMAT_MARKER} -> true;
                    _ -> false
                end
            after
                file:close(FD)
            end;
        _ ->
            false
    end.

ensure_open(Partition, KeyFile) ->
    MapperDev = <<"/dev/mapper/", ?DEFAULT_MAPPER/binary>>,
    case file:read_file_info(binary_to_list(MapperDev)) of
        {ok, _} ->
            case mounted_device(MapperDev) of
                expected -> ok;
                elsewhere -> {error, <<"mapper-mounted-elsewhere">>};
                false ->
                    case run(<<"cryptsetup">>, [<<"close">>, ?DEFAULT_MAPPER]) of
                        {ok, _} -> open_luks(Partition, KeyFile);
                        Error -> Error
                    end
            end;
        _ ->
            open_luks(Partition, KeyFile)
    end.

open_luks(Partition, KeyFile) ->
    case run(
        <<"cryptsetup">>,
        [
            <<"open">>,
            <<"--key-file">>, KeyFile,
            Partition,
            ?DEFAULT_MAPPER
        ]
    ) of
        {ok, _} -> ok;
        Error -> Error
    end.

ensure_mounted_filesystem(MapperDev, Mount, LuksFormatted) ->
    case filesystem_type(MapperDev) of
        {ok, <<"ext4">>} ->
            mount_with_status(MapperDev, Mount, false);
        {ok, Other} ->
            {error, #{<<"unexpected-filesystem">> => Other}};
        unknown when LuksFormatted ->
            case make_ext4(MapperDev) of
                {ok, true} -> mount_with_status(MapperDev, Mount, true);
                Error -> Error
            end;
        unknown ->
            case ensure_mount(MapperDev, Mount) of
                ok -> {ok, false};
                {error, Reason} ->
                    {error, #{
                        <<"existing-luks-mount-failed">> =>
                            command_reason(Reason)
                    }}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

mount_with_status(MapperDev, Mount, FsFormatted) ->
    case ensure_mount(MapperDev, Mount) of
        ok -> {ok, FsFormatted};
        {error, Reason} -> {error, Reason}
    end.

filesystem_type(MapperDev) ->
    case run(
        <<"blkid">>,
        [<<"-o">>, <<"value">>, <<"-s">>, <<"TYPE">>, MapperDev]
    ) of
        {ok, Type0} ->
            parse_blkid_type(Type0);
        {error, #{<<"exit-status">> := 2, <<"output">> := Output}} ->
            case parse_blkid_type(Output) of
                unknown -> unknown;
                Type -> Type
            end;
        {error, Reason} ->
            {error, Reason}
    end.

parse_blkid_type(Output) ->
    Type = clean_blkid_type(Output),
    case Type of
        <<>> -> unknown;
        _ -> {ok, Type}
    end.

clean_blkid_type(Output) ->
    Clean = string:trim(binary:replace(Output, <<"\n">>, <<" ">>, [global])),
    case binary:split(Clean, <<"TYPE=\"">>) of
        [_Before, Rest] ->
            hd(binary:split(Rest, <<"\"">>));
        [_] ->
            case binary:match(Clean, <<"TYPE=">>) of
                {Start, _} ->
                    Value0 = binary:part(
                        Clean,
                        Start + byte_size(<<"TYPE=">>),
                        byte_size(Clean) - Start - byte_size(<<"TYPE=">>)
                    ),
                    hd(binary:split(Value0, <<" ">>));
                nomatch ->
                    case binary:match(Clean, <<": ">>) of
                        nomatch -> Clean;
                        _ -> <<>>
                    end
            end
    end.

make_ext4(MapperDev) ->
    case run(
        <<"mke2fs">>,
        [
            <<"-t">>, <<"ext4">>,
            <<"-F">>,
            <<"-L">>, ?DEFAULT_LABEL,
            MapperDev
        ],
        ?FORMAT_TIMEOUT_MS
    ) of
        {ok, _} ->
            sync_storage(),
            {ok, true};
        Error -> Error
    end.

ensure_mount(MapperDev, Mount) ->
    MountList = binary_to_list(Mount),
    ok = filelib:ensure_dir(filename:join(MountList, "store/.keep")),
    case mounted_device(MapperDev) of
        expected ->
            ok;
        elsewhere ->
            {error, <<"mapper-mounted-elsewhere">>};
        false ->
            case run(
                <<"mount">>,
                [
                    <<"-t">>, <<"ext4">>,
                    <<"-o">>, <<"noatime,nodev,nosuid,noexec">>,
                    MapperDev,
                    Mount
                ]
            ) of
                {ok, _} -> ok;
                Error -> Error
            end
    end.

mounted_device(MapperDev) ->
    case file:read_file("/proc/mounts") of
        {ok, Mounts} ->
            Lines = binary:split(Mounts, <<"\n">>, [global]),
            Mount = ?DEFAULT_MOUNT,
            case [mount_fields(Line) || Line <- Lines,
                                      starts_with(Line, <<MapperDev/binary, " ">>)] of
                [] -> false;
                [[MapperDev, Mount | _] | _] -> expected;
                [_ | _] -> elsewhere
            end;
        _ ->
            false
    end.

mapper_mounted_at_default() ->
    mounted_device(<<"/dev/mapper/", ?DEFAULT_MAPPER/binary>>) =:= expected.

mapper_source_partition() ->
    case run(<<"cryptsetup">>, [<<"status">>, ?DEFAULT_MAPPER]) of
        {ok, Output} -> parse_mapper_source(Output);
        _ -> undefined
    end.

parse_mapper_source(Output) ->
    Lines = binary:split(Output, <<"\n">>, [global]),
    case [string:trim(Rest)
          || Line <- Lines,
             [Key, Rest] <- [binary:split(Line, <<":">>)],
             string:trim(Key) =:= <<"device">>] of
        [Device | _] when byte_size(Device) > 0 -> Device;
        _ -> undefined
    end.

starts_with(Line, Prefix) ->
    byte_size(Line) >= byte_size(Prefix) andalso
        binary:part(Line, 0, byte_size(Prefix)) =:= Prefix.

mount_fields(Line) ->
    binary:split(Line, <<" ">>, [global]).

persistent_store(Mount, Opts) ->
    Source = primary_lmdb_store(Opts),
    Name = filename:join(Mount, ?DEFAULT_STORE),
    Source#{<<"name">> => Name}.

ensure_volume_id(Mount) ->
    Path = filename:join(binary_to_list(Mount), ?VOLUME_ID_FILE),
    case file:read_file(Path) of
        {ok, ID} ->
            string:trim(ID);
        _ ->
            ID = hb_util:encode(crypto:strong_rand_bytes(32)),
            ok = file:write_file(Path, <<ID/binary, "\n">>),
            ok = file:change_mode(Path, 8#600),
            sync_storage(),
            ID
    end.

primary_lmdb_store(Opts) ->
    Stores = hb_opts:get(store, [], Opts),
    case [Store || Store <- store_list(Stores),
                   hb_maps:get(<<"store-module">>, Store, undefined, #{}) =:=
                       hb_store_lmdb] of
        [Store | _] -> Store;
        [] -> #{<<"name">> => <<"cache-mainnet/lmdb">>,
                <<"store-module">> => hb_store_lmdb}
    end.

store_list(Stores) when is_list(Stores) -> Stores;
store_list(Store) when is_map(Store) -> [Store];
store_list(_) -> [].

migrate_primary_lmdb(PersistentStore, Opts) ->
    SourceStore = primary_lmdb_store(Opts),
    SourceName = hb_maps:get(<<"name">>, SourceStore, undefined, #{}),
    DestName = hb_maps:get(<<"name">>, PersistentStore, undefined, #{}),
    case {SourceName, DestName} of
        {undefined, _} ->
            #{<<"status">> => <<"skipped">>, <<"reason">> => <<"no-source">>};
        {Same, Same} ->
            #{<<"status">> => <<"skipped">>, <<"reason">> => <<"already-primary">>};
        _ ->
            migrate_lmdb_dir(SourceStore, SourceName, DestName)
    end.

migrate_lmdb_dir(SourceStore, _SourceName, DestName) ->
    DestStore = SourceStore#{<<"name">> => DestName},
    try
        #{<<"db">> := SourceDB} = hb_store:find(SourceStore),
        #{<<"db">> := DestDB} = hb_store:find(DestStore),
        catch elmdb:flush(SourceDB),
        Count =
            case elmdb:fold(
                SourceDB,
                fun(Key, Value, Acc) ->
                    case elmdb:get(DestDB, Key) of
                        {ok, _} ->
                            Acc;
                        not_found ->
                            ok = elmdb:put(DestDB, Key, Value),
                            Acc + 1;
                        {error, not_found} ->
                            ok = elmdb:put(DestDB, Key, Value),
                            Acc + 1
                    end
                end,
                0
            ) of
                {ok, N} -> N;
                {error, Type, Desc} ->
                    throw({lmdb_migration_failed, Type, Desc})
            end,
        catch elmdb:flush(DestDB),
        sync_storage(),
        #{<<"status">> => <<"merged">>, <<"keys">> => Count}
    catch
        _:Reason ->
            #{<<"status">> => <<"failed">>,
              <<"reason">> => unicode:characters_to_binary(
                  io_lib:format("~p", [Reason]))}
    end.

install_store(Store, Opts) ->
    Stores = hb_opts:get(store, [], Opts),
    MatchIndex = hb_opts:get(<<"match-index">>, [], Opts),
    StoreName = hb_maps:get(<<"name">>, Store, undefined, #{}),
    Opts#{
        <<"store">> => [Store | remove_store_name(StoreName, store_list(Stores))],
        <<"match-index">> =>
            [Store | remove_store_name(StoreName, store_list(MatchIndex))]
    }.

remove_store_name(undefined, Stores) ->
    Stores;
remove_store_name(Name, Stores) ->
    [Store || Store <- Stores,
              hb_maps:get(<<"name">>, Store, undefined, #{}) =/= Name].

set_status(Opts, Status) ->
    Opts#{<<"lapee-nonvolatile-status">> => Status}.

with_key_file(Key, Fun) ->
    ok = ensure_private_key_dir(),
    Path = filename:join(
        ?KEY_DIR,
        "nonvolatile-key-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    try
        ok = file:write_file(Path, Key),
        ok = file:change_mode(Path, 8#600),
        Fun(unicode:characters_to_binary(Path))
    after
        _ = file:delete(Path)
    end.

ensure_private_key_dir() ->
    ok = filelib:ensure_dir(filename:join(?KEY_DIR, ".keep")),
    ok = file:change_mode(?KEY_DIR, 8#700).

sync_storage() ->
    case executable(<<"sync">>) of
        {ok, Path} ->
            Port = open_port(
                {spawn_executable, Path},
                [binary, exit_status, stderr_to_stdout, use_stdio]
            ),
            _ = collect(Port, [], ?FORMAT_TIMEOUT_MS),
            ok;
        {error, _} ->
            ok
    end.

run(Program, Args) ->
    run(Program, Args, 120000).

run(Program, Args, Timeout) ->
    case executable(Program) of
        {ok, Path} ->
            Port = open_port(
                {spawn_executable, Path},
                [
                    binary,
                    exit_status,
                    stderr_to_stdout,
                    use_stdio,
                    {args, [arg(A) || A <- Args]}
                ]
            ),
            collect(Port, [], Timeout);
        {error, _} = Error ->
            Error
    end.

collect(Port, Acc, Timeout) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Acc, Data], Timeout);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(Acc)};
        {Port, {exit_status, Status}} ->
            {error, #{<<"exit-status">> => Status,
                      <<"output">> => iolist_to_binary(Acc)}}
    after Timeout ->
        port_close(Port),
        {error, <<"timeout">>}
    end.

executable(Program) ->
    case os:find_executable(binary_to_list(Program)) of
        false -> {error, #{<<"missing-executable">> => Program}};
        Path -> {ok, Path}
    end.

arg(Bin) when is_binary(Bin) -> binary_to_list(Bin);
arg(List) when is_list(List) -> List.

command_reason(#{<<"missing-executable">> := Program}) ->
    #{<<"missing-executable">> => Program};
command_reason(#{<<"exit-status">> := Status, <<"output">> := Output}) ->
    #{<<"exit-status">> => Status, <<"output">> => Output};
command_reason(Reason) when is_binary(Reason) ->
    Reason;
command_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~p", [Reason])).
