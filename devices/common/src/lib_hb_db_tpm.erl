%%% @doc Minimal TPM trust-root loader.
%%%
%%% The v1 product path only needs the measured-in TPM EK root CA bundle.
%%% Historical interpretation catalogues are not loaded in production.
-module(lib_hb_db_tpm).
-export([load/1, load/2, priv_dir/0, priv_dir/1, read_cert_roots/1]).

-define(APPNAME, hb).
-define(DB_SUBDIR, "tpm-interpret").
-define(CACHE_KEY, {lib_hb_db_tpm, loaded}).

load(Opts) ->
    load(undefined, Opts).

load(DeviceModule, Opts) ->
    CacheKey = {?CACHE_KEY, DeviceModule},
    case persistent_term:get(CacheKey, undefined) of
        undefined ->
            Db = #{<<"cert-roots">> => cert_roots(DeviceModule, Opts)},
            persistent_term:put(CacheKey, Db),
            Db;
        Db ->
            Db
    end.

priv_dir() ->
    priv_dir(undefined).

priv_dir(DeviceModule) when is_atom(DeviceModule) ->
    case packaged_priv_dir(DeviceModule) of
        undefined -> app_priv_dir();
        Dir -> Dir
    end;
priv_dir(_) ->
    app_priv_dir().

cert_roots(DeviceModule, Opts) ->
    Roots =
        lists:append(
            [
                read_cert_roots(filename:join([Dir, ?DB_SUBDIR, "root-cas"]))
             || Dir <- priv_dirs(DeviceModule, Opts)
            ]),
    unique_roots(Roots).

priv_dirs(DeviceModule, Opts) ->
    unique_dirs(
        lists:filtermap(
            fun
                (undefined) -> false;
                (Dir) -> existing_dir(Dir)
            end,
            [
                packaged_priv_dir(DeviceModule),
                app_priv_dir(),
                configured_runtime_priv_dir(DeviceModule, Opts),
                env_runtime_priv_dir(DeviceModule),
                source_priv_dir(DeviceModule)
            ])).

packaged_priv_dir(DeviceModule) ->
    try hb_device_archive:implementation_dir(DeviceModule)
    catch _:_ -> undefined
    end.

app_priv_dir() ->
    case code:priv_dir(?APPNAME) of
        {error, _} ->
            filename:join(
                [filename:dirname(filename:dirname(code:which(?MODULE))),
                 "priv"]);
        Dir ->
            Dir
    end.

configured_runtime_priv_dir(DeviceModule, Opts) ->
    case hb_opts:get(<<"handee-runtime-root">>, undefined, Opts) of
        undefined -> undefined;
        Root -> runtime_priv_dir(Root, DeviceModule)
    end.

env_runtime_priv_dir(DeviceModule) ->
    case os:getenv("HANDEE_RUNTIME_ROOT") of
        false -> undefined;
        Root -> runtime_priv_dir(Root, DeviceModule)
    end.

runtime_priv_dir(Root, DeviceModule) ->
    filename:join([path_to_list(Root), "priv", atom_to_list(DeviceModule)]).

source_priv_dir(DeviceModule) ->
    filename:join(
        [
            filename:dirname(filename:dirname(code:which(?MODULE))),
            "src",
            "priv",
            atom_to_list(DeviceModule)
        ]).

existing_dir(Dir) ->
    case filelib:is_dir(Dir) of
        true -> {true, Dir};
        false -> false
    end.

unique_dirs(Dirs) ->
    unique_by(fun filename:absname/1, Dirs).

unique_roots(Roots) ->
    unique_by(fun(Root) -> hb_maps:get(<<"pem">>, Root, <<>>, #{}) end, Roots).

unique_by(F, Values) ->
    {Out, _Seen} =
        lists:foldl(
            fun(Value, {Acc, Seen}) ->
                Key = F(Value),
                case maps:is_key(Key, Seen) of
                    true -> {Acc, Seen};
                    false -> {[Value | Acc], Seen#{Key => true}}
                end
            end,
            {[], #{}},
            Values),
    lists:reverse(Out).

read_cert_roots(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            [#{<<"name">> => list_to_binary(filename:rootname(F)),
               <<"pem">> => Pem}
             || F <- Files,
                filename:extension(F) =:= ".pem",
                {ok, Pem} <- [file:read_file(filename:join(Dir, F))]];
        _ ->
            []
    end.

path_to_list(Path) when is_binary(Path) -> binary_to_list(Path);
path_to_list(Path) when is_list(Path) -> Path;
path_to_list(Path) -> binary_to_list(hb_util:bin(Path)).
