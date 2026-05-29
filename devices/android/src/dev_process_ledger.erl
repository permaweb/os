%%% @doc P4 ledger adapter for AO-Core process-backed token ledgers.
%%%
%%% This device exposes the P4 ledger API for the AndEE AO payment profile.
%%% The profile still installs the LapEE process ledger for compatibility, but
%%% Android nodes keep the spendable balance table in the live node message so
%%% real AO topups and P4 charges do not require evaluating the large Lua ledger
%%% inside the phone process.
-module(dev_process_ledger).
-export([balance/3, charge/3, credit_once/6]).
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
            with_ledger_lock(fun() -> charge_locked(Req, NodeMsg) end)
    end.

credit_once(_LedgerID, Recipient, Quantity0, ImportKey, ImportValue, NodeMsg) ->
    case {normalize_target(Recipient), parse_positive_quantity(Quantity0)} of
        {undefined, _} ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Invalid credit recipient.">>
            }};
        {RecipientID, {ok, Quantity}} ->
            with_ledger_lock(fun() ->
                LiveNodeMsg = latest_node_msg(NodeMsg),
                Imports = hb_opts:get(ao_payment_imports, #{}, LiveNodeMsg),
                case maps:find(ImportKey, Imports) of
                    {ok, Existing} ->
                        {ok, already_imported, Existing};
                    error ->
                        NewNodeMsg0 =
                            set_balance_in_msg(
                                RecipientID,
                                get_balance_from(RecipientID, LiveNodeMsg) + Quantity,
                                LiveNodeMsg
                            ),
                        NewImports =
                            set_message_key(
                                Imports,
                                ImportKey,
                                ImportValue,
                                LiveNodeMsg
                            ),
                        NewNodeMsg =
                            set_message_key(
                                NewNodeMsg0,
                                <<"ao-payment-imports">>,
                                NewImports,
                                LiveNodeMsg
                            ),
                        hb_http_server:set_opts(#{}, NewNodeMsg),
                        {ok, imported, NewNodeMsg}
                end
            end);
        {_, error} ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Invalid credit quantity.">>
            }}
    end.

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
    catch _:_ -> undefined
    end;
normalize_target(_) ->
    undefined.

committed_charge(Req, NodeMsg) ->
    Operator = normalize_target(hb_opts:get(operator, undefined, NodeMsg)),
    case Operator =/= undefined
        andalso charge_signed_by_operator(Req, Operator, NodeMsg)
    of
        true -> committed_charge_fields(Req, Operator, NodeMsg);
        false -> {error, 403, <<"Charge request is not authorized.">>}
    end.

charge_signed_by_operator(Req, Operator, NodeMsg) ->
    try hb_message:verify(Req, [Operator], NodeMsg) of
        true -> true;
        _ -> false
    catch
        _:_ -> false
    end.

committed_charge_fields(Req, Operator, NodeMsg) ->
    Required = [
        <<"path">>,
        <<"quantity">>,
        <<"account">>,
        <<"recipient">>,
        <<"request">>
    ],
    try hb_message:committed(
            Req,
            #{<<"committers">> => [Operator], <<"raw">> => true},
            NodeMsg) of
        RawCommitted ->
            case has_exact_committed_charge_fields(Required, RawCommitted)
                andalso no_link_variants(Required, Req)
            of
                true ->
                    {ok, hb_maps:with([<<"commitments">> | Required], Req, NodeMsg)};
                false ->
                    {error, 403, <<"Charge request fields are not committed exactly.">>}
            end
    catch
        _:_ -> {error, 403, <<"Charge request fields are not committed exactly.">>}
    end.

has_exact_committed_charge_fields(Required, RawCommitted) ->
    lists:all(fun(Key) -> lists:member(Key, RawCommitted) end, Required)
        andalso not lists:any(fun hb_link:is_link_key/1, RawCommitted).

no_link_variants(Required, Req) ->
    not lists:any(
        fun(Key) ->
            maps:is_key(<<Key/binary, "+link">>, Req)
        end,
        Required
    ).

