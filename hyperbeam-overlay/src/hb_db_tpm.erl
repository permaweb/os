%%% @doc Minimal TPM trust-root loader.
%%%
%%% The v1 product path only needs the measured-in TPM EK root CA bundle.
%%% Historical interpretation catalogues are not loaded in production.
-module(hb_db_tpm).
-export([load/1, priv_dir/0, read_cert_roots/1]).

-define(APPNAME, hb).
-define(DB_SUBDIR, "tpm-interpret").
-define(CACHE_KEY, {hb_db_tpm, loaded}).

load(_Opts) ->
    case persistent_term:get(?CACHE_KEY, undefined) of
        undefined ->
            Root = filename:join(priv_dir(), ?DB_SUBDIR),
            Db = #{<<"cert-roots">> =>
                       read_cert_roots(filename:join(Root, "root-cas"))},
            persistent_term:put(?CACHE_KEY, Db),
            Db;
        Db ->
            Db
    end.

priv_dir() ->
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
