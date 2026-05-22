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

load(DeviceModule, _Opts) ->
    case persistent_term:get(?CACHE_KEY, undefined) of
        undefined ->
            Root = filename:join(priv_dir(DeviceModule), ?DB_SUBDIR),
            Db = #{<<"cert-roots">> =>
                       read_cert_roots(filename:join(Root, "root-cas"))},
            persistent_term:put(?CACHE_KEY, Db),
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
