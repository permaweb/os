%%% @doc Docker-backed PermawebOS Unix-tool execution adapter.
-module(lib_permawebos_docker).
-include_lib("kernel/include/file.hrl").
-export([
    read/3,
    write/3,
    append/3,
    edit/3,
    glob/3,
    grep/3,
    bash/3,
    bash_session/3,
    tool_keys/1,
    readiness/1,
    volume/1
]).
-export([list_files/3, serve_file/3]).
-export([
    handle/3,
    prepare_member/3,
    container_read/3,
    container_write/4,
    container_list_dir/3,
    exec/6
]).
-export([stop/2, destroy/2]).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEVICE, <<"docker@1.0">>).
-define(DEFAULT_MEMORY, <<"512m">>).
-define(DEFAULT_CPUS, <<"1.0">>).
-define(DEFAULT_PIDS, 256).
-define(DEFAULT_STORAGE, <<"512m">>).
-define(DEFAULT_TMPFS, <<"64m">>).
-define(DEFAULT_VOLUME, <<"ephemeral">>).
-define(DOCKER_HOST, <<"unix:///run/lapee/docker-runtime/state/engine.sock">>).
-define(MEMBER_ROOT, <<"/run/lapee/docker-runtime/members">>).
-define(TRANSFER_ROOT, <<"/run/lapee/docker-runtime/transfer">>).
-define(MAX_COMMAND_OUTPUT, 2 * 1024 * 1024).
-define(ACTION(Action),
    Action(_Base, Req, Opts) ->
        handle(Action, Req, Opts)
).

?ACTION(read).
?ACTION(write).
?ACTION(append).
?ACTION(edit).
?ACTION(glob).
?ACTION(grep).
?ACTION(bash).
?ACTION(bash_session).

handle(Action, Req, Opts) ->
    lib_permawebos_execution:handle(
        Action,
        ?DEVICE,
        ?MODULE,
        Req,
        force_backend(Opts)
    ).

tool_keys(Action) ->
    lib_permawebos_execution:tool_keys(Action).

list_files(MemberId, Path, Opts) ->
    lib_permawebos_execution:list_files(MemberId, Path, force_backend(Opts)).

serve_file(MemberId, Path, Opts) ->
    lib_permawebos_execution:serve_file(MemberId, Path, force_backend(Opts)).

%% @doc Bind the member's immutable instance policy before a file or session
%% helper can create its container with the fail-closed default.
prepare_member(MemberId, DisableNetwork, Opts) ->
    with_container(
        MemberId,
        DisableNetwork,
        force_backend(Opts),
        fun(_Spec) -> ok end
    ).

exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, Opts) ->
    docker_exec(
        MemberId,
        Cwd,
        Command,
        TimeoutMs,
        DisableNetwork,
        force_backend(Opts)
    ).

force_backend(Opts) ->
    Opts#{
        <<"execution-device">> => ?DEVICE,
        execution_backend => ?MODULE,
        execution_default_allow_network => false
    }.

%% @doc Fail closed until the private daemon and configured local image exist.
readiness(Opts) ->
    case volume(Opts) of
        {error, _Volume, Message} ->
            {error, 503, Message};
        {ok, _Volume} ->
            readiness_ephemeral(Opts)
    end.

readiness_ephemeral(Opts) ->
    case private_docker_host() of
        {error, Message} ->
            {error, 503, Message};
        {ok, _Host} ->
            case configuration(Opts) of
                {error, Message} ->
                    {error, 503, Message};
                {ok, Config} ->
                    case daemon_capabilities() of
                        {ok, _Capabilities} ->
                            readiness_image(Config);
                        {error, Message} ->
                            {error, 503, Message}
                    end
            end
    end.

readiness_image(Config) ->
    Image = maps:get(image, Config),
    case image_identity(Image) of
        {ok, ImageId} ->
            {ok,
                #{
                    <<"image">> => Image,
                    <<"image-id">> => ImageId,
                    <<"network-default">> => <<"disabled">>,
                    <<"volume">> => maps:get(volume, Config)
                }};
        {error, Message} ->
            {error, 503, Message}
    end.

docker_exec(MemberId, Cwd, Command, TimeoutMs, DisableNetwork, Opts) ->
    case with_container(
        MemberId,
        DisableNetwork,
        Opts,
        fun(Spec) ->
            Args = container_exec_args(
                maps:get(name, Spec),
                [<<"-w">>, Cwd],
                [<<"bash">>, <<"-lc">>, Command]
            ),
            case run_command(<<"docker">>, Args, TimeoutMs) of
                {ok, Output, ExitCode} ->
                    {ok, Output, ExitCode};
                {exit, 125, Output} ->
                    {error,
                        500,
                        append_output(
                            <<"Docker exec failed for the configured image.">>,
                            Output
                        )};
                {exit, ExitCode, Output} ->
                    {ok, Output, ExitCode};
                {timeout, Output} ->
                    {error, 408, append_output(<<"Command timed out.">>, Output)};
                {error, 503, Message} ->
                    {error, 503, Message}
            end
        end
    ) of
        {error, Status, Message} ->
            {error, Status, Message};
        Other ->
            Other
    end.

with_container(MemberId, NetworkPolicy, Opts, Fun) ->
    with_member_lock(
        MemberId,
        fun() ->
            case resolve_spec(MemberId, Opts) of
                {error, Status, Message} ->
                    {error, Status, Message};
                {ok, Spec} ->
                    case ensure_container(Spec, NetworkPolicy) of
                        {ok, BoundSpec} -> Fun(BoundSpec);
                        {error, Status, Message} ->
                            {error, Status, Message};
                        {error, Message} -> {error, 503, Message}
                    end
            end
        end
    ).

with_member_lock(MemberId, Fun) ->
    global:trans(
        {{?MODULE, container_name(MemberId)}, self()},
        Fun
    ).

resolve_spec(MemberId, Opts) ->
    case private_docker_host() of
        {error, Message} ->
            {error, 503, Message};
        {ok, _Host} ->
            case configuration(Opts) of
                {error, Message} ->
                    {error, 503, Message};
                {ok, Config} ->
                    case daemon_capabilities() of
                        {error, Message} ->
                            {error, 503, Message};
                        {ok, Capabilities} ->
                            Image = maps:get(image, Config),
                            case image_identity(Image) of
                                {error, Message} ->
                                    {error, 503, Message};
                                {ok, ImageId} ->
                                    MemberHash = member_hash(MemberId),
                                    Workspace = join_path(?MEMBER_ROOT, MemberHash),
                                    Spec0 =
                                        maps:merge(
                                            Config,
                                            Capabilities#{
                                                image_id => ImageId,
                                                member_hash => MemberHash,
                                                name => container_name(MemberId),
                                                workspace => Workspace,
                                                transfer_root => ?TRANSFER_ROOT
                                            }
                                        ),
                                    {ok, Spec0}
                            end
                    end
            end
    end.

daemon_capabilities() ->
    case docker_command(
        [
            <<"info">>,
            <<"--format">>,
            <<"{{.MemoryLimit}}\t{{.SwapLimit}}">>
        ],
        5000,
        fun(_Code, Output) ->
            {error,
                append_output(
                    <<"private Docker daemon is not healthy.">>,
                    Output
                )}
        end,
        <<"private Docker daemon readiness timed out.">>
    ) of
        {ok, Output} -> parse_daemon_capabilities(trim(Output));
        {error, _} = Error -> Error
    end.

