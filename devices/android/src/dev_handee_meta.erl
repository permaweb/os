%%% @doc HandEE public meta facade.
%%%
%%% Upstream `~meta@1.0/info' returns the full node message. That is useful on
%%% a general HyperBEAM node, but HandEE's attested public subject should be the
%%% small Android-bound node/config identity, not the entire runtime option map.
-module(dev_handee_meta).

-export([info/1, info/3, build/3, handle/2, is/2, is/3]).
-export([is_operator/2, is_operator/3]).

-include("include/hb.hrl").

info(Base) ->
    dev_meta:info(Base).

info(_Base, _Req, NodeMsg) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => public_node_info(NodeMsg)
    }}.

build(Base, Req, NodeMsg) ->
    dev_meta:build(Base, Req, NodeMsg).

handle(NodeMsg, RawRequest) ->
    dev_meta:handle(NodeMsg, RawRequest).

is(Path, NodeMsg) ->
    dev_meta:is(Path, NodeMsg).

is(Base, Req, NodeMsg) ->
    dev_meta:is(Base, Req, NodeMsg).

is_operator(Request, NodeMsg) ->
    dev_meta:is_operator(Request, NodeMsg).

is_operator(Base, Req, NodeMsg) ->
    dev_meta:is_operator(Base, Req, NodeMsg).

public_node_info(NodeMsg) ->
    NodeSubject = hb_opts:get(<<"handee-node-subject">>, #{}, NodeMsg),
    #{
        <<"type">> => <<"handee-node-info">>,
        <<"version">> => <<"1.0">>,
        <<"address">> => hb_opts:get(<<"address">>, <<>>, NodeMsg),
        <<"http-server">> => hb_opts:get(<<"http-server">>, <<>>, NodeMsg),
        <<"handee-node-message-id">> =>
            hb_opts:get(<<"handee-node-message-id">>, <<>>, NodeMsg),
        <<"node-subject">> => NodeSubject,
        <<"measurement-device">> =>
            hb_opts:get(<<"measurement-device">>, <<"handee@1.0">>, NodeMsg),
        <<"load-remote-devices">> =>
            hb_opts:get(<<"load-remote-devices">>, false, NodeMsg),
        <<"store">> => public_store(hb_opts:get(<<"store">>, [], NodeMsg)),
        <<"port">> => hb_opts:get(<<"port">>, 8734, NodeMsg),
        <<"runtime">> => #{
            <<"environment">> => <<"android-app-uid">>,
            <<"node-key-scope">> => <<"ephemeral-memory">>,
            <<"store-default">> => <<"volatile">>
        }
    }.

public_store(Stores) when is_list(Stores) ->
    [public_store(Store) || Store <- Stores];
public_store(Store) when is_map(Store) ->
    maps:from_list(
        [
            {<<"name">>, hb_maps:get(<<"name">>, Store, <<>>, #{})},
            {<<"store-module">>, public_store_module(
                hb_maps:get(<<"store-module">>, Store, undefined, #{}))}
        ]
    );
public_store(_) ->
    [].

public_store_module(hb_store_volatile) ->
    <<"hb_store_volatile">>;
public_store_module(Mod) when is_atom(Mod) ->
    atom_to_binary(Mod, utf8);
public_store_module(Mod) when is_binary(Mod) ->
    Mod;
public_store_module(_) ->
    <<"unknown">>.
