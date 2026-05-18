%%% @doc Test-only SNP-shaped measurement engine.
%%%
%%% This module is not preloaded by the production LapEE config and is not an
%%% `auto' candidate. QEMU harnesses can explicitly preload/select it to prove
%%% that green-zone depends on `~measurement@1.0' rather than TPM-specific
%%% MakeCredential details.
-module(dev_snp_mock).
-export([info/1, info/3, supported/3, subject/3, measure/3, verify/3,
         wrap_secret/3, unwrap_secret/3]).
-export([unwrap_secret_value/2, ensure_secret_activation/5]).

-include("include/hb.hrl").

info(_) ->
    #{exports => [
        <<"info">>,
        <<"supported">>,
        <<"subject">>,
        <<"measure">>,
        <<"verify">>,
        <<"wrap-secret">>,
        <<"unwrap-secret">>
    ]}.

info(_Base, _Req, _Opts) ->
    {ok, #{<<"status">> => 200,
           <<"body">> => #{<<"supported">> => true,
                            <<"description">> =>
                                <<"test-only SNP measurement mock">>}}}.

supported(_Base, _Req, _Opts) ->
    {ok, true}.

subject(Base, Req, Opts) ->
    {ok, #{<<"status">> := 200, <<"body">> := Body}} =
        dev_snp:subject(Base, Req, Opts),
    {ok, #{<<"status">> => 200,
           <<"body">> => rewrite_device(Body, <<"snp-mock@1.0">>)}}.

measure(_Base, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
    Recipient = hb_maps:get(<<"secret-recipient">>, Req, #{}, Opts),
    Nonce = nonce(Req, Opts),
    Digest = mock_report_data(Body, Nonce, Recipient, Opts),
    {ok, #{<<"status">> => 200,
           <<"body">> => #{
                <<"type">> => <<"lapee-snp-mock-evidence">>,
                <<"version">> => <<"1.0">>,
                <<"nonce">> => hb_util:encode(Nonce),
                <<"report-data">> => hb_util:encode(Digest),
                <<"mock">> => true
           }}}.

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
    Body = hb_maps:get(<<"body">>, Measurement, #{}, Opts),
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    Recipient = hb_maps:get(<<"secret-recipient">>, Measurement, #{}, Opts),
    Nonce = decode(hb_maps:get(<<"nonce">>, Evidence, <<>>, Opts)),
    Expected = hb_util:encode(mock_report_data(Body, Nonce, Recipient, Opts)),
    Got = hb_maps:get(<<"report-data">>, Evidence, <<>>, Opts),
    NonceOK =
        case hb_maps:get(<<"nonce">>, Req, undefined, Opts) of
            undefined -> true;
            B -> decode(B) =:= Nonce
        end,
    Verified = NonceOK andalso Got =:= Expected,
    {ok, #{<<"status">> => 200,
           <<"body">> => #{
                <<"verified">> => Verified,
                <<"verdict">> =>
                    case Verified of
                        true -> <<"accepted">>;
                        false -> <<"rejected">>
                    end,
                <<"checks">> => [
                    #{<<"name">> => <<"mock report-data binding">>,
                      <<"ok">> => Verified,
                      <<"severity">> => <<"core">>}
                ]
           }}}.

wrap_secret(_Base, Req, Opts) ->
    Subject = rewrite_device(
        hb_maps:get(<<"subject">>, Req, #{}, Opts),
        <<"snp@1.0">>),
    Secret = decode(hb_maps:get(<<"secret">>, Req, <<>>, Opts)),
    {ok, #{<<"status">> => 200,
           <<"body">> =>
                rewrite_device(
                    dev_snp:wrap_secret_for_subject(Subject, Secret, Opts),
                    <<"snp-mock@1.0">>)}}.

unwrap_secret(_Base, Req, Opts) ->
    Credential = rewrite_device(Req, <<"snp@1.0">>),
    case dev_snp:unwrap_secret(#{}, Credential, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            {ok, #{<<"status">> => 200,
                   <<"body">> => rewrite_device(Body, <<"snp-mock@1.0">>)}};
        Other ->
            Other
    end.

unwrap_secret_value(Credential, Opts) ->
    dev_snp:unwrap_secret_value(rewrite_device(Credential, <<"snp@1.0">>), Opts).

ensure_secret_activation(Activation, Credential, Expected, Subject, Opts) ->
    ExpectedHash = hb_util:encode(crypto:hash(sha256, Expected)),
    case hb_maps:get(
            <<"credential-secret-sha256">>,
            rewrite_device(Activation, <<"snp@1.0">>),
            undefined,
            Opts) of
        ExpectedHash -> ok;
        _ ->
            throw({snp_mock_error,
                   #{<<"secret-activation">> =>
                        <<"activation secret did not match challenge">>,
                     <<"credential">> =>
                        stable_id(Credential, Opts),
                     <<"subject">> =>
                        stable_id(Subject, Opts)}})
    end.

mock_report_data(Body, Nonce, Recipient, Opts) ->
    crypto:hash(
        sha512,
        <<"lapee-snp-mock-v1",
          (hb_util:native_id(stable_id(Body, Opts)))/binary,
          Nonce/binary,
          (hb_util:native_id(stable_id(Recipient, Opts)))/binary>>).

stable_id(Msg, Opts) when is_map(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(canonical_payload(Msg, Opts), Opts),
        uncommitted,
        Opts);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
stable_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
stable_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

canonical_payload(Link, Opts) when ?IS_LINK(Link) ->
    canonical_payload(response_body(Link, Opts), Opts);
canonical_payload(Msg, Opts) when is_map(Msg) ->
    Loaded = hb_cache:ensure_all_loaded(hb_link:decode_all_links(Msg), Opts),
    maps:from_list(
        [
            {Key, canonical_payload(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Loaded, Opts),
            Key =/= <<"commitments">>,
            Key =/= <<"ao-types">>
        ]);
canonical_payload(List, Opts) when is_list(List) ->
    [canonical_payload(Value, Opts) || Value <- List];
canonical_payload(Value, _Opts) when is_atom(Value) ->
    hb_util:bin(Value);
canonical_payload(Value, _Opts) ->
    Value.

nonce(Req, Opts) ->
    case hb_maps:get(<<"nonce">>, Req, undefined, Opts) of
        undefined -> crypto:strong_rand_bytes(32);
        B when is_binary(B) -> decode(B);
        _ -> crypto:strong_rand_bytes(32)
    end.

decode(B) when is_binary(B) ->
    try hb_util:decode(B)
    catch _:_ -> B
    end;
decode(_) ->
    <<>>.

rewrite_device(Msg, Device) when is_map(Msg) ->
    Msg#{<<"measurement-device">> => Device};
rewrite_device(Other, _Device) ->
    Other.

response_body({ok, Msg}, Opts) ->
    response_body(Msg, Opts);
response_body(#{<<"status">> := _Status, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
response_body(#{<<"body">> := Body} = Msg, Opts) ->
    case hb_maps:get(<<"type">>, Msg, undefined, Opts) of
        <<"lapee-measurement">> -> Msg;
        _ -> response_body(Body, Opts)
    end;
response_body(Body, _Opts) ->
    Body.

resolve_envelope(Base, Req, Opts) when is_map(Base) ->
    case hb_maps:get(<<"envelope">>, Req, undefined, Opts) of
        E when is_map(E) -> E;
        _ -> Base
    end;
resolve_envelope(_Base, Req, Opts) ->
    hb_maps:get(<<"envelope">>, Req, #{}, Opts).
