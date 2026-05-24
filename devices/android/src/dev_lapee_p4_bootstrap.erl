%%% @doc LapEE boot-time P4 wiring for the AO-paid bundler profile.
%%%
%%% The node wallet is generated at boot, so the P4 recipient, AO payment
%%% deposit address, and ledger admin cannot be safely hardcoded in JSON. This
%%% start hook derives those values from the live node message, installs the
%%% process-ledger definition, and then enables the P4 request/response hooks.
-module(dev_lapee_p4_bootstrap).
-implements(<<"lapee-p4-bootstrap@1.0">>).
-export([info/1, start/3, request/3, response/3]).

-include_lib("hb/include/hb.hrl").

-define(AO_TOKEN, <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>).
-define(LEDGER_NAME, <<"ledger">>).
-define(LEDGER_PATH, <<"/ledger~node-process@1.0">>).

info(_) ->
    #{exports => [<<"start">>, <<"request">>, <<"response">>]}.

start(Base, #{<<"body">> := NodeMsg0}, _Opts) ->
    case configure(NodeMsg0, bootstrap_device_ref(Base)) of
        {ok, NodeMsg} -> {ok, #{<<"body">> => NodeMsg}};
        Error -> Error
    end.

%% @doc Single on-request handler for the LapEE paid bundler profile.
%%
%% P4 currently expects exactly one request hook when exposing balance through
%% `~p4@1.0/balance'. LapEE also needs HyperBEAM's legacy manifest request hook
%% for plain `/TXID[/path]' reads. This handler keeps P4 as the single visible
%% request hook while applying manifest casting only to read requests for
%% content-address paths.
request(State, Raw, Opts) ->
    case maybe_manifest_request(State, Raw, Opts) of
        {ok, HookReq0} ->
            HookReq = alias_hook_req(HookReq0, State, Opts),
            case non_chargable_request(HookReq, Opts) of
                true -> {ok, #{<<"body">> => raw_hook_body(HookReq, Opts)}};
                false -> resolve_device(p4_state(State), <<"request">>, HookReq, Opts)
            end;
        Error ->
            Error
    end.

response(State, Raw, Opts) ->
    case non_chargable_request(Raw, Opts) of
        true -> {ok, #{<<"body">> => raw_hook_body(Raw, Opts)}};
        false -> resolve_device(p4_state(State), <<"response">>, Raw, Opts)
    end.

resolve_device(Base, Path, Req, Opts) ->
    hb_ao:resolve(Base, Req#{<<"path">> => Path}, Opts).

configure(NodeMsg0, BootstrapDevice) ->
    Address = node_address(NodeMsg0),
    Beneficiary = beneficiary_address(NodeMsg0, Address),
    DeviceRefs = profile_device_refs(NodeMsg0, BootstrapDevice),
    WithdrawSecret = hb_util:encode(crypto:strong_rand_bytes(32)),
    case ledger_process(Address) of
        {ok, LedgerProc} ->
            NodeMsg1 =
                install_base_config(
                    NodeMsg0,
                    Address,
                    Beneficiary,
                    LedgerProc,
                    WithdrawSecret
                ),
            case ensure_ledger(NodeMsg1) of
                {ok, LedgerID} ->
                    {ok,
                        install_hooks(
                            NodeMsg1,
                            Address,
                            Beneficiary,
                            LedgerID,
                            BootstrapDevice,
                            DeviceRefs
                        )};
                {error, Reason} ->
                    {error, #{
                        <<"status">> => 500,
                        <<"body">> => <<"Failed to spawn LapEE payment ledger.">>,
                        <<"reason">> => hb_util:bin(io_lib:format("~0p", [Reason]))
                    }}
            end;
        {error, Reason} ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Failed to prepare LapEE P4 ledger.">>,
                <<"reason">> => hb_util:bin(io_lib:format("~0p", [Reason]))
            }}
    end.

node_address(NodeMsg) ->
    case hb_maps:get(<<"address">>, NodeMsg, undefined, NodeMsg) of
        undefined ->
            Wallet = hb_opts:get(priv_wallet, hb:wallet(), NodeMsg),
            hb_util:human_id(ar_wallet:to_address(Wallet));
        Address ->
            hb_util:human_id(Address)
    end.

beneficiary_address(NodeMsg, Default) ->
    case hb_maps:get(<<"bundler-beneficiary">>, NodeMsg, undefined, NodeMsg) of
        undefined ->
            case hb_maps:get(<<"bundler_beneficiary">>, NodeMsg, Default, NodeMsg) of
                <<>> -> Default;
                Beneficiary -> hb_util:human_id(Beneficiary)
            end;
        <<>> ->
            Default;
        Beneficiary ->
            hb_util:human_id(Beneficiary)
    end.

ledger_process(Address) ->
    try
        {ok, TokenScript} = read_script("hyper-token.lua"),
        {ok, P4Script} = read_script("hyper-token-p4.lua"),
        LedgerProc = #{
            <<"device">> => <<"process@1.0">>,
            <<"type">> => <<"Process">>,
            <<"execution-device">> => <<"lua@5.3a">>,
            <<"scheduler-device">> => <<"scheduler@1.0">>,
            <<"scheduler">> => [Address],
            <<"authority">> => [Address],
            <<"admin">> => Address,
            <<"token">> => ?AO_TOKEN,
            <<"balance">> => #{},
            <<"module">> => [
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token.lua">>,
                    <<"body">> => TokenScript
                },
                #{
                    <<"content-type">> => <<"text/x-lua">>,
                    <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                    <<"body">> => P4Script
                }
            ]
        },
        {ok, LedgerProc}
    catch
        Class:CatchReason:Stack ->
            {error, {Class, CatchReason, Stack}}
    end.