parse_daemon_capabilities(<<"true\ttrue">>) ->
    {ok, #{ swap_limit => true }};
parse_daemon_capabilities(<<"true\tfalse">>) ->
    {ok, #{ swap_limit => false }};
parse_daemon_capabilities(<<"false\t", _/binary>>) ->
    {error, <<"private Docker daemon does not enforce memory limits.">>};
parse_daemon_capabilities(_) ->
    {error, <<"private Docker daemon returned invalid resource capabilities.">>}.

configuration(Opts) ->
    case volume(Opts) of
        {ok, Volume} -> configuration_ephemeral(Volume, Opts);
        {error, _Volume, Message} -> {error, Message}
    end.

configuration_ephemeral(Volume, Opts) ->
    Image = configured_value(
        <<"permawebos-docker-image">>,
        "PERMAWEBOS_DOCKER_IMAGE",
        undefined,
        Opts
    ),
    Memory = configured_value(
        <<"permawebos-docker-memory">>,
        "PERMAWEBOS_DOCKER_MEMORY",
        ?DEFAULT_MEMORY,
        Opts
    ),
    Cpus = configured_value(
        <<"permawebos-docker-cpus">>,
        "PERMAWEBOS_DOCKER_CPUS",
        ?DEFAULT_CPUS,
        Opts
    ),
    Pids = configured_value(
        <<"permawebos-docker-pids">>,
        "PERMAWEBOS_DOCKER_PIDS",
        ?DEFAULT_PIDS,
        Opts
    ),
    Storage = configured_value(
        <<"permawebos-docker-storage">>,
        "PERMAWEBOS_DOCKER_STORAGE",
        ?DEFAULT_STORAGE,
        Opts
    ),
    Tmpfs = configured_value(
        <<"permawebos-docker-tmpfs">>,
        "PERMAWEBOS_DOCKER_TMPFS",
        ?DEFAULT_TMPFS,
        Opts
    ),
    validate_configuration(
        #{
            volume => normalize_binary(Volume),
            image => normalize_binary(Image),
            memory => normalize_binary(Memory),
            cpus => normalize_binary(Cpus),
            pids => normalize_integer(Pids),
            storage => normalize_binary(Storage),
            tmpfs => normalize_binary(Tmpfs)
        }
    ).

configured_value(Key, EnvName, Default, Opts) ->
    EnvValue =
        case os:getenv(EnvName) of
            Value when is_list(Value), Value =/= [] -> hb_util:bin(Value);
            _ -> undefined
        end,
    lib_permawebos_execution_runtime:first_defined(
        [maps:get(Key, Opts, undefined), EnvValue, Default]
    ).

validate_configuration(#{ image := undefined }) ->
    {error, <<"permawebos-docker-image is not configured.">>};
validate_configuration(#{ image := <<>> }) ->
    {error, <<"permawebos-docker-image is not configured.">>};
validate_configuration(#{ image := <<"-", _/binary>> }) ->
    {error, <<"permawebos-docker-image is invalid.">>};
validate_configuration(Config) ->
    Validators =
        [
            {memory, fun valid_size/1},
            {cpus, fun valid_cpus/1},
            {pids, fun valid_pids/1},
            {storage, fun valid_size/1},
            {tmpfs, fun valid_size/1}
        ],
    case validate_fields(Validators, Config) of
        {ok, Validated} ->
            {ok,
                Validated#{
                    storage => canonical_size(maps:get(storage, Validated))
                }};
        Error ->
            Error
    end.

%% Zone is a valid declared mode, but it is deliberately unavailable until a
%% quota-enforced, executable member filesystem can be opened beneath the
%% matching zone@1.0 volume. Never fall back to the ephemeral workspace.
volume(Opts) ->
    Value = normalize_binary(
        configured_value(
            <<"permawebos-docker-volume">>,
            "PERMAWEBOS_DOCKER_VOLUME",
            ?DEFAULT_VOLUME,
            Opts
        )
    ),
    case Value of
        <<"ephemeral">> ->
            {ok, <<"ephemeral">>};
        <<"zone">> ->
            {error, <<"zone">>,
                <<"permawebos-docker-volume=zone is not available; "
                  "the Docker device will not fall back to ephemeral storage.">>};
        _ ->
            {error, <<"invalid">>,
                <<"permawebos-docker-volume must be ephemeral or zone.">>}
    end.

canonical_size(Value) ->
    {ok, Bytes} = parse_size_bytes(Value),
    integer_to_binary(Bytes).

validate_fields([], Config) ->
    {ok, Config};
validate_fields([{Key, Validator} | Rest], Config) ->
    case Validator(maps:get(Key, Config)) of
        true -> validate_fields(Rest, Config);
        false ->
            {error,
                <<"invalid Docker configuration for ",
                  (atom_to_binary(Key))/binary, ".">>}
    end.

valid_size(Value) when is_binary(Value) ->
    re:run(Value, <<"^[1-9][0-9]*([kKmMgG][bB]?)?$">>, [{capture, none}]) =:= match;
valid_size(_) ->
    false.

valid_cpus(Value) when is_binary(Value) ->
    case re:run(Value, <<"^[0-9]+([.][0-9]+)?$">>, [{capture, none}]) of
        match ->
            try binary_to_float(normalize_float(Value)) > 0.0
            catch _:_ -> false
            end;
        nomatch ->
            false
    end;
valid_cpus(_) ->
    false.

normalize_float(Value) ->
    case binary:match(Value, <<".">>) of
        nomatch -> <<Value/binary, ".0">>;
        _ -> Value
    end.

valid_pids(Value) ->
    is_integer(Value) andalso Value > 0 andalso Value =< 4096.

normalize_binary(undefined) -> undefined;
normalize_binary(Value) -> hb_util:bin(Value).

normalize_integer(Value) when is_integer(Value) -> Value;
normalize_integer(Value) ->
    lib_permawebos_execution_runtime:safe_int(Value, invalid).

private_docker_host() ->
    case os:getenv("DOCKER_HOST") of
        Host when is_list(Host), Host =/= [] ->
            private_docker_host_value(hb_util:bin(Host));
        _ ->
            {error, <<"DOCKER_HOST must identify the private Docker Unix socket.">>}
    end.

private_docker_host_value(?DOCKER_HOST = Host) ->
    {ok, Host};
private_docker_host_value(_) ->
    {error, <<"DOCKER_HOST must identify the private LapEE Docker socket.">>}.

image_identity(Image) ->
    case docker_command(
        [
            <<"image">>,
            <<"inspect">>,
            <<"--format">>,
            <<"{{.Id}}\t{{json (index .Config \"Volumes\")}}">>,
            Image
        ],
        10000,
        fun(_Code, Output) ->
            {error,
                append_output(
                    <<"configured Docker image is not available locally.">>,
                    Output
                )}
        end,
        <<"Docker image inspection timed out.">>
    ) of
        {ok, Output} -> parse_image_identity(trim(Output));
        {error, _} = Error ->
            Error
    end.

parse_image_identity(Output) ->
    case binary:split(Output, <<"\t">>, [global]) of
        [<<>>, _Volumes] ->
            {error, <<"configured Docker image has no local identity.">>};
        [ImageId, Volumes] when Volumes =:= <<"null">>; Volumes =:= <<"{}">> ->
            {ok, ImageId};
        [_ImageId, _Volumes] ->
            {error, <<"configured Docker image declares unsupported volumes.">>};
        _ ->
            {error, <<"configured Docker image metadata is invalid.">>}
    end.

member_hash(MemberId) ->
    hb_util:human_id(crypto:hash(sha256, hb_util:bin(MemberId))).

container_name(MemberId) ->
    Hash = member_hash(MemberId),
    <<Prefix:24/binary, _/binary>> = Hash,
    <<"permawebos-docker-", Prefix/binary>>.

config_fingerprint(Spec) ->
    Bytes =
        iolist_to_binary(
            [
                <<"docker@1.0\nimage-id=">>, maps:get(image_id, Spec),
                <<"\nvolume=">>, maps:get(volume, Spec),
                <<"\nnetwork=">>, maps:get(network, Spec),
                <<"\nmemory=">>, maps:get(memory, Spec),
                <<"\nswap-limit=">>, atom_to_binary(maps:get(swap_limit, Spec)),
                <<"\ncpus=">>, maps:get(cpus, Spec),
                <<"\npids=">>, integer_to_binary(maps:get(pids, Spec)),
                <<"\nstorage=">>, maps:get(storage, Spec),
                <<"\ntmpfs=">>, maps:get(tmpfs, Spec),
                <<"\nworkspace=">>, maps:get(workspace, Spec),
                <<"\nworkspace-destination=/root\nmount-policy=root-and-tmpfs-only">>,
                <<"\nread-only=true\ncap-drop=ALL\nno-new-privileges=true">>,
                <<"\nuser=0:0\nworkdir=/root\nentrypoint=sleep">>,
                <<"\ncommand=infinity\nhealthcheck=disabled\n">>
            ]
        ),
    hb_util:human_id(crypto:hash(sha256, Bytes)).

join_path(Root, Name) ->
    <<Root/binary, "/", Name/binary>>.

stop(MemberId, _Opts) ->
    with_member_lock(
        MemberId,
        fun() ->
            case private_docker_host() of
                {error, Message} -> {error, Message};
                {ok, _} -> stop_container(container_name(MemberId))
            end
        end
    ).

stop_container(Name) ->
    case container_status(Name) of
        absent -> ok;
        exited -> ok;
        {error, _} = Error -> Error;
        _ ->
            docker_ok(
                [<<"stop">>, <<"--time">>, <<"10">>, Name],
                15000,
                <<"failed to stop Docker member container.">>,
                <<"Docker stop timed out.">>
            )
    end.

destroy(MemberId, _Opts) ->
    with_member_lock(
        MemberId,
        fun() ->
            case private_docker_host() of
                {error, Message} -> {error, Message};
                {ok, _} ->
                    case destroy_container(container_name(MemberId)) of
                        ok -> destroy_member_workspace(MemberId);
                        Error -> Error
                    end
            end
        end
    ).

destroy_container(Name) ->
    case container_status(Name) of
        absent -> ok;
        {error, _} = Error -> Error;
        _ ->
            docker_ok(
                [<<"rm">>, <<"--force">>, <<"--volumes">>, Name],
                15000,
                <<"failed to destroy Docker member container.">>,
                <<"Docker remove timed out.">>
            )
    end.

%% Each member owns one host-controlled tmpfs. The mount survives container
%% stop/start, bounds the actual writable workspace, and is never selected by
%% request data.
ensure_member_workspace(Spec) ->
    Workspace = maps:get(workspace, Spec),
    case ensure_private_directory(?MEMBER_ROOT) of
        {error, _} = Error ->
            Error;
        ok ->
            case workspace_mount(Workspace) of
                absent -> mount_member_workspace(Spec);
                {ok, SizeBytes} -> verify_workspace_size(Spec, SizeBytes);
                {error, _} = Error -> Error
            end
    end.

verify_member_workspace(Spec) ->
    case workspace_mount(maps:get(workspace, Spec)) of
        {ok, SizeBytes} -> verify_workspace_size(Spec, SizeBytes);
        absent -> {error, <<"Docker member workspace mount is missing.">>};
        {error, _} = Error -> Error
    end.

verify_workspace_size(Spec, ActualBytes) ->
    case parse_size_bytes(maps:get(storage, Spec)) of
        {ok, ActualBytes} -> ok;
        {ok, _ExpectedBytes} ->
            {error, <<"Docker member workspace has the wrong storage limit.">>};
        error ->
            {error, <<"Docker member workspace storage limit is invalid.">>}
    end.

mount_member_workspace(Spec) ->
    Workspace = maps:get(workspace, Spec),
    case ensure_private_directory(Workspace) of
        {error, _} = Error ->
            Error;
        ok ->
            case file:list_dir(binary_to_list(Workspace)) of
                {ok, []} ->
                    MountOptions =
                        <<"size=", (maps:get(storage, Spec))/binary,
                          ",nosuid,nodev,mode=0700">>,
                    Source = <<"permawebos-member-", (maps:get(member_hash, Spec))/binary>>,
                    case host_command_ok(
                        <<"mount">>,
                        [
                            <<"-t">>, <<"tmpfs">>,
                            <<"-o">>, MountOptions,
                            Source,
                            Workspace
                        ],
                        10000,
                        <<"failed to mount the bounded Docker member workspace.">>,
                        <<"Docker member workspace mount timed out.">>
                    ) of
                        ok -> verify_member_workspace(Spec);
                        Error -> Error
                    end;
                {ok, _Entries} ->
                    {error, <<"unmounted Docker member workspace is not empty.">>};
                {error, Reason} ->
                    {error, lib_permawebos_execution_runtime:safe_bin(Reason)}
            end
    end.

destroy_member_workspace(MemberId) ->
    Workspace = join_path(?MEMBER_ROOT, member_hash(MemberId)),
    case workspace_mount(Workspace) of
        absent -> remove_empty_workspace(Workspace);
        {error, _} = Error -> Error;
        {ok, _SizeBytes} ->
            case host_command_ok(
                <<"umount">>,
                [Workspace],
                10000,
                <<"failed to unmount the Docker member workspace.">>,
                <<"Docker member workspace unmount timed out.">>
            ) of
                ok ->
                    case workspace_mount(Workspace) of
                        absent -> remove_empty_workspace(Workspace);
                        _ -> {error, <<"Docker member workspace remained mounted.">>}
                    end;
                Error -> Error
            end
    end.

remove_empty_workspace(Workspace) ->
    case file:del_dir(binary_to_list(Workspace)) of
        ok -> ok;
        {error, enoent} -> ok;
        {error, Reason} when Reason =:= eexist; Reason =:= enotempty ->
            {error, <<"Docker member workspace is not empty after unmount.">>};
        {error, Reason} ->
            {error, lib_permawebos_execution_runtime:safe_bin(Reason)}
    end.

workspace_mount(Workspace) ->
    case file:read_file("/proc/self/mountinfo") of
        {ok, MountInfo} ->
            workspace_mount_lines(
                Workspace,
                binary:split(MountInfo, <<"\n">>, [global])
            );
        {error, Reason} ->
            {error,
                append_output(
                    <<"could not inspect Docker member workspace mounts.">>,
                    lib_permawebos_execution_runtime:safe_bin(Reason)
                )}
    end.

workspace_mount_lines(_Workspace, []) ->
    absent;
workspace_mount_lines(Workspace, [Line | Rest]) ->
    case parse_mountinfo_line(Line) of
        {ok, Workspace, <<"tmpfs">>, Options} ->
            case mount_size(Options) of
                {ok, SizeBytes} -> {ok, SizeBytes};
                error -> {error, <<"Docker member tmpfs has no size limit.">>}
            end;
        {ok, Workspace, _OtherFilesystem, _Options} ->
            {error, <<"Docker member workspace is not a tmpfs mount.">>};
        _ ->
            workspace_mount_lines(Workspace, Rest)
    end.

parse_mountinfo_line(<<>>) ->
    false;
parse_mountinfo_line(Line) ->
    case binary:split(Line, <<" - ">>) of
        [Before, After] ->
            BeforeFields = binary:split(Before, <<" ">>, [global, trim_all]),
            AfterFields = binary:split(After, <<" ">>, [global, trim_all]),
            case {BeforeFields, AfterFields} of
                {[_, _, _, _, MountPoint | _], [Filesystem, _Source, Options | _]} ->
                    {ok, MountPoint, Filesystem, Options};
                _ ->
                    false
            end;
        _ ->
            false
    end.

mount_size(Options) ->
    mount_size_options(binary:split(Options, <<",">>, [global])).

mount_size_options([]) ->
    error;
mount_size_options([<<"size=", Value/binary>> | _]) ->
    parse_size_bytes(Value);
mount_size_options([_ | Rest]) ->
    mount_size_options(Rest).

parse_size_bytes(Value) when is_binary(Value) ->
    Lower0 = hb_util:bin(string:lowercase(binary_to_list(Value))),
    Lower = strip_optional_b(Lower0),
    case Lower of
        <<>> -> error;
        _ ->
            LastIndex = byte_size(Lower) - 1,
            <<Number:LastIndex/binary, Suffix>> = Lower,
            case Suffix of
                $k -> size_number(Number, 1024);
                $m -> size_number(Number, 1024 * 1024);
                $g -> size_number(Number, 1024 * 1024 * 1024);
                Digit when Digit >= $0, Digit =< $9 -> size_number(Lower, 1);
                _ -> error
            end
    end;
parse_size_bytes(_) ->
    error.

strip_optional_b(<<>>) ->
    <<>>;
strip_optional_b(Value) ->
    case binary:last(Value) of
        $b -> binary:part(Value, 0, byte_size(Value) - 1);
        _ -> Value
    end.

size_number(<<>>, _Multiplier) ->
    error;
size_number(Number, Multiplier) ->
    try
        Bytes = binary_to_integer(Number) * Multiplier,
        case Bytes > 0 of true -> {ok, Bytes}; false -> error end
    catch _:_ ->
        error
    end.

ensure_container(Spec, NetworkPolicy) ->
    Name = maps:get(name, Spec),
    State = container_status(Name),
    case bind_network_policy(Spec, State, NetworkPolicy) of
        {error, _, _} = Error ->
            Error;
        {error, _} = Error ->
            Error;
        {ok, BoundSpec} when State =:= absent ->
            case ensure_member_workspace(BoundSpec) of
                ok ->
                    case create_container(BoundSpec) of
                        ok -> {ok, BoundSpec};
                        Error -> Error
                    end;
                Error -> Error
            end;
        {ok, BoundSpec} ->
            case verify_member_workspace(BoundSpec) of
                ok ->
                    case verify_container(BoundSpec) of
                        ok ->
                            DisableNetwork = maps:get(disable_network, BoundSpec),
                            case verify_network_policy(Name, not DisableNetwork) of
                                ok ->
                                    case activate_container(Name, State) of
                                        ok ->
                                            case verify_network_policy(
                                                Name,
                                                not DisableNetwork
                                            ) of
                                                ok -> {ok, BoundSpec};
                                                Error -> Error
                                            end;
                                        Error -> Error
                                    end;
                                Error -> Error
                            end;
                        Error -> Error
                    end;
                Error ->
                    Error
            end
    end.

bind_network_policy(Spec, absent, preserve) ->
    {ok, bind_network_policy(Spec, true)};
bind_network_policy(Spec, absent, DisableNetwork)
        when is_boolean(DisableNetwork) ->
    {ok, bind_network_policy(Spec, DisableNetwork)};
bind_network_policy(_Spec, {error, _} = Error, _Requested) ->
    Error;
bind_network_policy(Spec, _State, Requested) ->
    Name = maps:get(name, Spec),
    case stored_network_policy(Name) of
        {error, _} = Error ->
            Error;
        {ok, DisableNetwork} ->
            bind_stored_network_policy(Spec, DisableNetwork, Requested)
    end.

bind_stored_network_policy(Spec, DisableNetwork, Requested)
        when Requested =:= preserve; Requested =:= DisableNetwork ->
    {ok, bind_network_policy(Spec, DisableNetwork)};
bind_stored_network_policy(_Spec, _DisableNetwork, _Requested) ->
    {error,
        409,
        <<"Docker member network policy is immutable for this instance.">>}.

bind_network_policy(Spec, DisableNetwork) ->
    Network =
        case DisableNetwork of
            true -> <<"disabled">>;
            false -> <<"enabled">>
        end,
    BoundSpec = Spec#{
        disable_network => DisableNetwork,
        network => Network
    },
    BoundSpec#{ fingerprint => config_fingerprint(BoundSpec) }.

stored_network_policy(Name) ->
    case docker_command(
        [
            <<"inspect">>,
            <<"--format">>,
            <<"{{index .Config.Labels \"org.permawebos.execution.network\"}}">>,
            Name
        ],
        5000,
        fun(_Code, Output) ->
            {error,
                append_output(
                    <<"failed to inspect Docker member network policy.">>,
                    Output
                )}
        end,
        <<"Docker network policy inspection timed out.">>
    ) of
        {ok, Output} ->
            case trim(Output) of
                <<"disabled">> -> {ok, true};
                <<"enabled">> -> {ok, false};
                _ ->
                    {error,
                        <<"Docker member container has no valid immutable network policy.">>}
            end;
        {error, _} = Error ->
            Error
    end.

activate_container(_Name, running) ->
    ok;
activate_container(Name, paused) ->
    case docker_ok(
        [<<"unpause">>, Name],
        10000,
        <<"failed to unpause Docker member container.">>,
        <<"Docker unpause timed out.">>
    ) of
        ok -> verify_running(Name);
        Error -> Error
    end;
activate_container(Name, State)
        when State =:= exited; State =:= created; State =:= dead ->
    case docker_ok(
        [<<"start">>, Name],
        15000,
        <<"failed to restart Docker member container.">>,
        <<"Docker start timed out.">>
    ) of
        ok -> verify_running(Name);
        Error -> Error
    end;
activate_container(_Name, restarting) ->
    {error, <<"Docker member container is unexpectedly restarting.">>};
activate_container(_Name, Other) ->
    {error,
        lib_permawebos_execution_runtime:safe_bin(
            io_lib:format("unexpected Docker member state: ~p", [Other])
        )}.

verify_running(Name) ->
    case container_status(Name) of
        running -> ok;
        State ->
            {error,
                lib_permawebos_execution_runtime:safe_bin(
                    io_lib:format(
                        "Docker member container did not enter running state: ~p",
                        [State]
                    )
                )}
    end.

verify_container(Spec) ->
    Name = maps:get(name, Spec),
    case container_metadata(Name) of
        {error, _} = Error ->
            Error;
        {ok, Metadata} ->
            Expected = expected_container_metadata(Spec),
            case Metadata =:= Expected of
                true -> ok;
                false ->
                    Mismatches = metadata_mismatch_keys(Expected, Metadata),
                    {error,
                        <<"existing Docker member container does not match the requested image, member, workspace, or security configuration; mismatched fields: ",
                          Mismatches/binary, ".">>}
            end
    end.

metadata_mismatch_keys(Expected, Actual) ->
    Keys = lists:usort(maps:keys(Expected) ++ maps:keys(Actual)),
    Names =
        [
            binary:replace(
                atom_to_binary(Key),
                <<"_">>,
                <<"-">>,
                [global]
            )
         || Key <- Keys,
            maps:get(Key, Expected, '$missing') =/=
                maps:get(Key, Actual, '$missing')
        ],
    iolist_to_binary(lists:join(<<", ">>, Names)).

container_metadata(Name) ->
    Format =
        <<"{{.Image}}\t{{index .Config.Labels \"org.permawebos.execution.device\"}}\t",
          "{{index .Config.Labels \"org.permawebos.execution.member\"}}\t",
          "{{index .Config.Labels \"org.permawebos.execution.config\"}}\t",
          "{{index .Config.Labels \"org.permawebos.execution.network\"}}\t",
          "{{range .Mounts}}{{if eq .Destination \"/root\"}}{{.Type}}={{.Source}}:",
          "{{if .RW}}rw{{else}}ro{{end}}{{end}}{{end}}\t",
          "{{range .Mounts}}{{if and (ne .Destination \"/root\") (ne .Destination \"/tmp\")}}{{.Destination}};{{end}}{{end}}\t",
          "{{.HostConfig.ReadonlyRootfs}}\t",
          "{{.HostConfig.Memory}}\t{{.HostConfig.MemorySwap}}\t",
          "{{.HostConfig.NanoCpus}}\t{{.HostConfig.PidsLimit}}\t",
          "{{range .HostConfig.CapDrop}}{{.}};{{end}}\t",
          "{{range .HostConfig.CapAdd}}{{.}};{{end}}\t",
          "{{range .HostConfig.SecurityOpt}}{{.}};{{end}}\t",
          "{{.HostConfig.Init}}\t{{.HostConfig.RestartPolicy.Name}}\t",
          "{{index .HostConfig.Tmpfs \"/tmp\"}}\t",
          "{{.HostConfig.NetworkMode}}\t{{.HostConfig.Privileged}}\t",
          "{{.HostConfig.PidMode}}\t{{.HostConfig.IpcMode}}\t",
          "{{range .HostConfig.Devices}}{{.PathOnHost}}>{{.PathInContainer}};{{end}}\t",
          "{{range .HostConfig.DeviceRequests}}device;{{end}}\t",
          "{{.Config.User}}\t{{json .Config.Entrypoint}}\t",
          "{{json .Config.Cmd}}\t{{json .Config.Healthcheck}}\t",
          "{{.Config.WorkingDir}}\tcomplete">>,
    case docker_command(
        [<<"inspect">>, <<"--format">>, Format, Name],
        5000,
        fun(_Code, Output) ->
            {error,
                append_output(
                    <<"failed to inspect Docker member metadata.">>,
                    Output
                )}
        end,
        <<"Docker metadata inspection timed out.">>
    ) of
        {ok, Output} -> parse_container_metadata(trim(Output));
        {error, _} = Error -> Error
    end.

parse_container_metadata(Output) ->
    case binary:split(Output, <<"\t">>, [global]) of
        [
            ImageId,
            Device,
            MemberHash,
            Fingerprint,
            Network,
            WorkspaceMount,
            UnexpectedMounts,
            ReadOnly,
            Memory,
            MemorySwap,
            NanoCpus,
            PidsLimit,
            CapDrop,
            CapAdd,
            SecurityOpt,
            Init,
            Restart,
            Tmpfs,
            NetworkMode,
            Privileged,
            PidMode,
            IpcMode,
            Devices,
            DeviceRequests,
            User,
            Entrypoint,
            Command,
            Healthcheck,
            WorkingDir,
            <<"complete">>
        ] ->
            {ok,
                #{
                    image_id => ImageId,
                    device => Device,
                    member_hash => MemberHash,
                    fingerprint => Fingerprint,
                    network => Network,
                    workspace_mount => WorkspaceMount,
                    unexpected_mounts => UnexpectedMounts,
                    read_only => ReadOnly,
                    memory => Memory,
                    memory_swap => MemorySwap,
                    nano_cpus => NanoCpus,
                    pids_limit => PidsLimit,
                    cap_drop => CapDrop,
                    cap_add => CapAdd,
                    security_opt => SecurityOpt,
                    init => Init,
                    restart => Restart,
                    tmpfs => Tmpfs,
                    network_mode => NetworkMode,
                    privileged => Privileged,
                    pid_mode => PidMode,
                    ipc_mode => IpcMode,
                    devices => Devices,
                    device_requests => DeviceRequests,
                    user => User,
                    entrypoint => Entrypoint,
                    command => Command,
                    healthcheck => Healthcheck,
                    working_dir => WorkingDir
                }};
        _ ->
            {error, <<"Docker member metadata is incomplete.">>}
    end.

expected_container_metadata(Spec) ->
    {ok, MemoryBytes} = parse_size_bytes(maps:get(memory, Spec)),
    #{
        image_id => maps:get(image_id, Spec),
        device => ?DEVICE,
        member_hash => maps:get(member_hash, Spec),
        fingerprint => maps:get(fingerprint, Spec),
        network => maps:get(network, Spec),
        workspace_mount =>
            <<"bind=", (maps:get(workspace, Spec))/binary, ":rw">>,
        unexpected_mounts => <<>>,
        read_only => <<"true">>,
        memory => integer_to_binary(MemoryBytes),
        memory_swap =>
            case maps:get(swap_limit, Spec) of
                true -> integer_to_binary(MemoryBytes);
                false -> <<"-1">>
            end,
        nano_cpus => integer_to_binary(cpu_nanos(maps:get(cpus, Spec))),
        pids_limit => integer_to_binary(maps:get(pids, Spec)),
        cap_drop => <<"ALL;">>,
        cap_add => <<>>,
        security_opt => <<"no-new-privileges:true;">>,
        init => <<"true">>,
        restart => <<"no">>,
        tmpfs =>
            <<"rw,nosuid,nodev,noexec,size=", (maps:get(tmpfs, Spec))/binary>>,
        network_mode => <<"bridge">>,
        privileged => <<"false">>,
        pid_mode => <<>>,
        ipc_mode => <<"private">>,
        devices => <<>>,
        device_requests => <<>>,
        user => <<"0:0">>,
        entrypoint => <<"[\"sleep\"]">>,
        command => <<"[\"infinity\"]">>,
        healthcheck => <<"{\"Test\":[\"NONE\"]}">>,
        working_dir => <<"/root">>
    }.

