%%% @doc P4 ledger adapter for AO-Core process-backed token ledgers.
%%%
%%% This device exposes the P4 ledger API for the AndEE AO payment profile.
%%% The profile still installs the LapEE process ledger for compatibility, but
%%% Android nodes keep the spendable balance table in the live node message so
%%% real AO topups and P4 charges do not require evaluating the large Lua ledger
%%% inside the phone process.
-module(dev_process_ledger).
-export([balance/3, charge/3, credit/4]).
-include_lib("hb/include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% @doc Read the target account balance from the configured ledger process.
balance(Base, Req, NodeMsg) ->
    case {ledger_path(Base, NodeMsg), balance_target(Req, NodeMsg)} of
        {undefined, _} ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        {_, undefined} ->
            {ok, 0};
        {_LedgerPath, Target} ->
            {ok, get_balance(Target, NodeMsg)}
    end.

%% @doc Apply a p4 charge by pushing the signed charge request to the ledger.
charge(Base, Req, NodeMsg) ->
    case ledger_path(Base, NodeMsg) of
        undefined ->
            {error, #{
                <<"status">> => 500,
                <<"body">> => <<"Missing process ledger path.">>
            }};
        _LedgerPath ->
            Account = hb_ao:get(<<"account">>, Req, undefined, NodeMsg),
            Recipient = hb_ao:get(<<"recipient">>, Req, undefined, NodeMsg),
            Quantity = hb_util:int(hb_ao:get(<<"quantity">>, Req, 0, NodeMsg)),
            case {Account, Recipient} of
                {undefined, _} ->
                    {error, #{ <<"status">> => 400, <<"body">> => <<"Missing charge account.">> }};
                {_, undefined} ->
                    {error, #{ <<"status">> => 400, <<"body">> => <<"Missing charge recipient.">> }};
                _ ->
                    {ok, NodeMsg1} =
                        set_balance(Account, get_balance(Account, NodeMsg) - Quantity, NodeMsg),
                    {ok, _NodeMsg2} =
                        set_balance(Recipient, get_balance(Recipient, NodeMsg1) + Quantity, NodeMsg1),
                    {ok, #{
                        <<"debited">> => hb_util:human_id(Account),
                        <<"credited">> => hb_util:human_id(Recipient),
                        <<"quantity">> => Quantity
                    }}
            end
    end.

%% @doc Credit an account after `ao-payment@1.0' has externally verified a real
%% AO token transfer.
credit(_LedgerID, Recipient, Quantity0, NodeMsg) ->
    Quantity = hb_util:int(Quantity0),
    {ok, NewNodeMsg} =
        set_balance(
            Recipient,
            get_balance(Recipient, NodeMsg) + Quantity,
            NodeMsg
        ),
    {ok, NewNodeMsg}.

ledger_path(Base, NodeMsg) ->
    hb_ao:get(<<"ledger-path">>, Base, undefined, NodeMsg).

balance_target(Req, NodeMsg) ->
    case target_from_message(Req, NodeMsg) of
        undefined ->
            case hb_ao:get(<<"request">>, Req, undefined, NodeMsg#{ hashpath => ignore }) of
                undefined -> undefined;
                NestedReq -> target_from_message(NestedReq, NodeMsg)
            end;
        Target ->
            Target
    end.

target_from_message(Msg, NodeMsg) ->
    case normalize_target(hb_ao:get(<<"target">>, Msg, undefined, NodeMsg)) of
        undefined ->
            case hb_message:signers(Msg, NodeMsg) of
                [] -> undefined;
                [Signer | _] -> normalize_target(Signer)
            end;
        Target ->
            Target
    end.

normalize_target(Target) when is_binary(Target) ->
    try hb_util:human_id(Target)
    catch _:_ -> Target
    end;
normalize_target(_) ->
    undefined.

set_balance(Account, Amount, NodeMsg) ->
    LiveNodeMsg = latest_node_msg(NodeMsg),
    NormAccount = hb_util:human_id(Account),
    Ledger = hb_opts:get(ao_payment_ledger_balances, #{}, LiveNodeMsg),
    NewLedger = hb_ao:set(Ledger, NormAccount, Amount, LiveNodeMsg),
    hb_http_server:set_opts(
        #{},
        NewNodeMsg = LiveNodeMsg#{ <<"ao-payment-ledger-balances">> => NewLedger }
    ),
    {ok, NewNodeMsg}.

get_balance(Account, NodeMsg) ->
    NormAccount = hb_util:human_id(Account),
    Ledger = hb_opts:get(ao_payment_ledger_balances, #{}, latest_node_msg(NodeMsg)),
    hb_util:int(hb_ao:get(NormAccount, Ledger, 0, NodeMsg)).

latest_node_msg(NodeMsg) ->
    case hb_opts:get(http_server, no_server_ref, NodeMsg) of
        no_server_ref ->
            NodeMsg;
        _ ->
            try hb_http_server:get_opts(NodeMsg) of
                no_node_msg -> NodeMsg;
                CurrentNodeMsg -> CurrentNodeMsg
            catch
                _:_ -> NodeMsg
            end
    end.

-ifdef(TEST).
missing_ledger_path_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        balance(#{}, #{ <<"target">> => <<"alice">> }, #{})
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 500 }},
        charge(#{}, #{}, #{})
    ).

missing_balance_target_returns_zero_test() ->
    ?assertEqual(
        {ok, 0},
        balance(#{ <<"ledger-path">> => <<"/missing~process@1.0">> }, #{}, #{})
    ).

missing_ledger_balance_returns_zero_test() ->
    ?assertEqual(
        {ok, 0},
        balance(
            #{ <<"ledger-path">> => <<"/missing~process@1.0">> },
            #{ <<"target">> => <<"alice">> },
            #{}
        )
    ).

explicit_target_balance_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, _BobAddress, _HostWallet, _AliceWallet} = test_ledger(100),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"target">> => AliceAddress }, Opts))
    end}.

nested_request_signer_balance_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, _BobAddress, _HostWallet, AliceWallet} = test_ledger(100),
        SignedReq =
            hb_message:commit(
                #{ <<"path">> => <<"/paid-route">> },
                #{ <<"priv-wallet">> => AliceWallet }
            ),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"request">> => SignedReq }, Opts)),
        ?assertEqual({ok, AliceAddress}, {ok, hd(hb_message:signers(SignedReq, Opts))})
    end}.

charge_pushes_to_process_ledger_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, BobAddress, HostWallet, _AliceWallet} = test_ledger(100),
        ChargeReq =
            hb_message:commit(
                #{
                    <<"path">> => <<"charge">>,
                    <<"quantity">> => 2,
                    <<"account">> => AliceAddress,
                    <<"recipient">> => BobAddress,
                    <<"request">> => #{ <<"path">> => <<"/paid-route">> }
                },
                Opts#{ <<"priv-wallet">> => HostWallet }
            ),
        ?assertMatch({ok, _}, charge(Base, ChargeReq, Opts)),
        ?assertEqual({ok, 98}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 2}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

test_ledger(AliceBalance) ->
    Store = hb_test_utils:test_store(),
    HostWallet = ar_wallet:new(),
    AliceWallet = ar_wallet:new(),
    BobWallet = ar_wallet:new(),
    HostAddress = hb_util:human_id(ar_wallet:to_address(HostWallet)),
    AliceAddress = hb_util:human_id(ar_wallet:to_address(AliceWallet)),
    BobAddress = hb_util:human_id(ar_wallet:to_address(BobWallet)),
    Opts = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => HostWallet,
        <<"priv-wallet">> => HostWallet,
        operator => HostAddress,
        <<"operator">> => HostAddress
    },
    {ok, TokenScript} = read_test_script("hyper-token.lua"),
    {ok, ProcessScript} = read_test_script("hyper-token-p4.lua"),
    LedgerProc =
        hb_message:commit(
            #{
                <<"device">> => <<"process@1.0">>,
                <<"type">> => <<"Process">>,
                <<"scheduler-device">> => <<"scheduler@1.0">>,
                <<"scheduler">> => [HostAddress],
                <<"authority">> => [HostAddress],
                <<"admin">> => HostAddress,
                <<"execution-device">> => <<"lua@5.3a">>,
                <<"balance">> => #{ AliceAddress => AliceBalance },
                <<"module">> => [
                    #{
                        <<"content-type">> => <<"text/x-lua">>,
                        <<"name">> => <<"scripts/hyper-token.lua">>,
                        <<"body">> => TokenScript
                    },
                    #{
                        <<"content-type">> => <<"text/x-lua">>,
                        <<"name">> => <<"scripts/hyper-token-p4.lua">>,
                        <<"body">> => ProcessScript
                    }
                ]
            },
            Opts
        ),
    {ok, _} = hb_cache:write(LedgerProc, Opts),
    LedgerID = hb_util:human_id(hb_message:id(LedgerProc, signed, Opts)),
    {
        #{ <<"ledger-path">> => <<"/", LedgerID/binary, "~process@1.0">> },
        Opts,
        AliceAddress,
        BobAddress,
        HostWallet,
        AliceWallet
    }.

read_test_script(Name) ->
    read_first_test_script(test_script_paths(Name), []).

test_script_paths(Name) ->
    NameList = binary_to_list(hb_util:bin(Name)),
    ArchivePriv =
        filename:join([
            hb_device_archive:implementation_dir(?MODULE),
            "priv",
            "lapee-p4",
            NameList
        ]),
    [
        ArchivePriv,
        filename:join([
            "src",
            "priv",
            "dev_lapee_p4_bootstrap",
            "lapee-p4",
            NameList
        ]),
        filename:join(["scripts", NameList])
    ].

read_first_test_script([], Errors) ->
    {error, {missing_script, lists:reverse(Errors)}};
read_first_test_script([Path | Rest], Errors) ->
    case file:read_file(Path) of
        {ok, Body} -> {ok, Body};
        {error, Reason} -> read_first_test_script(Rest, [{Path, Reason} | Errors])
    end.
-endif.