ensure_ledger(NodeMsg) ->
    try
        NodeProcesses = map_opt(<<"node-processes">>, NodeMsg),
        case maps:find(?LEDGER_NAME, NodeProcesses) of
            {ok, LedgerProc} ->
                Signed = hb_message:commit(
                    LedgerProc,
                    NodeMsg,
                    hb_opts:get(
                        node_process_spawn_codec,
                        <<"httpsig@1.0">>,
                        NodeMsg
                    )
                ),
                LedgerID = hb_message:id(Signed, signed, NodeMsg),
                {ok, _} = hb_cache:write(Signed, NodeMsg),
                case register_ledger_name(LedgerID, NodeMsg) of
                    {ok, _} -> {ok, hb_util:human_id(LedgerID)};
                    {error, Reason} -> {error, Reason}
                end;
            error ->
                {error, {missing_node_process, ?LEDGER_NAME}}
        end
    catch
        Class:CatchReason:Stack ->
            {error, {Class, CatchReason, Stack}}
    end.

register_ledger_name(LedgerID, NodeMsg) ->
    RegisterOpts =
        case hb_opts:get(priv_wallet, no_viable_wallet, NodeMsg) of
            no_viable_wallet -> NodeMsg;
            Wallet ->
                NodeMsg#{ <<"operator">> => ar_wallet:to_address(Wallet) }
        end,
    hb_ao:resolve(
        #{ <<"device">> => <<"local-name@1.0">> },
        hb_message:commit(
            #{
                <<"path">> => <<"register">>,
                <<"key">> => ?LEDGER_NAME,
                <<"value">> => hb_util:human_id(LedgerID)
            },
            RegisterOpts
        ),
        RegisterOpts
    ).

read_script(Name) ->
    Candidates = script_paths(Name),
    read_first(Candidates, []).

script_paths(Name) ->
    NameBin = hb_util:bin(Name),
    NameList = binary_to_list(NameBin),
    ArchivePriv =
        filename:join([
            hb_device_archive:implementation_dir(?MODULE),
            "priv",
            "lapee-p4",
            NameList
        ]),
    HBScript =
        case code:lib_dir(hb) of
            {error, _} -> [];
            HBDir -> [filename:join([HBDir, "scripts", NameList])]
        end,
    [
        ArchivePriv,
        filename:join(["priv", "lapee-p4", NameList]),
        filename:join(["scripts", NameList])
    ] ++ HBScript.

read_first([], Errors) ->
    {error, {missing_script, lists:reverse(Errors)}};
read_first([Path | Rest], Errors) ->
    case file:read_file(Path) of
        {ok, Body} -> {ok, Body};
        {error, Reason} -> read_first(Rest, [{Path, Reason} | Errors])
    end.

