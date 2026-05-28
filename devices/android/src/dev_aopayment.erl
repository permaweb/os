%%% @doc Import verified AO token payments into a local HyperBEAM payment
%%% ledger. This device expects production AO token transfers of the form:
%%%
%%%     Action=Transfer, Recipient=<node deposit address>, Quantity=<raw units>
%%%
%%% It verifies the resulting `Debit-Notice' and `Credit-Notice' from AO
%%% mainnet state before scheduling a local `Credit-Notice' into the configured
%%% ledger process.
-module(dev_aopayment).
-implements(<<"ao-payment@1.0">>).
-export([ingest/3, verify/3, withdraw/3]).
-include_lib("hb/include/hb.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(DEFAULT_AO_TOKEN, <<"0syT13r0s0tgPmIed95bJnuSqaD29HQNN8D3ElLSrsc">>).
-define(DEFAULT_MAINNET_URL, <<"https://state.forward.computer">>).
-define(DEFAULT_CU_URL, <<"https://cu.ao-testnet.xyz">>).
-define(DEFAULT_SCHEDULER_URL, <<"https://su-router.ao-testnet.xyz">>).
-define(DEFAULT_SUBMIT_URL, <<"https://mu.ao-testnet.xyz">>).
-define(HTTP_TIMEOUT_MS, 30000).

%% @doc Verify and import an AO token payment into the local ledger.
ingest(Base, Req, NodeMsg) ->
    case verify(Base, Req, NodeMsg) of
        {ok, Payment} ->
            PaymentKey = payment_key(Payment, NodeMsg),
            ImportValue = Payment#{<<"status">> => <<"imported">>},
            case import_payment(Payment, PaymentKey, ImportValue, NodeMsg) of
                {ok, already_imported, Existing} ->
                    {ok, Existing#{ <<"status">> => <<"already-imported">> }};
                {ok, imported, _UpdatedNodeMsg} ->
                    {ok, ImportValue};
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

%% @doc Submit a real AO transfer from the node wallet to the configured
%% beneficiary. This is guarded by a boot-generated secret so the route is not
%% an arbitrary signing endpoint when exposed over HTTP.
withdraw(Base, Req, NodeMsg) ->
    case validate_withdrawal(Base, Req, NodeMsg) of
        {ok, Withdrawal} ->
            Key = withdrawal_key(Withdrawal, NodeMsg),
            case reserve_withdrawal(Key, Withdrawal, NodeMsg) of
                {ok, reserved} ->
                    case submit_withdrawal(Withdrawal, NodeMsg) of
                        {ok, Result} ->
                            Stored = Result#{ <<"status">> => <<"submitted">> },
                            record_withdrawal(Key, Stored, NodeMsg),
                            {ok, Stored};
                        Error ->
                            record_withdrawal(
                                Key,
                                Withdrawal#{
                                    <<"status">> => <<"failed">>,
                                    <<"error">> => Error
                                },
                                NodeMsg
                            ),
                            Error
                    end;
                {ok, Existing} ->
                    existing_withdrawal_result(Existing, NodeMsg)
            end;
        Error ->
            Error
    end.

%% @doc Verify that an AO message produced matching token debit/credit notices.
verify(_Base, Req, NodeMsg) ->
    Token = hb_opts:get(ao_payment_token, ?DEFAULT_AO_TOKEN, NodeMsg),
    Ledger = hb_opts:get(ao_payment_ledger, undefined, NodeMsg),
    DepositAddress =
        hb_opts:get(
            ao_payment_deposit_address,
            hb_opts:get(operator, Ledger, NodeMsg),
            NodeMsg
        ),
    MessageID = hb_ao:get(<<"message-id">>, Req, hb_ao:get(<<"id">>, Req, undefined, NodeMsg), NodeMsg),
    Slot = hb_ao:get(<<"slot">>, Req, undefined, NodeMsg),
    Sender = hb_ao:get(<<"sender">>, Req, undefined, NodeMsg),
    Quantity0 = hb_ao:get(<<"quantity">>, Req, undefined, NodeMsg),
    RequestedRecipient = hb_ao:get(<<"recipient">>, Req, undefined, NodeMsg),
    Quantity =
        case parse_positive_quantity(Quantity0) of
            {ok, PositiveQuantity} -> integer_to_binary(PositiveQuantity);
            {error, _} -> undefined
        end,
    case lists:any(
        fun(V) -> V =:= undefined orelse V =:= <<"undefined">> end,
        [Token, Ledger, DepositAddress, MessageID, Slot, Sender, Quantity])
    of
        true ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Missing token, ledger, deposit-address, message-id, slot, sender, or quantity.">>
            }};
        false ->
            case fetch_schedule(Token, Slot, MessageID, NodeMsg) of
                {ok, Result} ->
                    Expected = #{
                        <<"token">> => Token,
                        <<"ledger">> => Ledger,
                        <<"deposit-address">> => DepositAddress,
                        <<"message-id">> => MessageID,
                        <<"slot">> => hb_util:bin(Slot),
                        <<"sender">> => Sender,
                        <<"quantity">> => Quantity,
                        <<"requested-recipient">> => RequestedRecipient
                    },
                    case verify_schedule(Result, Expected, NodeMsg) of
                        ok ->
                            case fetch_result(Token, Slot, MessageID, NodeMsg) of
                                {ok, ComputeResult} ->
                                    verify_result(ComputeResult, Expected, NodeMsg);
                                {error, Reason} ->
                                    fetch_error(Reason)
                            end;
                        Error ->
                            Error
                    end;
                {error, Reason} ->
                    fetch_error(Reason)
            end
    end.

fetch_schedule(Token, Slot, MessageID, NodeMsg) ->
    case fetch_modern_schedule(Token, MessageID, NodeMsg) of
        {ok, Schedule} -> {ok, Schedule};
        {error, _Reason} -> fetch_legacy_schedule(Token, Slot, NodeMsg)
    end.

fetch_modern_schedule(Token, MessageID, NodeMsg) ->
    BaseURL = scheduler_url(NodeMsg),
    URL = <<BaseURL/binary, "/", MessageID/binary, "?process-id=", Token/binary>>,
    fetch_json(URL).

fetch_legacy_schedule(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/schedule?from=",
            SlotBin/binary, "&to=", SlotBin/binary, "&accept=application/aos-2">>,
    fetch_json(URL).

fetch_result(Token, Slot, MessageID, NodeMsg) ->
    case fetch_modern_result(Token, MessageID, NodeMsg) of
        {ok, Result} -> {ok, Result};
        {error, _Reason} -> fetch_legacy_result(Token, Slot, NodeMsg)
    end.

fetch_modern_result(Token, MessageID, NodeMsg) ->
    BaseURL = cu_url(NodeMsg),
    URL = <<BaseURL/binary, "/result/", MessageID/binary,
            "?process-id=", Token/binary>>,
    fetch_json(URL).

fetch_legacy_result(Token, Slot, NodeMsg) ->
    BaseURL = mainnet_url(NodeMsg),
    SlotBin = hb_util:bin(Slot),
    URL =
        <<BaseURL/binary, "/", Token/binary, "~process@1.0/compute&slot=",
            SlotBin/binary,
            "/results?require-codec=application/json&accept-bundle=true">>,
    fetch_json(URL).

mainnet_url(NodeMsg) ->
    URL0 = hb_opts:get(ao_payment_mainnet_url, ?DEFAULT_MAINNET_URL, NodeMsg),
    case binary:last(URL0) of
            $/ -> binary:part(URL0, 0, byte_size(URL0) - 1);
            _ -> URL0
    end.

cu_url(NodeMsg) ->
    normalize_url(hb_opts:get(ao_payment_cu_url, ?DEFAULT_CU_URL, NodeMsg)).

scheduler_url(NodeMsg) ->
    normalize_url(
        hb_opts:get(
            ao_payment_scheduler_url,
            ?DEFAULT_SCHEDULER_URL,
            NodeMsg)).

fetch_json(URL) ->
    case httpc:request(
        get,
        {binary_to_list(URL), [{"accept", "application/json"}]},
        http_options(),
        [{body_format, binary}]
    ) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            {ok, hb_json:decode(Body)};
        {ok, {{_, Status, _}, _Headers, Body}} ->
            {error, {http_status, Status, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

fetch_error(Reason) ->
    {error, #{
        <<"status">> => 502,
        <<"body">> => <<"Unable to fetch AO payment data from mainnet endpoint.">>,
        <<"reason">> => format_reason(Reason)
    }}.

format_reason(Reason) when is_binary(Reason) -> Reason;
format_reason(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).

verify_schedule(#{<<"message">> := Message, <<"assignment">> := Assignment},
                Expected,
                NodeMsg) ->
    MessageID = hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Slot = hb_maps:get(<<"slot">>, Expected, undefined, NodeMsg),
    MessageTags = hb_maps:get(<<"tags">>, Message, [], NodeMsg),
    AssignmentTags = hb_maps:get(<<"tags">>, Assignment, [], NodeMsg),
    case hb_maps:get(<<"id">>, Message, undefined, NodeMsg) =:= MessageID
        andalso hb_maps:get(<<"target">>, Message, undefined, NodeMsg)
            =:= hb_maps:get(<<"token">>, Expected, undefined, NodeMsg)
        andalso tag_value(MessageTags, <<"Action">>, NodeMsg) =:= <<"Transfer">>
        andalso tag_value(MessageTags, <<"Recipient">>, NodeMsg) =:= DepositAddress
        andalso hb_util:bin(tag_value(MessageTags, <<"Quantity">>, NodeMsg)) =:= Quantity
        andalso tag_value(AssignmentTags, <<"Message">>, NodeMsg) =:= MessageID
        andalso hb_util:bin(tag_value(AssignmentTags, <<"Nonce">>, NodeMsg)) =:= Slot
    of
        true -> ok;
        false ->
            {error, #{
                <<"status">> => 402,
                <<"body">> =>
                    <<"AO scheduler did not contain the expected Transfer assignment.">>
            }}
    end;
verify_schedule(Schedule, Expected, NodeMsg) ->
    Edges = hb_maps:get(<<"edges">>, Schedule, [], NodeMsg),
    MessageID = hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Slot = hb_maps:get(<<"slot">>, Expected, undefined, NodeMsg),
    Found =
        lists:any(
            fun(Edge) ->
                Node = hb_maps:get(<<"node">>, Edge, #{}, NodeMsg),
                Message = hb_maps:get(<<"message">>, Node, #{}, NodeMsg),
                Assignment = hb_maps:get(<<"assignment">>, Node, #{}, NodeMsg),
                MessageTags = hb_maps:get(<<"Tags">>, Message, [], NodeMsg),
                AssignmentTags = hb_maps:get(<<"Tags">>, Assignment, [], NodeMsg),
                hb_maps:get(<<"Id">>, Message, undefined, NodeMsg) =:= MessageID
                    andalso tag_value(MessageTags, <<"Action">>, NodeMsg) =:= <<"Transfer">>
                    andalso tag_value(MessageTags, <<"Recipient">>, NodeMsg) =:= DepositAddress
                    andalso hb_util:bin(tag_value(MessageTags, <<"Quantity">>, NodeMsg)) =:= Quantity
                    andalso hb_util:bin(tag_value(AssignmentTags, <<"Nonce">>, NodeMsg)) =:= Slot
            end,
            Edges
        ),
    case Found of
        true -> ok;
        false ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO schedule did not contain the expected Transfer assignment.">>
            }}
    end.

verify_result(Result, Expected, NodeMsg) ->
    Raw = hb_maps:get(<<"raw">>, Result, Result, NodeMsg),
    Messages = hb_maps:get(<<"Messages">>, Raw, [], NodeMsg),
    DepositAddress = hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
    Debit = find_notice(
        <<"Debit-Notice">>,
        Sender,
        #{<<"Recipient">> => DepositAddress, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    Credit = find_notice(
        <<"Credit-Notice">>,
        DepositAddress,
        #{<<"Sender">> => Sender, <<"Quantity">> => Quantity},
        Messages,
        NodeMsg
    ),
    case {Debit, Credit} of
        {{value, _DebitMsg}, {value, CreditMsg}} ->
            credit_to_payment(CreditMsg, Expected, NodeMsg);
        _ ->
            {error, #{
                <<"status">> => 402,
                <<"body">> => <<"AO result did not contain the expected Debit-Notice and Credit-Notice.">>
            }}
    end.

find_notice(Action, Target, RequiredTags, Messages, NodeMsg) ->
    lists:search(
        fun(Msg) ->
            Tags = hb_maps:get(<<"Tags">>, Msg, [], NodeMsg),
            hb_maps:get(<<"Target">>, Msg, undefined, NodeMsg) =:= Target
                andalso tag_value(Tags, <<"Action">>, NodeMsg) =:= Action
                andalso maps:fold(
                    fun(Name, Value, Acc) ->
                        Acc andalso hb_util:bin(tag_value(Tags, Name, NodeMsg)) =:= Value
                    end,
                    true,
                    RequiredTags
                )
        end,
        Messages
    ).

credit_to_payment(CreditMsg, Expected, NodeMsg) ->
    Tags = hb_maps:get(<<"Tags">>, CreditMsg, [], NodeMsg),
    Sender = hb_maps:get(<<"sender">>, Expected, undefined, NodeMsg),
    RequestedRecipient = hb_maps:get(<<"requested-recipient">>, Expected, undefined, NodeMsg),
    Recipient =
        case tag_value(Tags, <<"X-HB-Recipient">>, NodeMsg) of
            undefined -> Sender;
            ForwardedRecipient -> ForwardedRecipient
        end,
    case RequestedRecipient =:= undefined orelse RequestedRecipient =:= Recipient of
        true ->
            {ok, #{
                <<"token">> => hb_maps:get(<<"token">>, Expected, undefined, NodeMsg),
                <<"message-id">> => hb_maps:get(<<"message-id">>, Expected, undefined, NodeMsg),
                <<"ledger">> => hb_maps:get(<<"ledger">>, Expected, undefined, NodeMsg),
                <<"deposit-address">> =>
                    hb_maps:get(<<"deposit-address">>, Expected, undefined, NodeMsg),
                <<"sender">> => Sender,
                <<"recipient">> => Recipient,
                <<"quantity">> => hb_maps:get(<<"quantity">>, Expected, undefined, NodeMsg),
                <<"notice-reference">> => tag_value(Tags, <<"Reference">>, NodeMsg)
            }};
        false ->
            {error, #{
                <<"status">> => 400,
                <<"body">> => <<"Requested recipient does not match AO Credit-Notice.">>,
                <<"recipient">> => Recipient
            }}
    end.

import_payment(Payment, PaymentKey, ImportValue, NodeMsg) ->
    Opts = (wallet_opts(NodeMsg))#{ <<"scheduling-mode">> => aggressive },
    Ledger = hb_maps:get(<<"ledger">>, Payment, undefined, NodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Payment, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Payment, undefined, NodeMsg),
    dev_process_ledger:credit_once(
        Ledger,
        Recipient,
        Quantity,
        PaymentKey,
        ImportValue,
        Opts).

reserve_withdrawal(Key, Withdrawal, NodeMsg) ->
    with_payment_lock(fun() ->
        LiveNodeMsg = latest_node_msg(NodeMsg),
        Withdrawals = hb_opts:get(ao_payment_withdrawals, #{}, LiveNodeMsg),
        case maps:find(Key, Withdrawals) of
            {ok, Existing} ->
                {ok, Existing};
            error ->
                Pending = Withdrawal#{<<"status">> => <<"pending">>},
                hb_http_server:set_opts(
                    LiveNodeMsg#{
                        <<"ao-payment-withdrawals">> => Withdrawals#{Key => Pending}
                    }
                ),
                {ok, reserved}
        end
    end).

record_withdrawal(Key, Stored, NodeMsg) ->
    with_payment_lock(fun() ->
        LiveNodeMsg = latest_node_msg(NodeMsg),
        Withdrawals = hb_opts:get(ao_payment_withdrawals, #{}, LiveNodeMsg),
        hb_http_server:set_opts(
            LiveNodeMsg#{
                <<"ao-payment-withdrawals">> => Withdrawals#{Key => Stored}
            }
        )
    end).

existing_withdrawal_result(Existing, NodeMsg) ->
    case hb_maps:get(<<"status">>, Existing, undefined, NodeMsg) of
        <<"submitted">> ->
            {ok, Existing#{ <<"status">> => <<"already-submitted">> }};
        <<"pending">> ->
            withdraw_error(409, <<"Withdrawal is already pending.">>);
        <<"failed">> ->
            withdraw_error(502, <<"Withdrawal previously failed.">>);
        _ ->
            {ok, Existing}
    end.

validate_withdrawal(Base, Req, NodeMsg) ->
    ExpectedSecret = withdraw_secret(NodeMsg),
    SuppliedSecret =
        hb_ao:get(<<"withdraw-secret">>, Req, undefined, NodeMsg),
    case ExpectedSecret of
        undefined ->
            withdraw_error(403, <<"AO payment withdrawals are not enabled.">>);
        SuppliedSecret ->
            validate_withdrawal_fields(Base, Req, NodeMsg);
        _ ->
            withdraw_error(403, <<"Invalid AO payment withdrawal secret.">>)
    end.

validate_withdrawal_fields(Base, Req, NodeMsg) ->
    Token =
        hb_ao:get(
            <<"token">>,
            Req,
            hb_maps:get(
                <<"token">>,
                Base,
                hb_opts:get(ao_payment_token, ?DEFAULT_AO_TOKEN, NodeMsg),
                NodeMsg
            ),
            NodeMsg
        ),
    Recipient = hb_ao:get(<<"recipient">>, Req, undefined, NodeMsg),
    Quantity0 = hb_ao:get(<<"quantity">>, Req, undefined, NodeMsg),
    WithdrawID = hb_ao:get(<<"withdraw-id">>, Req, undefined, NodeMsg),
    case {Recipient, parse_positive_quantity(Quantity0)} of
        {undefined, _} ->
            withdraw_error(400, <<"Missing withdrawal recipient.">>);
        {_, {error, _}} ->
            withdraw_error(400, <<"Invalid withdrawal quantity.">>);
        {_, {ok, Quantity}} ->
            AllowedRecipient = allowed_withdraw_recipient(Base, NodeMsg),
            case AllowedRecipient =:= undefined
                orelse hb_util:human_id(AllowedRecipient) =:=
                    hb_util:human_id(Recipient)
            of
                true ->
                    {ok, #{
                        <<"token">> => hb_util:human_id(Token),
                        <<"recipient">> => hb_util:human_id(Recipient),
                        <<"quantity">> => Quantity,
                        <<"withdraw-id">> => WithdrawID,
                        <<"submit-url">> => submit_url(Base, NodeMsg)
                    }};
                false ->
                    withdraw_error(
                        403,
                        <<"Withdrawal recipient does not match configured beneficiary.">>
                    )
            end
    end.

withdraw_secret(NodeMsg) ->
    hb_private:get(
        <<"ao-payment-withdraw-secret">>,
        NodeMsg,
        hb_private:get(<<"withdraw-secret">>, NodeMsg, undefined, NodeMsg),
        NodeMsg
    ).

allowed_withdraw_recipient(Base, NodeMsg) ->
    hb_opts:get(
        ao_payment_withdraw_recipient,
        hb_maps:get(<<"withdraw-recipient">>, Base, undefined, NodeMsg),
        NodeMsg
    ).

parse_positive_quantity(undefined) ->
    {error, missing};
parse_positive_quantity(Quantity0) ->
    try hb_util:int(Quantity0) of
        Quantity when Quantity > 0 -> {ok, Quantity};
        _ -> {error, invalid}
    catch
        _:_ -> {error, invalid}
    end.

submit_withdrawal(Withdrawal, NodeMsg) ->
    Opts = wallet_opts(NodeMsg),
    Token = hb_maps:get(<<"token">>, Withdrawal, ?DEFAULT_AO_TOKEN, NodeMsg),
    Recipient = hb_maps:get(<<"recipient">>, Withdrawal, undefined, NodeMsg),
    Quantity = hb_maps:get(<<"quantity">>, Withdrawal, undefined, NodeMsg),
    Msg =
        hb_message:commit(
            #{
                <<"target">> => Token,
                <<"data">> => <<"1984">>,
                <<"Data-Protocol">> => <<"ao">>,
                <<"Variant">> => <<"ao.TN.1">>,
                <<"Type">> => <<"Message">>,
                <<"Action">> => <<"Transfer">>,
                <<"Recipient">> => Recipient,
                <<"Quantity">> => hb_util:bin(Quantity),
                <<"Content-Type">> => <<"text/plain">>,
                <<"SDK">> => <<"hyperbeam-lapee">>
            },
            Opts,
            <<"ans104@1.0">>
        ),
    MessageID = hb_message:id(Msg, signed, Opts),
    case post_legacy_mu(
        hb_maps:get(<<"submit-url">>, Withdrawal, ?DEFAULT_SUBMIT_URL, NodeMsg),
        Msg,
        Opts
    ) of
        {ok, SubmitResult} ->
            {ok, #{
                <<"message-id">> => MessageID,
                <<"token">> => Token,
                <<"recipient">> => Recipient,
                <<"quantity">> => Quantity,
                <<"submit-response">> => SubmitResult
            }};
        {error, Reason} ->
            withdraw_fetch_error(Reason)
    end.

post_legacy_mu(SubmitURL0, Msg, Opts) ->
    SubmitURL = normalize_url(SubmitURL0),
    Item = hb_message:convert(Msg, <<"ans104@1.0">>, Opts),
    Body = ar_bundles:serialize(Item),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    Request = {
        binary_to_list(SubmitURL),
        [{"accept", "application/json"}],
        "application/octet-stream",
        Body
    },
    case httpc:request(post, Request, http_options(), [{body_format, binary}]) of
        {ok, {{_, Status, _}, _Headers, ResponseBody}}
                when Status >= 200, Status < 300 ->
            {ok, #{
                <<"status">> => Status,
                <<"body">> => ResponseBody
            }};
        {ok, {{_, Status, _}, _Headers, ResponseBody}} ->
            {error, #{
                <<"status">> => Status,
                <<"body">> => ResponseBody
            }};
        {error, Reason} ->
            {error, Reason}
    end.

http_options() ->
    [
        {timeout, ?HTTP_TIMEOUT_MS},
        {connect_timeout, ?HTTP_TIMEOUT_MS},
        {autoredirect, true},
        {ssl, [
            {verify, verify_peer},
            {cacertfile, certifi:cacertfile()},
            {customize_hostname_check, [
                {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
            ]}
        ]}
    ].

submit_url(Base, NodeMsg) ->
    Configured =
        hb_opts:get(
            ao_payment_submit_url,
            hb_opts:get(ao_payment_mu_url, ?DEFAULT_SUBMIT_URL, NodeMsg),
            NodeMsg
        ),
    hb_maps:get(
        <<"submit-url">>,
        Base,
        hb_maps:get(<<"mu-url">>, Base, Configured, NodeMsg),
        NodeMsg
    ).

normalize_url(URL0) ->
    URL = hb_util:bin(URL0),
    case binary:last(URL) of
        $/ -> binary:part(URL, 0, byte_size(URL) - 1);
        _ -> URL
    end.

withdrawal_key(Withdrawal, Opts) ->
    case hb_maps:get(<<"withdraw-id">>, Withdrawal, undefined, Opts) of
        undefined ->
            <<(hb_maps:get(<<"token">>, Withdrawal, undefined, Opts))/binary, ":",
                (hb_maps:get(<<"recipient">>, Withdrawal, undefined, Opts))/binary, ":",
                (hb_util:bin(hb_maps:get(<<"quantity">>, Withdrawal, undefined, Opts)))/binary>>;
        WithdrawID ->
            hb_util:bin(WithdrawID)
    end.

withdraw_error(Status, Body) ->
    {error, #{ <<"status">> => Status, <<"body">> => Body }}.

withdraw_fetch_error(Reason) ->
    {error, #{
        <<"status">> => 502,
        <<"body">> => <<"Unable to submit AO withdrawal to AO endpoint.">>,
        <<"reason">> => format_reason(Reason)
    }}.

wallet_opts(NodeMsg) ->
    Wallet =
        case hb_opts:get(priv_wallet, not_found, NodeMsg) of
            not_found ->
                hb:wallet(hb_opts:get(priv_key_location, <<"hyperbeam-key.json">>, NodeMsg));
            FoundWallet ->
                FoundWallet
        end,
    Operator = hb_util:human_id(ar_wallet:to_address(Wallet)),
    NodeMsg#{
        priv_wallet => Wallet,
        <<"priv-wallet">> => Wallet,
        operator => Operator,
        <<"operator">> => Operator
    }.

with_payment_lock(Fun) ->
    global:trans({dev_process_ledger, ao_payment_ledger}, Fun, [node()], infinity).

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

payment_key(Payment, Opts) ->
    <<(hb_maps:get(<<"token">>, Payment, undefined, Opts))/binary, ":",
        (hb_maps:get(<<"ledger">>, Payment, undefined, Opts))/binary, ":",
        (hb_maps:get(<<"deposit-address">>, Payment, undefined, Opts))/binary, ":",
        (hb_maps:get(<<"message-id">>, Payment, undefined, Opts))/binary>>.

tag_value(Tags, Name, NodeMsg) ->
    case lists:search(
        fun(Tag) ->
            hb_maps:get(<<"name">>, Tag, undefined, NodeMsg) =:= Name
        end,
        Tags
    ) of
        {value, Tag} -> hb_maps:get(<<"value">>, Tag, undefined, NodeMsg);
        false -> undefined
    end.

-ifdef(TEST).
verify_result_requires_debit_and_credit_test() ->
    Expected = #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => undefined
    },
    Debit = #{
        <<"Target">> => <<"sender">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Debit-Notice">>},
            #{<<"name">> => <<"Recipient">>, <<"value">> => <<"node-address">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    Credit = #{
        <<"Target">> => <<"node-address">>,
        <<"Tags">> => [
            #{<<"name">> => <<"Action">>, <<"value">> => <<"Credit-Notice">>},
            #{<<"name">> => <<"Sender">>, <<"value">> => <<"sender">>},
            #{<<"name">> => <<"Quantity">>, <<"value">> => <<"1">>}
        ]
    },
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">>, <<"quantity">> := <<"1">> }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Debit, Credit]}}, Expected, #{})
    ),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_result(#{<<"raw">> => #{<<"Messages">> => [Credit]}}, Expected, #{})
    ).

verify_rejects_missing_required_fields_test() ->
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        verify(#{}, #{ <<"message-id">> => <<"message-id">> }, #{})
    ).

verify_schedule_matches_expected_transfer_test() ->
    Schedule = #{
        <<"edges">> => [
            #{
                <<"node">> => #{
                    <<"message">> => #{
                        <<"Id">> => <<"message-id">>,
                        <<"Tags">> => [
                            tag(<<"Action">>, <<"Transfer">>),
                            tag(<<"Recipient">>, <<"node-address">>),
                            tag(<<"Quantity">>, <<"1">>)
                        ]
                    },
                    <<"assignment">> => #{
                        <<"Tags">> => [tag(<<"Nonce">>, <<"7">>)]
                    }
                }
            }
        ]
    },
    Expected = #{
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"quantity">> => <<"1">>,
        <<"slot">> => <<"7">>
    },
    ?assertEqual(ok, verify_schedule(Schedule, Expected, #{})),
    ?assertMatch(
        {error, #{ <<"status">> := 402 }},
        verify_schedule(
            Schedule,
            Expected#{ <<"quantity">> => <<"2">> },
            #{}
        )
    ).

credit_to_payment_uses_sender_without_forwarded_recipient_test() ->
    Expected = payment_expected(undefined),
    Credit = credit_notice([]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"sender">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_respects_forwarded_recipient_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"local-recipient">>)]),
    ?assertMatch(
        {ok, #{ <<"recipient">> := <<"local-recipient">> }},
        credit_to_payment(Credit, Expected, #{})
    ).

credit_to_payment_rejects_requested_recipient_mismatch_test() ->
    Expected = payment_expected(<<"local-recipient">>),
    Credit = credit_notice([tag(<<"X-HB-Recipient">>, <<"other-recipient">>)]),
    ?assertMatch(
        {error, #{ <<"status">> := 400 }},
        credit_to_payment(Credit, Expected, #{})
    ).

withdraw_posts_legacy_mu_test_() ->
    {timeout, 30, fun() ->
        {ok, _} = application:ensure_all_started(hackney),
        ok = hb_http:start(),
        ok = hb_http_client:init_prometheus(),
        Token = hb_util:encode(crypto:strong_rand_bytes(32)),
        Recipient = hb_util:encode(crypto:strong_rand_bytes(32)),
        Store = hb_test_utils:test_store(),
        Wallet = ar_wallet:new(),
        Opts0 = #{
            store => Store,
            <<"store">> => Store,
            priv_wallet => Wallet,
            <<"priv-wallet">> => Wallet
        },
        {ok, SubmitURL, MockHandle} =
            hb_mock_server:start([
                {
                    "/",
                    submit,
                    {202, <<"{\"message\":\"Processing DataItem\"}">>}
                }
            ]),
        NodeMsg = Opts0,
        try
            {ok, Result} =
                submit_withdrawal(
                    #{
                        <<"token">> => Token,
                        <<"recipient">> => Recipient,
                        <<"quantity">> => 7,
                        <<"withdraw-id">> => <<"test-withdrawal">>,
                        <<"submit-url">> => SubmitURL
                    },
                    NodeMsg
                ),
            [Captured] = hb_mock_server:get_requests(submit, 1, MockHandle),
            Headers = hb_maps:get(<<"headers">>, Captured, #{}, #{}),
            ?assertEqual(
                <<"application/octet-stream">>,
                hb_maps:get(<<"content-type">>, Headers, undefined, #{})
            ),
            RawTX =
                ar_bundles:deserialize(
                    hb_maps:get(<<"body">>, Captured, undefined, #{})
                ),
            RawTags = RawTX#tx.tags,
            ?assert(lists:member({<<"Data-Protocol">>, <<"ao">>}, RawTags)),
            ?assert(lists:member({<<"Variant">>, <<"ao.TN.1">>}, RawTags)),
            ?assert(lists:member({<<"Type">>, <<"Message">>}, RawTags)),
            ?assert(lists:member({<<"Action">>, <<"Transfer">>}, RawTags)),
            ?assert(lists:member({<<"Recipient">>, Recipient}, RawTags)),
            ?assert(lists:member({<<"Quantity">>, <<"7">>}, RawTags)),
            Submitted =
                hb_message:convert(
                    ar_bundles:deserialize(
                        hb_maps:get(<<"body">>, Captured, undefined, #{})
                    ),
                    <<"structured@1.0">>,
                    <<"ans104@1.0">>,
                    NodeMsg
                ),
            ?assert(hb_message:verify(Submitted, all, NodeMsg)),
            ?assertEqual(Token, hb_maps:get(<<"target">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"ao">>, hb_maps:get(<<"data-protocol">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"ao.TN.1">>, hb_maps:get(<<"variant">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"Message">>, hb_maps:get(<<"type">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"Transfer">>, hb_maps:get(<<"action">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(Recipient, hb_maps:get(<<"recipient">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(<<"7">>, hb_maps:get(<<"quantity">>, Submitted, undefined, NodeMsg)),
            ?assertEqual(
                hb_message:id(Submitted, signed, NodeMsg),
                hb_maps:get(<<"message-id">>, Result, undefined, NodeMsg)
            )
        after
            hb_mock_server:stop(MockHandle)
        end
    end}.

payment_expected(RequestedRecipient) ->
    #{
        <<"token">> => <<"ao-token">>,
        <<"message-id">> => <<"message-id">>,
        <<"ledger">> => <<"ledger">>,
        <<"deposit-address">> => <<"node-address">>,
        <<"sender">> => <<"sender">>,
        <<"quantity">> => <<"1">>,
        <<"requested-recipient">> => RequestedRecipient
    }.

credit_notice(ExtraTags) ->
    #{
        <<"Tags">> => [
            tag(<<"Reference">>, <<"notice-reference">>)
            | ExtraTags
        ]
    }.

tag(Name, Value) ->
    #{ <<"name">> => Name, <<"value">> => Value }.
-endif.