cpu_nanos(Cpus) ->
    trunc(binary_to_float(normalize_float(Cpus)) * 1000000000).

create_container(Spec) ->
    Name = maps:get(name, Spec),
    case docker_ok(
        create_args(Spec),
        30000,
        <<"failed to create hardened Docker member container.">>,
        <<"Docker container creation timed out.">>
    ) of
        ok ->
            case finish_container_creation(Spec) of
                ok -> ok;
                {error, _} = Error -> cleanup_failed_container(Name, Error)
            end;
        Error ->
            Error
    end.

finish_container_creation(Spec) ->
    Name = maps:get(name, Spec),
    case verify_container(Spec) of
        ok ->
            % Docker cannot connect a container created with the private
            % `none' network to a bridge later. Create it on the bridge
            % without starting it and apply the immutable instance policy
            % before executing the image.
            DisableNetwork = maps:get(disable_network, Spec),
            case apply_initial_network_policy(Name, DisableNetwork) of
                ok ->
                    case activate_container(Name, created) of
                        ok -> verify_network_policy(Name, not DisableNetwork);
                        Error -> Error
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

cleanup_failed_container(Name, {error, Original}) ->
    case docker_ok(
        [<<"rm">>, <<"--force">>, <<"--volumes">>, Name],
        15000,
        <<"failed to remove an unusable Docker member container.">>,
        <<"Docker cleanup timed out for an unusable member container.">>
    ) of
        ok -> {error, Original};
        {error, Cleanup} ->
            {error, append_output(Original, Cleanup)}
    end.

create_args(Spec) ->
    Name = maps:get(name, Spec),
    Memory = maps:get(memory, Spec),
    Workspace = maps:get(workspace, Spec),
    Mount =
        <<"type=bind,src=", Workspace/binary,
          ",dst=/root,bind-propagation=rprivate">>,
    Tmpfs =
        <<"/tmp:rw,nosuid,nodev,noexec,size=", (maps:get(tmpfs, Spec))/binary>>,
    [
        <<"create">>,
        <<"--pull=never">>,
        <<"--name">>, Name,
        <<"--hostname">>, Name,
        <<"--user=0:0">>,
        <<"--workdir=/root">>,
        <<"--entrypoint=sleep">>,
        <<"--no-healthcheck">>,
        <<"--init">>,
        <<"--restart=no">>,
        <<"--network=bridge">>,
        <<"--read-only">>,
        <<"--cap-drop=ALL">>,
        <<"--security-opt=no-new-privileges:true">>,
        <<"--memory">>, Memory,
        <<"--memory-swap">>, Memory,
        <<"--cpus">>, maps:get(cpus, Spec),
        <<"--pids-limit">>, integer_to_binary(maps:get(pids, Spec)),
        <<"--tmpfs">>, Tmpfs,
        <<"--mount">>, Mount,
        <<"--label">>, <<"org.permawebos.execution.device=", ?DEVICE/binary>>,
        <<"--label">>,
            <<"org.permawebos.execution.member=", (maps:get(member_hash, Spec))/binary>>,
        <<"--label">>,
            <<"org.permawebos.execution.config=", (maps:get(fingerprint, Spec))/binary>>,
        <<"--label">>,
            <<"org.permawebos.execution.network=", (maps:get(network, Spec))/binary>>,
        maps:get(image, Spec),
        <<"infinity">>
    ].

apply_initial_network_policy(Name, DisableNetwork) ->
    case container_networks(Name) of
        {error, _} = Error ->
            Error;
        {ok, Attached} ->
            AllowNetwork = not DisableNetwork,
            case canonicalize_networks(Name, Attached, AllowNetwork) of
                ok -> verify_network_policy(Name, AllowNetwork);
                Error -> Error
            end
    end.

canonicalize_networks(Name, Attached, false) ->
    disconnect_networks(Name, [Net || Net <- Attached, Net =/= <<"none">>]);
canonicalize_networks(Name, Attached, true) ->
    case disconnect_networks(Name, [Net || Net <- Attached, Net =/= <<"bridge">>]) of
        ok ->
            case lists:member(<<"bridge">>, Attached) of
                true -> ok;
                false ->
                    docker_ok(
                        [<<"network">>, <<"connect">>, <<"bridge">>, Name],
                        10000,
                        <<"failed to enable the Docker bridge.">>,
                        <<"Docker network connect timed out.">>
                    )
            end;
        Error ->
            Error
    end.

disconnect_networks(_Name, []) ->
    ok;
disconnect_networks(Name, [Network | Rest]) ->
    case docker_ok(
        [<<"network">>, <<"disconnect">>, <<"--force">>, Network, Name],
        10000,
        <<"failed to disable a Docker member network.">>,
        <<"Docker network disconnect timed out.">>
    ) of
        ok -> disconnect_networks(Name, Rest);
        Error -> Error
    end.

verify_network_policy(Name, AllowNetwork) ->
    case container_networks(Name) of
        {error, _} = Error ->
            Error;
        {ok, Attached} ->
            Allowed =
                case AllowNetwork of
                    true -> Attached =:= [<<"bridge">>];
                    false ->
                        Attached =:= [] orelse Attached =:= [<<"none">>]
                end,
            case Allowed of
                true -> ok;
                false ->
                    {error, <<"Docker did not apply the requested network policy.">>}
            end
    end.

container_networks(Name) ->
    case docker_command(
        [
            <<"inspect">>,
            <<"--format">>,
            <<"{{range $net, $_ := .NetworkSettings.Networks}}{{$net}} {{end}}">>,
            Name
        ],
        5000,
        fun(_Code, Output) ->
            {error,
                append_output(
                    <<"failed to inspect Docker member networks.">>,
                    Output
                )}
        end,
        <<"Docker network inspection timed out.">>
    ) of
        {ok, Output} ->
            {ok,
                lists:sort(
                    binary:split(trim(Output), <<" ">>, [global, trim_all])
                )};
        {error, _} = Error ->
            Error
    end.

container_status(Name) ->
    case docker_command(
        [<<"inspect">>, <<"--format">>, <<"{{.State.Status}}">>, Name],
        5000,
        fun(_Code, Output) -> inspect_status_error(Output) end,
        <<"Docker container inspection timed out.">>
    ) of
        {ok, Output} -> parse_status(Output);
        Other -> Other
    end.

inspect_status_error(Output) ->
    Lower = hb_util:bin(string:lowercase(binary_to_list(Output))),
    case binary:match(Lower, <<"no such object">>) =/= nomatch orelse
         binary:match(Lower, <<"no such container">>) =/= nomatch of
        true -> absent;
        false ->
            {error,
                append_output(
                    <<"failed to inspect Docker member state.">>,
                    Output
                )}
    end.

parse_status(Output) ->
    Status = trim(Output),
    maps:get(
        Status,
        #{
            <<"running">> => running,
            <<"paused">> => paused,
            <<"exited">> => exited,
            <<"created">> => created,
            <<"restarting">> => restarting,
            <<"dead">> => dead
        },
        {error, <<"unknown Docker member state: ", Status/binary>>}
    ).

container_read(MemberId, ContainerPath, Opts) ->
    container_command(
        MemberId,
        preserve,
        Opts,
        fun(Name) ->
            container_exec_args(Name, [], [<<"cat">>, <<"--">>, ContainerPath])
        end,
        30000,
        fun(_Code, Output) -> {error, classify_fs_error(Output)} end,
        <<"Docker file read timed out.">>,
        fun(Output) -> {ok, Output} end
    ).

classify_fs_error(Output) ->
    Lower = string:lowercase(binary_to_list(Output)),
    case {
        string:find(Lower, "no such file or directory"),
        string:find(Lower, "is a directory")
    } of
        {Found, _} when Found =/= nomatch -> enoent;
        {_, Found} when Found =/= nomatch -> eisdir;
        _ -> trim(Output)
    end.

container_write(MemberId, ContainerPath, Content, Opts) ->
    case with_container(
        MemberId,
        preserve,
        Opts,
        fun(Spec) ->
            Name = maps:get(name, Spec),
            ParentDir = hb_util:bin(filename:dirname(binary_to_list(ContainerPath))),
            case ensure_container_dir(Name, ParentDir) of
                ok ->
                    copy_into_container(
                        Name,
                        ContainerPath,
                        Content,
                        maps:get(transfer_root, Spec)
                    );
                Error ->
                    Error
            end
        end
    ) of
        {error, Status, Message} ->
            {error, Status, Message, #{}};
        Other ->
            Other
    end.

ensure_container_dir(Name, ParentDir) ->
    docker_ok(
        container_exec_args(Name, [], [<<"mkdir">>, <<"-p">>, <<"--">>, ParentDir]),
        10000,
        <<"failed to create a container workspace directory.">>,
        <<"Docker workspace mkdir timed out.">>
    ).

copy_into_container(Name, ContainerPath, Content, TransferRoot) ->
    case secure_temp_file(TransferRoot, Content, 4) of
        {error, Reason} ->
            {error,
                append_output(
                    <<"could not create a private Docker transfer file.">>,
                    lib_permawebos_execution_runtime:safe_bin(Reason)
                )};
        {ok, TempPath} ->
            try
                Destination = <<Name/binary, ":", ContainerPath/binary>>,
                docker_ok(
                    [<<"cp">>, TempPath, Destination],
                    30000,
                    <<"failed to copy content into the member workspace.">>,
                    <<"Docker copy timed out.">>
                )
            after
                file:delete(binary_to_list(TempPath))
            end
    end.

secure_temp_file(_Root, _Content, 0) ->
    {error, temporary_name_collision};
secure_temp_file(Root, Content, Attempts) ->
    case ensure_private_directory(Root) of
        {error, _} = Error ->
            Error;
        ok ->
            Name = secure_temp_name(),
            Path = join_path(Root, Name),
            case file:open(
                binary_to_list(Path),
                [write, binary, exclusive]
            ) of
                {ok, IoDevice} ->
                    Result = file:write(IoDevice, Content),
                    CloseResult = file:close(IoDevice),
                    case {Result, CloseResult} of
                        {ok, ok} ->
                            case file:change_mode(binary_to_list(Path), 8#600) of
                                ok -> {ok, Path};
                                {error, Reason} ->
                                    file:delete(binary_to_list(Path)),
                                    {error, Reason}
                            end;
                        {{error, Reason}, _} ->
                            file:delete(binary_to_list(Path)),
                            {error, Reason};
                        {_, {error, Reason}} ->
                            file:delete(binary_to_list(Path)),
                            {error, Reason}
                    end;
                {error, eexist} ->
                    secure_temp_file(Root, Content, Attempts - 1);
                {error, Reason} ->
                    {error, Reason}
            end
    end.

secure_temp_name() ->
    hb_util:human_id(crypto:strong_rand_bytes(32)).

ensure_private_directory(Path) ->
    PathList = binary_to_list(Path),
    case filelib:ensure_dir(filename:join(PathList, ".lapee-directory")) of
        ok ->
            case file:read_link_info(PathList) of
                {ok, #file_info{type = directory}} ->
                    case file:change_mode(PathList, 8#700) of
                        ok -> ok;
                        {error, Reason} -> {error, Reason}
                    end;
                {ok, _} ->
                    {error, unsafe_private_directory};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

container_list_dir(MemberId, ContainerPath, Opts) ->
    Command =
        iolist_to_binary(
            [
                <<"find ">>, shell_quote(ContainerPath),
                <<" -mindepth 1 -maxdepth 1 -printf '%f\\t%y\\t%s\\t%T@\\n' 2>&1">>
            ]
        ),
    container_command(
        MemberId,
        preserve,
        Opts,
        fun(Name) ->
            container_exec_args(Name, [], [<<"bash">>, <<"-lc">>, Command])
        end,
        10000,
        fun(_Code, Output) ->
            case classify_fs_error(Output) of
                enoent -> {error, enoent};
                Reason -> {error, Reason}
            end
        end,
        <<"Docker directory listing timed out.">>,
        fun(Output) ->
            {ok,
                lists:filtermap(
                    fun parse_find_line/1,
                    binary:split(Output, <<"\n">>, [global])
                )}
        end
    ).

container_command(
    MemberId,
    NetworkPolicy,
    Opts,
    ArgsFun,
    TimeoutMs,
    ExitFun,
    TimeoutMessage,
    OkFun
) ->
    case with_container(
        MemberId,
        NetworkPolicy,
        Opts,
        fun(Spec) ->
            case docker_command(
                ArgsFun(maps:get(name, Spec)),
                TimeoutMs,
                ExitFun,
                TimeoutMessage
            ) of
                {ok, Output} -> OkFun(Output);
                Error -> Error
            end
        end
    ) of
        {error, Status, Message} ->
            {error, Status, Message, #{}};
        Other ->
            Other
    end.

container_exec_args(Name, ExecArgs, CommandArgs) ->
    [<<"exec">>] ++ ExecArgs ++ [<<"--">>, Name | CommandArgs].

parse_find_line(<<>>) -> false;
parse_find_line(Line) ->
    case binary:split(Line, <<"\t">>, [global]) of
        [Name, Type, Size, Mtime] ->
            {true,
                #{
                    <<"name">> => Name,
                    <<"type">> => find_type(Type),
                    <<"size">> =>
                        lib_permawebos_execution_runtime:safe_int(
                            trim(Size),
                            0
                        ),
                    <<"modified-at">> => epoch_seconds_to_iso(Mtime)
                }};
        _ ->
            false
    end.

find_type(<<"f">>) -> <<"file">>;
find_type(<<"d">>) -> <<"directory">>;
find_type(<<"l">>) -> <<"symlink">>;
find_type(_) -> <<"other">>.

epoch_seconds_to_iso(Bin) ->
    try
        [Whole | _] = binary:split(trim(Bin), <<".">>),
        hb_util:bin(
            calendar:system_time_to_rfc3339(
                binary_to_integer(Whole),
                [{unit, second}, {offset, "Z"}]
            )
        )
    catch _:_ ->
        <<>>
    end.

docker_ok(Args, TimeoutMs, ErrorMessage, TimeoutMessage) ->
    case docker_command(
        Args,
        TimeoutMs,
        fun(_Code, Output) ->
            {error, append_output(ErrorMessage, Output)}
        end,
        TimeoutMessage
    ) of
        {ok, _Output} -> ok;
        Error -> Error
    end.

host_command_ok(Executable, Args, TimeoutMs, ErrorMessage, TimeoutMessage) ->
    case run_command(Executable, Args, TimeoutMs) of
        {ok, _Output, 0} -> ok;
        {exit, _Code, Output} ->
            {error, append_output(ErrorMessage, Output)};
        {timeout, _Output} ->
            {error, TimeoutMessage};
        {error, _Status, Message} ->
            {error, Message}
    end.

docker_command(Args, TimeoutMs, ExitFun, TimeoutMessage) ->
    case run_command(<<"docker">>, Args, TimeoutMs) of
        {ok, Output, 0} -> {ok, Output};
        {exit, Code, Output} -> ExitFun(Code, Output);
        {timeout, _Output} -> {error, TimeoutMessage};
        {error, _Status, Message} -> {error, Message}
    end.

run_command(Executable, Args, TimeoutMs) ->
    case os:find_executable(binary_to_list(Executable)) of
        false ->
            {error,
                503,
                <<Executable/binary, " is not available on the host.">>};
        ExecPath ->
            Port =
                open_port(
                    {spawn_executable, ExecPath},
                    [
                        binary,
                        exit_status,
                        use_stdio,
                        stderr_to_stdout,
                        hide,
                        {args, [port_arg(Arg) || Arg <- Args]}
                    ]
                ),
            Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
            collect_port(Port, Deadline, <<>>, false)
    end.

port_arg(Value) ->
    Bin = hb_util:bin(Value),
    case unicode:characters_to_list(Bin, utf8) of
        Chars when is_list(Chars) -> Chars;
        _ -> binary_to_list(Bin)
    end.

collect_port(Port, Deadline, Acc, Truncated) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} ->
            {Next, NextTruncated} = append_bounded(
                Acc,
                Data,
                ?MAX_COMMAND_OUTPUT
            ),
            collect_port(
                Port,
                Deadline,
                Next,
                Truncated orelse NextTruncated
            );
        {Port, {exit_status, 0}} ->
            {ok, output_with_truncation_marker(Acc, Truncated), 0};
        {Port, {exit_status, Status}} ->
            {exit, Status, output_with_truncation_marker(Acc, Truncated)}
    after Remaining ->
        catch port_close(Port),
        {timeout, output_with_truncation_marker(Acc, Truncated)}
    end.

append_bounded(Acc, Data, Limit) when byte_size(Acc) >= Limit ->
    {Acc, Data =/= <<>>};
append_bounded(Acc, Data, Limit) ->
    Remaining = Limit - byte_size(Acc),
    case byte_size(Data) =< Remaining of
        true -> {<<Acc/binary, Data/binary>>, false};
        false ->
            {<<Acc/binary, (binary:part(Data, 0, Remaining))/binary>>, true}
    end.

output_with_truncation_marker(Output, false) ->
    Output;
output_with_truncation_marker(Output, true) ->
    <<Output/binary, "\n[permawebos docker output truncated]\n">>.

append_output(Message, Output0) ->
    case trim(Output0) of
        <<>> -> Message;
        Output -> <<Message/binary, " ", Output/binary>>
    end.

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

trim(Bin) when is_binary(Bin) ->
    hb_util:bin(string:trim(binary_to_list(Bin)));
trim(Value) ->
    trim(hb_util:bin(Value)).

-ifdef(TEST).

no_shared_or_tcp_docker_host_test() ->
    ?assertMatch(
        {error, _},
        private_docker_host_value(<<"unix:///var/run/docker.sock">>)
    ),
    ?assertMatch(
        {error, _},
        private_docker_host_value(<<"tcp://127.0.0.1:2375">>)
    ),
    ?assertEqual(
        {ok, ?DOCKER_HOST},
        private_docker_host_value(
            ?DOCKER_HOST
        )
    ),
    ?assertMatch(
        {error, _},
        private_docker_host_value(<<"unix:///run/user/1000/docker.sock">>)
    ).

docker_actions_fail_closed_network_by_default_test() ->
    ?assertEqual(
        false,
        maps:get(execution_default_allow_network, force_backend(#{}))
    ).

configuration_has_no_default_image_test() ->
    Previous = os:getenv("PERMAWEBOS_DOCKER_IMAGE"),
    os:unsetenv("PERMAWEBOS_DOCKER_IMAGE"),
    try
        ?assertEqual(
            {error, <<"permawebos-docker-image is not configured.">>},
            configuration(#{} )
        )
    after
        case Previous of
            false -> ok;
            Value -> os:putenv("PERMAWEBOS_DOCKER_IMAGE", Value)
        end
    end.

image_identity_rejects_image_declared_volumes_test() ->
    ?assertEqual(
        {ok, <<"sha256:image">>},
        parse_image_identity(<<"sha256:image\tnull">>)
    ),
    ?assertEqual(
        {ok, <<"sha256:image">>},
        parse_image_identity(<<"sha256:image\t{}">>)
    ),
    ?assertMatch(
        {error, _},
        parse_image_identity(<<"sha256:image\t{\"/data\":{}}">>)
    ),
    ?assertMatch({error, _}, parse_image_identity(<<"invalid">>)).

docker_volume_defaults_ephemeral_and_zone_fails_closed_test() ->
    Previous = os:getenv("PERMAWEBOS_DOCKER_VOLUME"),
    os:unsetenv("PERMAWEBOS_DOCKER_VOLUME"),
    try
        ?assertEqual({ok, <<"ephemeral">>}, volume(#{})),
        ?assertMatch(
            {error, <<"zone">>, _},
            volume(#{<<"permawebos-docker-volume">> => <<"zone">>})
        ),
        ?assertEqual(
            {error,
                <<"invalid">>,
                <<"permawebos-docker-volume must be ephemeral or zone.">>},
            volume(#{<<"permawebos-docker-volume">> => <<"durable">>})
        ),
        os:putenv("PERMAWEBOS_DOCKER_VOLUME", "zone"),
        ?assertMatch({error, <<"zone">>, _}, volume(#{})),
        ?assertEqual(
            {ok, <<"ephemeral">>},
            volume(#{<<"permawebos-docker-volume">> => <<"ephemeral">>})
        )
    after
        case Previous of
            false -> ok;
            Value -> os:putenv("PERMAWEBOS_DOCKER_VOLUME", Value)
        end
    end.

container_identity_and_config_are_bound_test() ->
    Base =
        #{
            volume => <<"ephemeral">>,
            network => <<"disabled">>,
            image => <<"fixture:1">>,
            image_id => <<"sha256:first">>,
            memory => <<"512m">>,
            swap_limit => true,
            cpus => <<"1.0">>,
            pids => 256,
            storage => <<"512m">>,
            tmpfs => <<"64m">>,
            member_hash => member_hash(<<"alpha">>),
            name => container_name(<<"alpha">>),
            workspace =>
                join_path(
                    ?MEMBER_ROOT,
                    member_hash(<<"alpha">>)
                )
        },
    First = config_fingerprint(Base),
    ?assertEqual(First, config_fingerprint(Base)),
    ?assertNotEqual(
        First,
        config_fingerprint(Base#{ image_id => <<"sha256:second">> })
    ),
    ?assertNotEqual(
        First,
        config_fingerprint(Base#{ swap_limit => false })
    ),
    ?assertNotEqual(
        First,
        config_fingerprint(Base#{ volume => <<"zone">> })
    ),
    ?assertNotEqual(
        First,
        config_fingerprint(Base#{ network => <<"enabled">> })
    ),
    ?assertNotEqual(container_name(<<"alpha">>), container_name(<<"beta">>)).

member_network_policy_is_immutable_test() ->
    Spec =
        #{
            volume => <<"ephemeral">>,
            image_id => <<"sha256:first">>,
            memory => <<"512m">>,
            swap_limit => true,
            cpus => <<"1.0">>,
            pids => 256,
            storage => <<"512m">>,
            tmpfs => <<"64m">>,
            workspace => <<"/run/lapee/docker-runtime/members/member">>
        },
    {ok, Disabled} = bind_stored_network_policy(Spec, true, preserve),
    ?assertEqual(<<"disabled">>, maps:get(network, Disabled)),
    ?assertEqual(
        {ok, Disabled},
        bind_stored_network_policy(Spec, true, true)
    ),
    ?assertMatch(
        {error, 409, _},
        bind_stored_network_policy(Spec, true, false)
    ),
    {ok, Enabled} = bind_stored_network_policy(Spec, false, preserve),
    ?assertEqual(<<"enabled">>, maps:get(network, Enabled)),
    ?assertMatch(
        {error, 409, _},
        bind_stored_network_policy(Spec, false, true)
    ),
    ?assertNotEqual(
        maps:get(fingerprint, Disabled),
        maps:get(fingerprint, Enabled)
    ).

hardened_create_args_test() ->
    Spec0 =
        #{
            volume => <<"ephemeral">>,
            network => <<"disabled">>,
            disable_network => true,
            image => <<"fixture:1">>,
            image_id => <<"sha256:fixture">>,
            memory => <<"512m">>,
            swap_limit => true,
            cpus => <<"1.0">>,
            pids => 256,
            storage => <<"512m">>,
            tmpfs => <<"64m">>,
            member_hash => member_hash(<<"member">>),
            name => container_name(<<"member">>),
            workspace => <<"/run/lapee/docker-runtime/members/member">>
        },
    Spec = Spec0#{ fingerprint => config_fingerprint(Spec0) },
    Args = create_args(Spec),
    ?assertEqual(<<"create">>, hd(Args)),
    ?assertNot(lists:member(<<"--detach">>, Args)),
    lists:foreach(
        fun(Required) -> ?assert(lists:member(Required, Args)) end,
        [
            <<"--pull=never">>,
            <<"--network=bridge">>,
            <<"--user=0:0">>,
            <<"--workdir=/root">>,
            <<"--entrypoint=sleep">>,
            <<"--no-healthcheck">>,
            <<"--read-only">>,
            <<"--cap-drop=ALL">>,
            <<"--security-opt=no-new-privileges:true">>,
            <<"--memory">>,
            <<"--memory-swap">>,
            <<"--cpus">>,
            <<"--pids-limit">>,
            <<"--tmpfs">>,
            <<"--mount">>
        ]
    ),
    ?assertNot(lists:any(fun(Arg) -> binary:match(Arg, <<"docker.sock">>) =/= nomatch end, Args)),
    ?assertNot(lists:member(<<"-v">>, Args)),
    ?assertNot(lists:member(<<"--volume">>, Args)),
    ?assertNot(lists:member(<<"--storage-opt">>, Args)),
    [<<"--mount">>, Mount | _] =
        lists:dropwhile(fun(Arg) -> Arg =/= <<"--mount">> end, Args),
    ?assertMatch(
        <<"type=bind,src=/run/lapee/docker-runtime/members/", _/binary>>,
        Mount
    ),
    ?assertEqual(nomatch, binary:match(Mount, <<",rw">>)).

container_metadata_must_be_exact_test() ->
    ?assertEqual(
        {ok,
            #{
                image_id => <<"sha256:image">>,
                device => ?DEVICE,
                member_hash => <<"member-hash">>,
                fingerprint => <<"config-hash">>,
                network => <<"disabled">>,
                workspace_mount =>
                    <<"bind=/run/lapee/docker-runtime/members/member:rw">>,
                unexpected_mounts => <<>>,
                read_only => <<"true">>,
                memory => <<"536870912">>,
                memory_swap => <<"536870912">>,
                nano_cpus => <<"1000000000">>,
                pids_limit => <<"256">>,
                cap_drop => <<"ALL;">>,
                cap_add => <<>>,
                security_opt => <<"no-new-privileges:true;">>,
                init => <<"true">>,
                restart => <<"no">>,
                tmpfs => <<"rw,nosuid,nodev,noexec,size=64m">>,
                network_mode => <<"bridge">>,
                privileged => <<"false">>,
                pid_mode => <<>>,
                ipc_mode => <<"private">>,
                devices => <<>>,
                device_requests => <<>>,
                user => <<"0:0">>,
                entrypoint => <<"[\"sleep\"]">>,
                command => <<"[\"infinity\"]">>,
                healthcheck => <<"{\"Test\":[\"NONE\"]}">>,
                working_dir => <<"/root">>
            }},
        parse_container_metadata(
            trim(
                <<"sha256:image\tdocker@1.0\tmember-hash\tconfig-hash\tdisabled\t",
                  "bind=/run/lapee/docker-runtime/members/member:rw\t\ttrue\t",
                  "536870912\t536870912\t1000000000\t256\tALL;\t\t",
                  "no-new-privileges:true;\ttrue\tno\t",
                  "rw,nosuid,nodev,noexec,size=64m\tbridge\tfalse\t\tprivate\t\t\t",
                  "0:0\t[\"sleep\"]\t[\"infinity\"]\t",
                  "{\"Test\":[\"NONE\"]}\t/root\t",
                  "complete\n">>
            )
        )
    ),
    ?assertMatch(
        {ok, #{ unexpected_mounts := <<"/var/lib/data;">> }},
        parse_container_metadata(
            <<"sha256:image\tdocker@1.0\tmember-hash\tconfig-hash\tdisabled\t",
              "bind=/run/lapee/docker-runtime/members/member:rw\t/var/lib/data;\ttrue\t",
              "536870912\t536870912\t1000000000\t256\tALL;\t\t",
              "no-new-privileges:true;\ttrue\tno\t",
              "rw,nosuid,nodev,noexec,size=64m\tbridge\tfalse\t\tprivate\t\t\t",
              "0:0\t[\"sleep\"]\t[\"infinity\"]\t",
              "{\"Test\":[\"NONE\"]}\t/root\t",
              "complete">>
        )
    ),
    ?assertMatch(
        {error, _},
        parse_container_metadata(
            trim(
                <<"sha256:image\tdocker@1.0\tmember-hash\tconfig-hash\tdisabled\t",
                  "bind=/run/lapee/docker-runtime/members/member:rw\t\ttrue\t",
                  "536870912\t536870912\t1000000000\t256\tALL;\t\t",
                  "no-new-privileges:true;\ttrue\tno\t",
                  "rw,nosuid,nodev,noexec,size=64m\tbridge\tfalse\t\tprivate\t\t\n">>
            )
        )
    ),
    ?assertMatch({error, _}, parse_container_metadata(<<"incomplete">>)).

live_resource_config_must_match_test() ->
    Spec =
        #{
            image_id => <<"sha256:image">>,
            member_hash => <<"member-hash">>,
            fingerprint => <<"config-hash">>,
            network => <<"disabled">>,
            workspace => <<"/run/lapee/docker-runtime/members/member">>,
            memory => <<"512m">>,
            swap_limit => true,
            cpus => <<"1.0">>,
            pids => 256,
            tmpfs => <<"64m">>
        },
    Expected = expected_container_metadata(Spec),
    ?assertEqual(<<"536870912">>, maps:get(memory, Expected)),
    ?assertEqual(<<"536870912">>, maps:get(memory_swap, Expected)),
    ?assertEqual(<<"1000000000">>, maps:get(nano_cpus, Expected)),
    ?assertEqual(
        <<"-1">>,
        maps:get(memory_swap, expected_container_metadata(Spec#{ swap_limit => false }))
    ),
    ?assertNotEqual(Expected, Expected#{ pids_limit => <<"512">> }),
    ?assertNotEqual(Expected, Expected#{ cap_add => <<"SYS_ADMIN;">> }),
    Actual =
        (maps:remove(memory_swap, Expected))#{
            cap_add => <<"secret-capability-value">>
        },
    Mismatches = metadata_mismatch_keys(Expected, Actual),
    ?assertEqual(<<"cap-add, memory-swap">>, Mismatches),
    ?assertEqual(nomatch, binary:match(Mismatches, <<"secret">>)).

daemon_capabilities_are_exact_test() ->
    ?assertEqual(
        {ok, #{ swap_limit => true }},
        parse_daemon_capabilities(<<"true\ttrue">>)
    ),
    ?assertEqual(
        {ok, #{ swap_limit => false }},
        parse_daemon_capabilities(<<"true\tfalse">>)
    ),
    ?assertEqual(
        {error, <<"private Docker daemon does not enforce memory limits.">>},
        parse_daemon_capabilities(<<"false\tfalse">>)
    ),
    ?assertMatch(
        {error, _},
        parse_daemon_capabilities(<<"true\tunknown">>)
    ).

secure_temp_name_is_base64url_test() ->
    Name = secure_temp_name(),
    ?assertEqual(43, byte_size(Name)),
    ?assertEqual(match, re:run(Name, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}])).

bounded_output_test() ->
    ?assertEqual({<<"abcd">>, false}, append_bounded(<<"ab">>, <<"cd">>, 4)),
    ?assertEqual({<<"abcd">>, true}, append_bounded(<<"ab">>, <<"cdef">>, 4)),
    ?assertEqual({<<"abcd">>, true}, append_bounded(<<"abcd">>, <<"x">>, 4)).

bounded_workspace_mount_test() ->
    Line =
        <<"36 29 0:32 / /run/lapee/docker-runtime/members/member rw,nosuid,nodev - tmpfs permawebos-member rw,size=524288k,inode64">>,
    ?assertEqual(
        {ok, 512 * 1024 * 1024},
        workspace_mount_lines(
            <<"/run/lapee/docker-runtime/members/member">>,
            [Line]
        )
    ),
    ?assertEqual({ok, 512 * 1024 * 1024}, parse_size_bytes(<<"512m">>)),
    ?assertEqual({ok, 64 * 1024 * 1024}, parse_size_bytes(<<"64MB">>)).

inspect_status_errors_fail_closed_test() ->
    ?assertEqual(absent, inspect_status_error(<<"Error: No such object: missing">>)),
    ?assertMatch(
        {error, _},
        inspect_status_error(<<"Cannot connect to the Docker daemon">>)
    ).

-endif.