install_base_config(NodeMsg0, Address, Beneficiary, LedgerProc, WithdrawSecret) ->
    NodeProcesses0 = map_opt(<<"node-processes">>, NodeMsg0),
    NodeMsg1 = NodeMsg0#{
        <<"operator">> => Address,
        <<"p4-recipient">> => Address,
        <<"bundler-beneficiary">> => Beneficiary,
        <<"ao-payment-token">> => ?AO_TOKEN,
        <<"ao-payment-deposit-address">> => Address,
        <<"ao-payment-withdraw-recipient">> => Beneficiary,
        <<"ao-payment-mainnet-url">> => <<"https://state.forward.computer">>,
        <<"ao-payment-submit-url">> => <<"https://mu.ao-testnet.xyz">>,
        <<"ao-payment-node">> =>
            <<"http://localhost:", (hb_util:bin(hb_maps:get(<<"port">>, NodeMsg0, 8734, NodeMsg0)))/binary>>,
        <<"scheduling-mode">> => aggressive,
        <<"node-processes">> => NodeProcesses0#{?LEDGER_NAME => LedgerProc}
    },
    hb_private:set(NodeMsg1, <<"ao-payment-withdraw-secret">>, WithdrawSecret, NodeMsg0).

install_hooks(NodeMsg0, Address, Beneficiary, LedgerID, BootstrapDevice, DeviceRefs) ->
    Processor = p4_processor(DeviceRefs),
    Settlement = bundler_settlement(Address, Beneficiary, DeviceRefs),
    On0 = map_opt(<<"on">>, NodeMsg0),
    BundledMessageComplete =
        append_hook_handlers(
            maps:get(<<"bundled-message-complete">>, On0, []),
            [Settlement, bundler_gc_hook(DeviceRefs)]
        ),
    Request =
        request_processor(
            maps:get(<<"request">>, On0, []),
            Processor,
            BootstrapDevice,
            DeviceRefs
        ),
    Response =
        append_hook_handlers(
            maps:get(<<"response">>, On0, []),
            [Processor]
        ),
    On1 = On0#{
        <<"request">> => Request,
        <<"response">> => Response,
        <<"bundled-message-complete">> => BundledMessageComplete
    },
    LocalNames0 = map_opt(<<"local-names">>, NodeMsg0),
    NodeMsg0#{
        <<"ao-payment-ledger">> => LedgerID,
        <<"local-names">> => LocalNames0#{?LEDGER_NAME => LedgerID},
        <<"p4-non-chargable-routes">> => p4_non_chargable_routes(LedgerID),
        <<"on">> => On1
    }.

append_hook_handlers([], NewHandlers) ->
    NewHandlers;
append_hook_handlers(Existing, NewHandlers) when is_list(Existing) ->
    Existing ++ NewHandlers;
append_hook_handlers(Existing, NewHandlers) ->
    [Existing | NewHandlers].

request_processor(ExistingRequest, Processor, BootstrapDevice, DeviceRefs) ->
    Base = Processor#{
        <<"device">> => BootstrapDevice,
        <<"p4-device">> => <<"p4@1.0">>,
        <<"lapee-device-aliases">> => DeviceRefs
    },
    case find_manifest_request(ExistingRequest) of
        not_found -> Base;
        ManifestRequest -> Base#{<<"manifest-request">> => ManifestRequest}
    end.

find_manifest_request(ExistingRequest) ->
    find_manifest_request_1(hook_handlers(ExistingRequest)).

find_manifest_request_1([]) ->
    not_found;
