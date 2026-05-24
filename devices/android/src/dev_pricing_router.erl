%%% @doc Route requests to different P4 pricing devices.
%%%
%%% This is a small pricing-device adapter. It allows a node to keep static
%%% route prices on `simple-pay@1.0' while sending specific routes to another
%%% narrow pricing device.
-module(dev_pricing_router).
-export([info/1, estimate/3, price/3]).

-include_lib("hb/include/hb.hrl").

info(_) ->
    #{ exports => [<<"estimate">>, <<"price">>] }.

estimate(Base, Req, Opts) ->
    forward(<<"estimate">>, Base, Req, Opts).

price(Base, Req, Opts) ->
    forward(<<"price">>, Base, Req, Opts).

forward(Path, Base, Req, Opts) ->
    PricingMsg = pricing_msg(Base, Req#{ <<"path">> => Path }, Opts),
    hb_ao:resolve(PricingMsg, Req#{ <<"path">> => Path }, Opts).

pricing_msg(Base, Req, Opts) ->
    Route = selected_route(Base, Req, Opts),
    Device =
        hb_maps:get(
            <<"pricing-device">>,
            Route,
            hb_maps:get(<<"default-pricing-device">>, Base, <<"simple-pay@1.0">>, Opts),
            Opts
        ),
    (maps:merge(Base, maps:remove(<<"template">>, Route)))#{
        <<"device">> => Device
    }.

selected_route(Base, Req, Opts) ->
    Request = hb_ao:get(<<"request">>, Req, #{}, Opts#{ <<"hashpath">> => ignore }),
    Routes =
        hb_maps:get(
            <<"pricing-routes">>,
            Base,
            hb_opts:get(<<"pricing-routes">>, [], Opts),
            Opts
        ),
    case route_match(Request, Routes, Opts) of
        no_match -> #{};
        Route -> Route
    end.

route_match(Request, Routes, Opts) ->
    TargetPath =
        case hb_util:find_target_path(Request, Opts) of
            no_path -> no_path;
            {_TargetKey, Path} -> Path
        end,
    match_routes(Request#{<<"path">> => TargetPath}, list_routes(Routes, Opts), Opts).

list_routes(Routes, Opts) when is_map(Routes) ->
    case hb_util:is_ordered_list(Routes, Opts) of
        true -> hb_util:message_to_ordered_list(Routes, Opts);
        false -> hb_maps:values(Routes, Opts)
    end;
list_routes(Routes, _Opts) when is_list(Routes) ->
    Routes;
list_routes(_Routes, _Opts) ->
    [].

match_routes(_Request, [], _Opts) ->
    no_match;
match_routes(Request, [Route | Rest], Opts) ->
    Template = hb_maps:get(<<"template">>, Route, #{}, Opts),
    case hb_util:template_matches(Request, Template, Opts) of
        true -> Route;
        false -> match_routes(Request, Rest, Opts)
    end.
