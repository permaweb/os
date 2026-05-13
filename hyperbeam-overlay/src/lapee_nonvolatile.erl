%%% @doc LapEE non-volatile store activation.
%%%
%%% This module is deliberately not an HTTP device. It is called only after a
%%% green-zone key exists, scans for a partition explicitly provisioned as
%%% `LAPEE_NONVOLATILE', and uses the zone AES secret to open or initialize an
%%% encrypted ext4 volume. On success the mounted LMDB becomes the first local
%%% HyperBEAM store; the temporary boot LMDB is copied across once so early boot
%%% cache entries survive the transition.
-module(lapee_nonvolatile).

-export([activate/3, status/1]).

-define(DEFAULT_LABEL, <<"LAPEE_NONVOLATILE">>).
-define(DEFAULT_MAPPER, <<"lapee-nonvolatile">>).
-define(DEFAULT_MOUNT, <<"/var/lib/lapee/nonvolatile">>).
-define(DEFAULT_STORE, <<"store/cache-mainnet/lmdb">>).
-define(KEY_DIR, "/run/lapee/nonvolatile-keys").
-define(FORMAT_MARKER, <<"LapEE nonvolatile provisioning marker v1\n">>).

activate(Name, AES, Opts) when is_binary(Name), is_binary(AES) ->
    case hb_opts:get(<<"lapee-nonvolatile">>, true, Opts) of
        false ->
            {ok, set_status(Opts, #{
                <<"enabled">> => false,
                <<"mounted">> => false
            })};
        _ ->
            activate_enabled(Name, AES, Opts)
    end.

status(Opts) ->
    hb_opts:get(<<"lapee-nonvolatile-status">>, #{}, Opts).

activate_enabled(Name, AES, Opts) ->
    case mounted(Opts) of
        true ->
            {ok, Opts};
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
    Label = hb_opts:get(<<"lapee-nonvolatile-label">>, ?DEFAULT_LABEL, Opts),
    case labeled_partitions(Label) of
        [] ->
            {skip, #{
                <<"enabled">> => true,
                <<"mounted">> => false,
                <<"partition-label">> => Label,
                <<"reason">> => <<"not-provisioned">>
            }};
        [Partition] ->
            activate_partition(Name, AES, Partition, Opts);
        Parts ->
            {error, #{
                <<"enabled">> => true,
                <<"mounted">> => false,
                <<"partition-label">> => Label,
                <<"error">> => <<"multiple-nonvolatile-partitions">>,
                <<"partitions">> => [unicode:characters_to_binary(P) || P <- Parts]
            }}
    end.

activate_partition(Name, AES, Partition, Opts) ->
    Mapper = hb_opts:get(<<"lapee-nonvolatile-mapper">>, ?DEFAULT_MAPPER, Opts),
    Mount = hb_opts:get(<<"lapee-nonvolatile-mount-point">>, ?DEFAULT_MOUNT, Opts),
    AllowFormat =
        hb_opts:get(<<"lapee-nonvolatile-allow-format">>, true, Opts),
    Key = disk_key(Name, AES),
    with_key_file(Key, fun(KeyFile) ->
        case ensure_luks(Partition, KeyFile, AllowFormat) of
            {ok, LuksFormatted} ->
                case ensure_open(Partition, Mapper, KeyFile) of
                    ok ->
                        MapperDev = <<"/dev/mapper/", Mapper/binary>>,
                        case ensure_filesystem(MapperDev, LuksFormatted, AllowFormat) of
                            {ok, FsFormatted} ->
                                case ensure_mount(MapperDev, Mount) of
                                    ok ->
                                        Store = persistent_store(Mount, Opts),
                                        Migration = migrate_primary_lmdb(Store, Opts),
                                        {ok, Store, #{
                                            <<"enabled">> => true,
                                            <<"mounted">> => true,
                                            <<"zone">> => Name,
                                            <<"partition">> =>
                                                unicode:characters_to_binary(Partition),
                                            <<"mapper">> => Mapper,
                                            <<"mount-point">> => Mount,
                                            <<"store">> =>
                                                hb_maps:get(<<"name">>, Store, undefined, #{}),
                                            <<"formatted-luks">> => LuksFormatted,
                                            <<"formatted-filesystem">> => FsFormatted,
                                            <<"migration">> => Migration
                                        }};
                                    {error, Reason} ->
                                        activation_error(<<"mount-failed">>, Reason)
                                end;
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
                    case partition_label(Name) of
                        Label -> {true, "/dev/" ++ Name};
                        _ -> false
                    end
                end,
                Names
            );
        _ ->
            []
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

ensure_luks(Partition, KeyFile, AllowFormat) ->
    case run(<<"cryptsetup">>, [<<"isLuks">>, Partition]) of
        {ok, _} ->
            {ok, false};
        {error, _} when AllowFormat =:= false ->
            {error, <<"not-luks">>};
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
                        ]
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

ensure_open(Partition, Mapper, KeyFile) ->
    case file:read_file_info(binary_to_list(<<"/dev/mapper/", Mapper/binary>>)) of
        {ok, _} ->
            run(<<"cryptsetup">>, [<<"close">>, Mapper]),
            open_luks(Partition, Mapper, KeyFile);
        _ ->
            open_luks(Partition, Mapper, KeyFile)
    end.

open_luks(Partition, Mapper, KeyFile) ->
    case run(
        <<"cryptsetup">>,
        [
            <<"open">>,
            <<"--key-file">>, KeyFile,
            Partition,
            Mapper
        ]
    ) of
        {ok, _} -> ok;
        Error -> Error
    end.

ensure_filesystem(MapperDev, FreshLuks, AllowFormat) ->
    case filesystem_type(MapperDev) of
        {ok, <<"ext4">>} ->
            {ok, false};
        {ok, Other} ->
            {error, #{<<"unexpected-filesystem">> => Other}};
        unknown when FreshLuks =:= true, AllowFormat =:= true ->
            make_ext4(MapperDev);
        unknown when FreshLuks =:= true ->
            {error, <<"missing-filesystem">>};
        unknown ->
            {ok, false}
    end.

filesystem_type(MapperDev) ->
    case run(
        <<"blkid">>,
        [<<"-o">>, <<"value">>, <<"-s">>, <<"TYPE">>, MapperDev]
    ) of
        {ok, Type0} ->
            parse_blkid_type(Type0);
        {error, _} ->
            unknown
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
        ]
    ) of
        {ok, _} ->
            sync_storage(),
            {ok, true};
        Error -> Error
    end.

ensure_mount(MapperDev, Mount) ->
    MountList = binary_to_list(Mount),
    ok = filelib:ensure_dir(filename:join(MountList, "store/.keep")),
    case mounted_at(MountList) of
        true ->
            ok;
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

mounted_at(Mount) ->
    case file:read_file("/proc/mounts") of
        {ok, Mounts} ->
            Needle = unicode:characters_to_binary([" ", Mount, " "]),
            binary:match(Mounts, Needle) =/= nomatch;
        _ ->
            false
    end.

persistent_store(Mount, Opts) ->
    Source = primary_lmdb_store(Opts),
    Name = filename:join(Mount, ?DEFAULT_STORE),
    Source#{<<"name">> => Name}.

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
                    ok = elmdb:put(DestDB, Key, Value),
                    Acc + 1
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
            _ = collect(Port, []),
            ok;
        {error, _} ->
            ok
    end.

run(Program, Args) ->
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
            collect(Port, []);
        {error, _} = Error ->
            Error
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Acc, Data]);
        {Port, {exit_status, 0}} ->
            {ok, iolist_to_binary(Acc)};
        {Port, {exit_status, Status}} ->
            {error, #{<<"exit-status">> => Status,
                      <<"output">> => iolist_to_binary(Acc)}}
    after 120000 ->
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