find_manifest_request_1([Handler = #{<<"device">> := <<"manifest@1.0">>} | _]) ->
    Handler;
find_manifest_request_1([_ | Rest]) ->
    find_manifest_request_1(Rest).

hook_handlers([]) ->
    [];
hook_handlers(Handler) when is_map(Handler) ->
    [Handler];
hook_handlers(Handlers) when is_list(Handlers) ->
    Handlers;
hook_handlers(_) ->
    [].

maybe_manifest_request(State, Raw, Opts) ->
    case {manifest_request(State), should_manifest_request(Raw, Opts)} of
        {false, _} ->
            {ok, Raw};
        {_, false} ->
            {ok, Raw};
        {ManifestRequest, true} ->
            case resolve_device(ManifestRequest, <<"request">>, Raw, Opts) of
                {error, #{<<"status">> := 404}} ->
                    {ok, Raw};
                Other ->
                    Other
            end
    end.

alias_hook_req(HookReq, State, Opts) ->
    Aliases = maps:get(<<"lapee-device-aliases">>, State, #{}),
    Body = hb_maps:get(<<"body">>, HookReq, [], Opts),
    HookReq#{<<"body">> => alias_body(Body, Aliases)}.

alias_body(Body, Aliases) when is_list(Body) ->
    [alias_message(Msg, Aliases) || Msg <- Body];
alias_body(Body, Aliases) ->
    alias_message(Body, Aliases).

alias_message({as, Device, Msg}, Aliases) ->
    {as, maps:get(Device, Aliases, Device), Msg};
alias_message(Msg, _Aliases) ->
    Msg.

manifest_request(State) ->
    case maps:get(<<"manifest-request">>, State, false) of
        Handler when is_map(Handler) -> Handler;
        _ -> false
    end.

should_manifest_request(Raw, Opts) ->
    Request = hb_maps:get(<<"request">>, Raw, #{}, Opts),
    Method = hb_maps:get(<<"method">>, Request, <<"GET">>, Opts),
    Path = hb_maps:get(<<"path">>, Request, <<>>, Opts),
    is_read_method(Method) andalso manifest_candidate_path(Path).

is_read_method(Method) ->
    case string:uppercase(binary_to_list(hb_util:bin(Method))) of
        "GET" -> true;
        "HEAD" -> true;
        _ -> false
    end.

manifest_candidate_path(Path0) ->
    Path = path_only(hb_util:bin(Path0)),
    case binary:split(trim_leading_slash(Path), <<"/">>) of
        [<<>>] -> false;
        [First | _] when ?IS_ID(First) -> true;
        _ -> false
    end.

path_only(Path) ->
    case binary:split(Path, <<"?">>) of
        [Only] -> Only;
        [Only, _Query] -> Only
    end.

trim_leading_slash(<<"/", Rest/binary>>) ->
    Rest;
trim_leading_slash(Path) ->
    Path.

p4_state(State) ->
    P4Device = maps:get(<<"p4-device">>, State, <<"p4@1.0">>),
    maps:without(
        [<<"manifest-request">>, <<"p4-device">>, <<"lapee-device-aliases">>],
        State#{<<"device">> => P4Device}
    ).

bootstrap_device_ref(Base) when is_map(Base) ->
    maps:get(<<"device">>, Base, <<"lapee-p4-bootstrap@1.0">>);
bootstrap_device_ref(_) ->
    <<"lapee-p4-bootstrap@1.0">>.

non_chargable_request(HookReq, Opts) ->
    Request = hb_maps:get(<<"request">>, HookReq, #{}, Opts),
    Routes = hb_opts:get(p4_non_chargable_routes, [], Opts),
    route_match(Request, Routes, Opts) =/= no_match.

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

raw_hook_body(HookReq, Opts) ->
    hb_maps:get(<<"body">>, HookReq, [], Opts).

profile_device_refs(NodeMsg, BootstrapDevice) ->
    #{
        <<"ao-payment@1.0">> => device_ref(<<"ao-payment@1.0">>, NodeMsg),
        <<"arweave-byte-pricing@1.0">> =>
            device_ref(<<"arweave-byte-pricing@1.0">>, NodeMsg),
        <<"bundler-settlement@1.0">> =>
            device_ref(<<"bundler-settlement@1.0">>, NodeMsg),
        <<"lapee-bundler-gc@1.0">> =>
            device_ref(<<"lapee-bundler-gc@1.0">>, NodeMsg),
        <<"lapee-p4-bootstrap@1.0">> => BootstrapDevice,
        <<"pricing-router@1.0">> =>
            device_ref(<<"pricing-router@1.0">>, NodeMsg),
        <<"process-ledger@1.0">> =>
            device_ref(<<"process-ledger@1.0">>, NodeMsg),
        <<"simple-oracle@1.0">> =>
            device_ref(<<"simple-oracle@1.0">>, NodeMsg)
    }.

device_ref(Name, NodeMsg) ->
    Resolvers = list_opt(<<"name-resolvers">>, NodeMsg),
    device_ref_1(Name, Resolvers, NodeMsg).

device_ref_1(Name, [Resolver | Rest], Opts) when is_map(Resolver) ->
    case hb_maps:get(Name, Resolver, not_found, Opts) of
        not_found -> device_ref_1(Name, Rest, Opts);
        Ref -> Ref
    end;
device_ref_1(Name, [_ | Rest], Opts) ->
    device_ref_1(Name, Rest, Opts);
device_ref_1(Name, [], _Opts) ->
    Name.

bundler_gc_hook(DeviceRefs) ->
    #{
        <<"device">> => maps:get(<<"lapee-bundler-gc@1.0">>, DeviceRefs),
        <<"hook">> => #{<<"result">> => <<"ignore">>}
    }.

map_opt(Key, NodeMsg) ->
    case hb_maps:get(Key, NodeMsg, #{}, NodeMsg) of
        Value when is_map(Value) -> Value;
        _ -> #{}
    end.

list_opt(Key, NodeMsg) ->
    case hb_maps:get(Key, NodeMsg, [], NodeMsg) of
        Value when is_list(Value) -> Value;
        Value when is_map(Value) ->
            case hb_util:is_ordered_list(Value, NodeMsg) of
                true -> hb_util:message_to_ordered_list(Value, NodeMsg);
                false -> []
            end;
        _ -> []
    end.

p4_processor(DeviceRefs) ->
    #{
        <<"device">> => <<"p4@1.0">>,
        <<"ledger-device">> => maps:get(<<"process-ledger@1.0">>, DeviceRefs),
        <<"pricing-device">> => maps:get(<<"pricing-router@1.0">>, DeviceRefs),
        <<"default-pricing-device">> => <<"simple-pay@1.0">>,
        <<"ledger-path">> => ?LEDGER_PATH,
        <<"pricing-routes">> => [
            #{
                <<"template">> => <<"/~bundler@1.0/tx">>,
                <<"pricing-device">> =>
                    maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs)
            },
            #{
                <<"template">> => <<"/~bundler@1.0/item">>,
                <<"pricing-device">> =>
                    maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs)
            }
        ]
    }.

