-module(lapee_snp_nif).
-export([supported/0, report/2]).

-on_load(init/0).
-define(NOT_LOADED, not_loaded(?LINE)).
-define(LIBNAME, "lapee_snp_nif").

supported() ->
    ?NOT_LOADED.

report(_ReportData, _VMPL) ->
    ?NOT_LOADED.

init() ->
    Path = filename:join([priv_dir(), "crates", ?LIBNAME, ?LIBNAME]),
    case erlang:load_nif(Path, 0) of
        ok ->
            ok;
        {error, Reason} ->
            io:format(
                standard_error,
                "[lapee_snp_nif] load_nif(~s) failed: ~p~n",
                [Path, Reason]
            ),
            {error, Reason}
    end.

priv_dir() ->
    case os:getenv("LAPEE_SNP_NIF_DIR") of
        false -> priv_dir_from_code();
        Dir -> Dir
    end.

priv_dir_from_code() ->
    case code:which(?MODULE) of
        Path when is_list(Path) -> filename:dirname(Path);
        _ -> fallback_priv_dir()
    end.

fallback_priv_dir() ->
    case filelib:is_dir(filename:join("..", "priv")) of
        true -> filename:join("..", "priv");
        false -> "priv"
    end.

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
