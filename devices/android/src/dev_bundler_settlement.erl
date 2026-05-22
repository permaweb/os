%%% @doc Completion hook for settling paid bundler uploads.
%%%
%%% P4 charges the uploader when the bundler POST succeeds. This hook runs after
%%% bundle completion, consumes the metered fee from the node's local ledger
%%% account, and optionally withdraws real AO to the beneficiary wallet.
-module(dev_bundler_settlement).
-export([info/1, bundled_message_complete/3, bundle_complete/3]).

-include_lib("hb/include/hb.hrl").

info(_) ->
    #{ exports => [<<"bundled-message-complete">>, <<"bundle-complete">>] }.

bundled_message_complete(Base, Req, Opts) ->
    settle(Base, Req, Opts).

bundle_complete(Base, Req, Opts) ->
    settle(Base, Req, Opts).

settle(Base, Req, Opts) ->
    Size = hb_util:int(hb_maps:get(<<"bundled-size">>, Req, 0, Opts)),
    case quote(Base, Size, Opts) of
        {ok, 0} ->
            {ok, Req};
        {ok, Amount} ->
            charge(Base, Req, Amount, Opts);
        Error ->
            Error
    end.

quote(Base, Size, Opts) ->
    PricingDevice =
        hb_maps:get(
            <<"pricing-device">>,
            Base,
            <<"arweave-byte-pricing@1.0">>,
            Opts
        ),
    hb_ao:resolve(
        Base#{ <<"device">> => PricingDevice },
        #{
            <<"path">> => <<"quote">>,
            <<"resource">> => <<"arweave-bytes">>,
            <<"amount">> => Size
        },
        Opts
    ).

charge(Base, Req, Amount, Opts) ->
    Account = account(Base, Opts),
    Recipient = recipient(Base, Opts),
    LedgerRecipient = ledger_recipient(Base, Recipient, Opts),
    LedgerDevice =
        hb_maps:get(
            <<"ledger-device">>,
            Base,
            <<"process-ledger@1.0">>,
            Opts
        ),
    ChargeReq =
        hb_message:commit(
            #{
                <<"path">> => <<"charge">>,
                <<"quantity">> => Amount,
                <<"account">> => Account,
                <<"recipient">> => LedgerRecipient,
                <<"request">> => Req
            },
            Opts
        ),
    case hb_ao:resolve(Base#{ <<"device">> => LedgerDevice }, ChargeReq, Opts) of
        {ok, _} -> withdraw_if_enabled(Base, Req, Amount, Recipient, Opts);
        Error -> Error
    end.

withdraw_if_enabled(Base, Req, Amount, Recipient, Opts) ->
    case enabled(hb_maps:get(<<"withdraw">>, Base, false, Opts)) of
        false ->
            {ok, Req};
        true ->
            AoPaymentDevice =
                hb_maps:get(
                    <<"withdraw-device">>,
                    Base,
                    <<"ao-payment@1.0">>,
                    Opts
                ),
            WithdrawReq0 = #{
                <<"path">> => <<"withdraw">>,
                <<"token">> => hb_maps:get(<<"withdraw-token">>, Base, undefined, Opts),
                <<"quantity">> => Amount,
                <<"recipient">> => Recipient,
                <<"withdraw-secret">> => withdraw_secret(Base, Opts),
                <<"withdraw-id">> => settlement_key(Req, Amount, Recipient, Opts),
                <<"request">> => Req
            },
            WithdrawReq =
                case hb_maps:get(<<"token">>, WithdrawReq0, undefined, Opts) of
                    undefined -> maps:remove(<<"token">>, WithdrawReq0);
                    _ -> WithdrawReq0
                end,
            case hb_ao:resolve(Base#{ <<"device">> => AoPaymentDevice }, WithdrawReq, Opts) of
                {ok, _} -> {ok, Req};
                Error -> Error
            end
    end.

withdraw_secret(Base, Opts) ->
    hb_private:get(
        <<"withdraw-secret">>,
        Base,
        hb_private:get(<<"ao-payment-withdraw-secret">>, Opts, undefined, Opts),
        Opts
    ).

account(Base, Opts) ->
    normalize_account(
        hb_maps:get(
            <<"settlement-account">>,
            Base,
            hb_opts:get(p4_recipient, hb_opts:get(operator, undefined, Opts), Opts),
            Opts
        )
    ).

recipient(Base, Opts) ->
    normalize_account(
        hb_maps:get(
            <<"beneficiary">>,
            Base,
            hb_opts:get(bundler_beneficiary, hb_opts:get(operator, undefined, Opts), Opts),
            Opts
        )
    ).

ledger_recipient(Base, Recipient, Opts) ->
    case enabled(hb_maps:get(<<"withdraw">>, Base, false, Opts)) of
        true ->
            normalize_account(
                hb_maps:get(
                    <<"withdrawal-account">>,
                    Base,
                    hb_maps:get(<<"withdraw-token">>, Base, Recipient, Opts),
                    Opts
                )
            );
        false ->
            Recipient
    end.

enabled(true) -> true;
enabled(<<"true">>) -> true;
enabled(1) -> true;
enabled(<<"1">>) -> true;
enabled(_) -> false.

settlement_key(Req, Amount, Recipient, Opts) ->
    BaseKey =
        try hb_message:id(Req, all, Opts)
        catch
            _:_ ->
                hb_util:encode(crypto:hash(sha256, term_to_binary(Req)))
        end,
    <<BaseKey/binary, ":", (hb_util:bin(Amount))/binary, ":", Recipient/binary>>.

normalize_account(Account) when ?IS_ID(Account) ->
    hb_util:human_id(Account);
normalize_account(Account) ->
    Account.