charge_locked(Req, NodeMsg) ->
    LiveNodeMsg = latest_node_msg(NodeMsg),
    case committed_charge(Req, LiveNodeMsg) of
        {ok, Charge} ->
            charge_committed(Charge, LiveNodeMsg);
        {error, Status, Body} ->
            {error, #{<<"status">> => Status, <<"body">> => Body}}
    end.

charge_committed(Charge, LiveNodeMsg) ->
    Account = hb_maps:get(<<"account">>, Charge, undefined, LiveNodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Charge, undefined, LiveNodeMsg),
    Quantity0 = hb_maps:get(<<"quantity">>, Charge, 0, LiveNodeMsg),
    case {Account, Recipient, parse_positive_quantity(Quantity0)} of
        {undefined, _, _} ->
            {error, #{ <<"status">> => 400, <<"body">> => <<"Missing charge account.">> }};
        {_, undefined, _} ->
            {error, #{ <<"status">> => 400, <<"body">> => <<"Missing charge recipient.">> }};
        {_, _, error} ->
            {error, #{<<"status">> => 400, <<"body">> => <<"Invalid charge quantity.">>}};
        {_, _, {ok, Quantity}} ->
            charge_accounts(Account, Recipient, Quantity, Charge, LiveNodeMsg)
    end.

charge_accounts(Account, Recipient, Quantity, Charge, LiveNodeMsg) ->
    AccountID = normalize_target(Account),
    RecipientID = normalize_target(Recipient),
    case {AccountID, RecipientID} of
        {undefined, _} ->
            {error, #{<<"status">> => 400, <<"body">> => <<"Invalid charge account.">>}};
        {_, undefined} ->
            {error, #{<<"status">> => 400, <<"body">> => <<"Invalid charge recipient.">>}};
        _ ->
            charge_valid_accounts(AccountID, RecipientID, Quantity, Charge, LiveNodeMsg)
    end.

charge_valid_accounts(AccountID, RecipientID, Quantity, Charge, LiveNodeMsg) ->
    Balance = get_balance_from(AccountID, LiveNodeMsg),
    Charges = hb_opts:get(ao_payment_charges, #{}, LiveNodeMsg),
    ChargeKey = charge_key(Charge, AccountID, RecipientID, Quantity, LiveNodeMsg),
    case maps:find(ChargeKey, Charges) of
        {ok, Existing} ->
            {ok, Existing#{<<"status">> => <<"already-charged">>}};
        error when Balance < Quantity ->
            {error, #{<<"status">> => 402, <<"body">> => <<"Insufficient balance.">>}};
        error ->
            NewNodeMsg =
                case AccountID =:= RecipientID of
                    true ->
                        LiveNodeMsg;
                    false ->
                        NodeMsg1 =
                            set_balance_in_msg(
                                AccountID,
                                Balance - Quantity,
                                LiveNodeMsg
                            ),
                        set_balance_in_msg(
                            RecipientID,
                            get_balance_from(RecipientID, NodeMsg1) + Quantity,
                            NodeMsg1
                        )
                end,
            ChargeValue = #{
                <<"debited">> => AccountID,
                <<"credited">> => RecipientID,
                <<"quantity">> => Quantity,
                <<"status">> => <<"charged">>
            },
            NewCharges =
                set_message_key(Charges, ChargeKey, ChargeValue, LiveNodeMsg),
            hb_http_server:set_opts(
                #{},
                set_message_key(
                    NewNodeMsg,
                    <<"ao-payment-charges">>,
                    NewCharges,
                    LiveNodeMsg
                )
            ),
            {ok, ChargeValue}
    end.

set_balance_in_msg(Account, Amount, NodeMsg) ->
    NormAccount = hb_util:human_id(Account),
    Ledger = hb_opts:get(ao_payment_ledger_balances, #{}, NodeMsg),
    NewLedger = set_message_key(Ledger, NormAccount, Amount, NodeMsg),
    set_message_key(NodeMsg, <<"ao-payment-ledger-balances">>, NewLedger, NodeMsg).

set_message_key(Msg, Key, Value, Opts) ->
    hb_maps:put(Key, Value, hb_message:uncommitted(Msg, Opts), Opts).

get_balance(Account, NodeMsg) ->
    get_balance_from(Account, latest_node_msg(NodeMsg)).

get_balance_from(Account, NodeMsg) ->
    NormAccount = hb_util:human_id(Account),
    Ledger = hb_opts:get(ao_payment_ledger_balances, #{}, NodeMsg),
    hb_util:int(hb_ao:get(NormAccount, Ledger, 0, NodeMsg)).

parse_positive_quantity(Quantity0) ->
    try hb_util:int(Quantity0) of
        Quantity when Quantity > 0 -> {ok, Quantity};
        _ -> error
    catch
        _:_ -> error
    end.

with_ledger_lock(Fun) ->
    global:trans({?MODULE, ao_payment_ledger}, Fun, [node()], infinity).

charge_key(Charge, Account, Recipient, Quantity, NodeMsg) ->
    Request = hb_maps:get(<<"request">>, Charge, undefined, NodeMsg),
    RequestKey =
        case Request of
            undefined -> message_key(Charge, NodeMsg);
            _ -> message_key(Request, NodeMsg)
        end,
    <<Account/binary, ":", Recipient/binary, ":",
        (integer_to_binary(Quantity))/binary, ":", RequestKey/binary>>.

message_key(Msg, NodeMsg) ->
    try hb_message:id(Msg, all, NodeMsg)
    catch
        _:_ -> hb_util:encode(crypto:hash(sha256, term_to_binary(Msg)))
    end.

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

charge_replay_is_idempotent_test_() ->
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
        ?assertMatch({ok, #{<<"status">> := <<"charged">>}}, charge(Base, ChargeReq, Opts)),
        ?assertMatch(
            {ok, #{<<"status">> := <<"already-charged">>}},
            charge(Base, ChargeReq, Opts)),
        ?assertEqual({ok, 98}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 2}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

charge_rejects_unsigned_field_overlay_test_() ->
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
        ?assertMatch(
            {error, #{<<"status">> := 403}},
            charge(Base, ChargeReq#{<<"quantity">> => 99}, Opts)),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 0}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

charge_rejects_link_shape_field_overlay_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, BobAddress, HostWallet, _AliceWallet} = test_ledger(100),
        ChargeReq =
            hb_message:commit(
                #{
                    <<"path">> => <<"charge">>,
                    <<"quantity">> => 2,
                    <<"account+link">> => AliceAddress,
                    <<"recipient">> => BobAddress,
                    <<"request">> => #{ <<"path">> => <<"/paid-route">> }
                },
                Opts#{ <<"priv-wallet">> => HostWallet }
            ),
        ?assertMatch(
            {error, #{<<"status">> := 403}},
            charge(Base, ChargeReq#{<<"account">> => AliceAddress}, Opts)),
        ?assertEqual({ok, 100}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 0}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

charge_rejects_invalid_or_insufficient_balance_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, BobAddress, HostWallet, _AliceWallet} = test_ledger(1),
        Req0 = #{
            <<"path">> => <<"charge">>,
            <<"account">> => AliceAddress,
            <<"recipient">> => BobAddress,
            <<"request">> => #{ <<"path">> => <<"/paid-route">> }
        },
        ?assertMatch(
            {error, #{ <<"status">> := 400 }},
            charge(
                Base,
                hb_message:commit(Req0#{<<"quantity">> => -1}, Opts#{
                    <<"priv-wallet">> => HostWallet
                }),
                Opts)),
        ?assertMatch(
            {error, #{ <<"status">> := 402 }},
            charge(
                Base,
                hb_message:commit(Req0#{<<"quantity">> => 2}, Opts#{
                    <<"priv-wallet">> => HostWallet
                }),
                Opts)),
        ?assertEqual({ok, 1}, balance(Base, #{ <<"target">> => AliceAddress }, Opts)),
        ?assertEqual({ok, 0}, balance(Base, #{ <<"target">> => BobAddress }, Opts))
    end}.

charge_requires_operator_signature_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, AliceAddress, BobAddress, _HostWallet, _AliceWallet} =
            test_ledger(100),
        ?assertMatch(
            {error, #{ <<"status">> := 403 }},
            charge(
                Base,
                #{
                    <<"quantity">> => 1,
                    <<"account">> => AliceAddress,
                    <<"recipient">> => BobAddress
                },
                Opts))
    end}.

credit_once_is_idempotent_test_() ->
    {timeout, 30, fun() ->
        {Base, Opts, _AliceAddress, BobAddress, _HostWallet, _AliceWallet} =
            test_ledger(0),
        Key = <<"token:ledger:deposit:message">>,
        Payment = #{<<"status">> => <<"imported">>},
        {ok, imported, NodeMsg1} =
            credit_once(<<"ledger">>, BobAddress, 7, Key, Payment, Opts),
        ?assertMatch(
            {ok, already_imported, _},
            credit_once(<<"ledger">>, BobAddress, 7, Key, Payment, NodeMsg1)),
        ?assertEqual({ok, 7}, balance(Base, #{ <<"target">> => BobAddress }, NodeMsg1))
    end}.

test_ledger(AliceBalance) ->
    Store = hb_test_utils:test_store(),
    HostWallet = ar_wallet:new(),
    AliceWallet = ar_wallet:new(),
    BobWallet = ar_wallet:new(),
    HostAddress = hb_util:human_id(ar_wallet:to_address(HostWallet)),
    AliceAddress = hb_util:human_id(ar_wallet:to_address(AliceWallet)),
    BobAddress = hb_util:human_id(ar_wallet:to_address(BobWallet)),
    Opts0 = #{
        store => Store,
        <<"store">> => Store,
        priv_wallet => HostWallet,
        <<"priv-wallet">> => HostWallet,
        operator => HostAddress,
        <<"operator">> => HostAddress,
        <<"port">> => 0,
        <<"ao-payment-ledger-balances">> => #{AliceAddress => AliceBalance}
    },
    {ok, _Listener} = hb_http_server:start(Opts0),
    Opts = Opts0#{<<"http-server">> => HostAddress},
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
    ArchiveRoot =
        filename:join([
            hb_device_archive:implementation_dir(?MODULE),
            "lapee-p4",
            NameList
        ]),
    ArchivePriv =
        filename:join([
            hb_device_archive:implementation_dir(?MODULE),
            "priv",
            "lapee-p4",
            NameList
        ]),
    [
        ArchiveRoot,
        ArchivePriv,
        filename:join(["priv", "lapee-p4", NameList]),
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
