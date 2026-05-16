-module(dev_snp_nif).
-export([supported/0, report/2]).

-include("include/cargo.hrl").

-on_load(init/0).
-define(NOT_LOADED, not_loaded(?LINE)).

supported() ->
    ?NOT_LOADED.

report(_ReportData, _VMPL) ->
    ?NOT_LOADED.

init() ->
    ?load_nif_from_crate(dev_snp_nif, 0).

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