bundler_settlement(Address, Beneficiary, DeviceRefs) ->
    #{
        <<"device">> => maps:get(<<"bundler-settlement@1.0">>, DeviceRefs),
        <<"ledger-device">> => maps:get(<<"process-ledger@1.0">>, DeviceRefs),
        <<"pricing-device">> =>
            maps:get(<<"arweave-byte-pricing@1.0">>, DeviceRefs),
        <<"ledger-path">> => ?LEDGER_PATH,
        <<"settlement-account">> => Address,
        <<"beneficiary">> => Beneficiary,
        <<"withdraw">> => true,
        <<"withdraw-device">> => maps:get(<<"ao-payment@1.0">>, DeviceRefs),
        <<"withdraw-token">> => ?AO_TOKEN,
        <<"withdraw-recipient">> => Beneficiary,
        <<"withdrawal-account">> => ?AO_TOKEN,
        <<"hook">> => #{<<"result">> => <<"ignore">>}
    }.

p4_non_chargable_routes(LedgerID) ->
    [
        #{<<"template">> => <<"/*~node-process@1.0/*">>},
        #{<<"template">> => <<?LEDGER_PATH/binary, "/*">>},
        #{<<"template">> => <<"/", LedgerID/binary, "~process@1.0/*">>},
        #{<<"template">> => <<"/~ao-payment@1.0/*">>},
        #{<<"template">> => <<"/~location@1.0/*">>},
        #{<<"template">> => <<"/~p4@1.0/balance">>},
        #{<<"template">> => <<"/~measurement@1.0/*">>},
        #{<<"template">> => <<"/~andee@1.0/*">>},
        #{<<"template">> => <<"/~system@1.0/*">>},
        #{<<"template">> => <<"/~tpm@2.0a/*">>},
        #{<<"template">> => <<"/~meta@1.0/*">>},
        #{<<"template">> => <<"/~query@1.0/*">>},
        #{<<"template">> => <<"/~hyperbuddy@1.0/*">>},
        #{<<"template">> => <<"/graphql">>},
        #{<<"template">> => <<"/schedule">>},
        #{<<"template">> => <<"^/[A-Za-z0-9_-]{43}$">>},
        #{<<"template">> => <<"^/[A-Za-z0-9_-]{43}/.*$">>}
    ].
