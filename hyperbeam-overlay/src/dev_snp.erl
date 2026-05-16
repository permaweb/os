%%% @doc LapEE AMD SEV-SNP measurement engine.
%%%
%%% This device implements the `~measurement@1.0' engine protocol for
%%% SEV-SNP guests. The native boundary is intentionally small: the NIF is
%%% used to ask `/dev/sev-guest' for an attestation report and to perform the
%%% current upstream signature check. Message construction, report-data
%%% binding, policy-neutral checks, and secret wrapping live in Erlang.
%%%
%%% SNP has no TPM-style ActivateCredential primitive. The equivalent LapEE
%%% construction is to generate a boot-local X25519 recipient key inside the
%%% measured guest, bind that public key into SNP `report_data', and let peers
%%% encrypt admission material to it.
-module(dev_snp).
-export([info/1, info/3, supported/3, subject/3, measure/3, verify/3,
         wrap_secret/3, unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         ensure_secret_activation/5]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).
-define(REPORT_CONTEXT, <<"lapee-measurement-v1">>).
-define(METHOD, <<"snp-report-data-x25519-hkdf-sha256-aes-256-gcm">>).

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"supported">>,
            <<"subject">>,
            <<"measure">>,
            <<"verify">>,
            <<"wrap-secret">>,
            <<"unwrap-secret">>
        ]
    }.

info(_Base, _Req, Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"description">> =>
                <<"AMD SEV-SNP measurement engine for ~measurement@1.0">>,
            <<"version">> => ?VERSION,
            <<"supported">> => snp_supported(Opts)
        }
    }}.

supported(_Base, _Req, Opts) ->
    {ok, snp_supported(Opts)}.

subject(_Base, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => secret_recipient(Body, Opts)
    }}.

measure(_Base, Req, Opts) ->
    try
        Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
        Recipient = hb_maps:get(
            <<"secret-recipient">>, Req, secret_recipient(Body, Opts), Opts),
        Nonce = measurement_nonce(Req),
        ReportData = report_data(Body, Nonce, Recipient, Opts),
        case dev_snp_nif:generate_attestation_report(ReportData, vmpl(Opts)) of
            {ok, ReportJSON} ->
                Report = decode_report(ReportJSON),
                {ok, #{
                    <<"status">> => 200,
                    <<"body">> => evidence(ReportJSON, Report, Nonce,
                                             ReportData, Recipient, Opts)
                }};
            {error, Reason} ->
                error_resp(500, <<"snp-report-failed">>, Reason)
        end
    catch
        Class:CatchReason ->
            error_resp(500, <<"snp-measure-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(CatchReason)})
    end.

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    Body = hb_maps:get(<<"body">>, Measurement, #{}, Opts),
    Recipient = hb_maps:get(<<"secret-recipient">>, Measurement, #{}, Opts),
    Checks = [
        check_report_data(Body, Recipient, Evidence, Req, Opts),
        check_report_signature(Evidence)
    ],
    Verified = lists:all(
        fun(#{<<"ok">> := Ok, <<"severity">> := Severity}) ->
            Ok orelse Severity =:= <<"informational">>
        end,
        Checks),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"verified">> => Verified,
            <<"verdict">> =>
                case Verified of true -> <<"accepted">>; false -> <<"rejected">> end,
            <<"checks">> => Checks
        }
    }}.

wrap_secret(_Base, Req, Opts) ->
    Subject = hb_maps:get(<<"subject">>, Req, undefined, Opts),
    Secret = decode_secret(hb_maps:get(<<"secret">>, Req, <<>>, Opts)),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => wrap_secret_for_subject(Subject, Secret, Opts)
    }}.

unwrap_secret(_Base, Req, Opts) ->
    try
        {ok, Secret} = unwrap_secret_value(Req, Opts),
        Msg = hb_message:commit(
            secret_activation_public_body(Secret, Req),
            Opts),
        {ok, #{<<"status">> => 200, <<"body">> => Msg}}
    catch
        Class:CatchReason ->
            error_resp(500, <<"snp-unwrap-secret-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(CatchReason)})
    end.

snp_supported(_Opts) ->
    try dev_snp_nif:check_snp_support() of
        {ok, true} -> true;
        _ -> false
    catch _:_ ->
        false
    end.

secret_recipient(Body, Opts) ->
    {Public, _Private} = recipient_keypair(),
    BodyID = body_id(Body, Opts),
    Context = device_context(Opts),
    #{
        <<"type">> => <<"lapee-secret-recipient">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
        <<"method">> => ?METHOD,
        <<"key-id">> => hb_util:encode(crypto:hash(sha256, Public)),
        <<"public-material">> => #{
            <<"x25519-public-key">> => hb_util:encode(Public)
        },
        <<"binding">> => #{
            <<"report-data-context">> => ?REPORT_CONTEXT,
            <<"body-id">> => BodyID,
            <<"device-context">> => Context,
            <<"device-context-digest">> => device_context_digest(Context)
        }
    }.

recipient_keypair() ->
    case persistent_term:get({dev_snp, x25519_keypair}, undefined) of
        {Public, Private} ->
            {Public, Private};
        undefined ->
            {Public, Private} = crypto:generate_key(ecdh, x25519),
            persistent_term:put({dev_snp, x25519_keypair}, {Public, Private}),
            {Public, Private}
    end.

wrap_secret_for_subject(Subject, Secret, Opts) when is_map(Subject) ->
    PeerPublic = decode_required(
        <<"x25519-public-key">>,
        hb_maps:get(<<"public-material">>, Subject, #{}, Opts),
        Opts),
    {EphemeralPublic, EphemeralPrivate} = crypto:generate_key(ecdh, x25519),
    Shared = crypto:compute_key(ecdh, PeerPublic, EphemeralPrivate, x25519),
    Salt = crypto:strong_rand_bytes(32),
    IV = crypto:strong_rand_bytes(12),
    SubjectID = stable_id(Subject, Opts),
    Info = <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>,
    Key = hkdf_sha256(Shared, Salt, Info, 32),
    AAD = secret_aad(SubjectID),
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm, Key, IV, Secret, AAD, 16, true),
    #{
        <<"type">> => <<"lapee-wrapped-secret">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
        <<"method">> => ?METHOD,
        <<"subject-id">> => SubjectID,
        <<"ephemeral-public-key">> => hb_util:encode(EphemeralPublic),
        <<"salt">> => hb_util:encode(Salt),
        <<"iv">> => hb_util:encode(IV),
        <<"ciphertext">> => hb_util:encode(Ciphertext),
        <<"tag">> => hb_util:encode(Tag)
    }.

unwrap_secret_value(Credential, Opts) when is_map(Credential) ->
    {_Public, Private} = recipient_keypair(),
    PeerPublic = decode_required(<<"ephemeral-public-key">>, Credential, Opts),
    Shared = crypto:compute_key(ecdh, PeerPublic, Private, x25519),
    SubjectID = hb_maps:get(<<"subject-id">>, Credential, <<>>, Opts),
    Info = <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>,
    Key = hkdf_sha256(
        Shared,
        decode_required(<<"salt">>, Credential, Opts),
        Info,
        32),
    Plain =
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            Key,
            decode_required(<<"iv">>, Credential, Opts),
            decode_required(<<"ciphertext">>, Credential, Opts),
            secret_aad(SubjectID),
            decode_required(<<"tag">>, Credential, Opts),
            false),
    case Plain of
        error -> {error, decrypt_failed};
        B when is_binary(B) -> {ok, B}
    end.

ensure_secret_activation(Activation, Credential, Expected, _Subject, Opts) ->
    ExpectedHash = hb_util:encode(crypto:hash(sha256, Expected)),
    GotHash = hb_maps:get(
        <<"credential-secret-sha256">>, Activation, undefined, Opts),
    Proof = hb_maps:get(<<"credential-secret-proof">>, Activation, <<>>, Opts),
    IssuedAt = hb_maps:get(<<"issued-at-unix">>, Activation, 0, Opts),
    ExpectedProof = hb_util:encode(
        crypto:mac(
            hmac,
            sha256,
            Expected,
            secret_activation_context(Credential, IssuedAt))),
    case {GotHash, Proof} of
        {ExpectedHash, ExpectedProof} -> ok;
        _ ->
            throw({snp_error,
                   #{<<"secret-activation">> =>
                        <<"activation proof did not match challenge">>}})
    end.

evidence(ReportJSON, Report, Nonce, ReportData, Recipient, Opts) ->
    #{
        <<"type">> => <<"lapee-snp-evidence">>,
        <<"version">> => ?VERSION,
        <<"nonce">> => hb_util:encode(Nonce),
        <<"report-data">> => hb_util:encode(ReportData),
        <<"report-json">> => ReportJSON,
        <<"report">> => parsed_report_summary(Report),
        <<"secret-recipient-id">> => stable_id(Recipient, Opts),
        <<"device-context">> => device_context(Opts),
        <<"signature-check">> => report_signature_check(ReportJSON)
    }.

parsed_report_summary(Report) ->
    #{
        <<"version">> => hb_maps:get(<<"version">>, Report, null, #{}),
        <<"guest-svn">> => hb_maps:get(<<"guest_svn">>, Report, null, #{}),
        <<"policy">> => hb_maps:get(<<"policy">>, Report, null, #{}),
        <<"family-id">> => encode_array_field(<<"family_id">>, Report),
        <<"image-id">> => encode_array_field(<<"image_id">>, Report),
        <<"vmpl">> => hb_maps:get(<<"vmpl">>, Report, null, #{}),
        <<"signature-algorithm">> =>
            hb_maps:get(<<"sig_algo">>, Report, null, #{}),
        <<"platform-info">> => hb_maps:get(<<"plat_info">>, Report, null, #{}),
        <<"measurement">> => encode_array_field(<<"measurement">>, Report),
        <<"reported-tcb">> =>
            hb_maps:get(<<"reported_tcb">>, Report, null, #{}),
        <<"committed-tcb">> =>
            hb_maps:get(<<"committed_tcb">>, Report, null, #{}),
        <<"launch-tcb">> =>
            hb_maps:get(<<"launch_tcb">>, Report, null, #{}),
        <<"chip-id">> => encode_array_field(<<"chip_id">>, Report),
        <<"report-id">> => encode_array_field(<<"report_id">>, Report),
        <<"report-id-ma">> => encode_array_field(<<"report_id_ma">>, Report)
    }.

check_report_data(Body, Recipient, Evidence, Req, Opts) ->
    safely_check(
        <<"SNP report_data binds body, nonce, and secret recipient">>,
        <<"core">>,
        fun() ->
            Nonce = decode_required(<<"nonce">>, Evidence, Opts),
            case expected_nonce(Req) of
                undefined -> ok;
                Nonce -> ok;
                _ -> throw(<<"fresh nonce does not match verifier challenge">>)
            end,
            Expected = report_data(Body, Nonce, Recipient, Opts),
            Got = decode_required(<<"report-data">>, Evidence, Opts),
            Report = decode_report(
                hb_maps:get(<<"report-json">>, Evidence, <<>>, Opts)),
            ReportData = array_binary(
                hb_maps:get(<<"report_data">>, Report, [], #{})),
            case {Got, ReportData} of
                {Expected, Expected} -> ok;
                _ -> throw(<<"report_data mismatch">>)
            end
        end).

check_report_signature(Evidence) ->
    SignatureCheck = hb_maps:get(
        <<"signature-check">>, Evidence, #{<<"verified">> => false}, #{}),
    safely_check(
        <<"SNP report signature and endorsement chain verify">>,
        <<"core">>,
        fun() ->
            case hb_maps:get(<<"verified">>, SignatureCheck, false, #{}) of
                true -> ok;
                false -> throw(SignatureCheck)
            end
        end).

report_signature_check(ReportJSON) ->
    try dev_snp_nif:verify_signature(ReportJSON) of
        {ok, true} -> #{<<"verified">> => true, <<"source">> => <<"nif">>};
        {ok, false} -> #{<<"verified">> => false, <<"source">> => <<"nif">>};
        {error, Reason} ->
            #{<<"verified">> => false,
              <<"source">> => <<"nif">>,
              <<"reason">> => reason_to_text(Reason)}
    catch
        Class:CatchReason ->
            #{<<"verified">> => false,
              <<"source">> => <<"nif">>,
              <<"reason">> =>
                  iolist_to_binary(
                      io_lib:format("~p:~0p", [Class, CatchReason]))}
    end.

report_data(Body, Nonce, Recipient, Opts) ->
    BodyID = body_id(Body, Opts),
    RecipientID = stable_id(Recipient, Opts),
    ContextDigest = device_context_digest(device_context(Opts)),
    crypto:hash(
        sha512,
        <<?REPORT_CONTEXT/binary,
          (hb_util:native_id(BodyID))/binary,
          Nonce/binary,
          (hb_util:native_id(RecipientID))/binary,
          (hb_util:decode(ContextDigest))/binary>>).

body_id(Body, Opts) when is_map(Body) ->
    stable_id(Body, Opts);
body_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

device_context(Opts) ->
    #{
        <<"vmpl">> => vmpl(Opts),
        <<"report-data-context">> => ?REPORT_CONTEXT,
        <<"secret-method">> => ?METHOD
    }.

device_context_digest(Context) ->
    hb_util:encode(
        crypto:hash(sha256, term_to_binary(hb_message:uncommitted(Context, #{})))).

vmpl(Opts) ->
    parse_integer(
        first_defined([
            hb_opts:get(<<"snp-vmpl">>, undefined, Opts),
            hb_opts:get(snp_vmpl, undefined, Opts)
        ]),
        1).

measurement_nonce(Req) ->
    case expected_nonce(Req) of
        undefined -> crypto:strong_rand_bytes(32);
        Nonce -> Nonce
    end.

expected_nonce(Req) ->
    case hb_maps:get(<<"nonce">>, Req, undefined, #{}) of
        undefined -> undefined;
        B when is_binary(B) ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ -> undefined
    end.

secret_activation_public_body(Secret, Credential) ->
    Now = erlang:system_time(second),
    #{
        <<"type">> => <<"lapee-secret-activation">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
        <<"method">> => ?METHOD,
        <<"issued-at-unix">> => Now,
        <<"credential-secret-sha256">> =>
            hb_util:encode(crypto:hash(sha256, Secret)),
        <<"proof-alg">> => <<"HMAC-SHA256">>,
        <<"credential-secret-proof">> =>
            hb_util:encode(
                crypto:mac(
                    hmac,
                    sha256,
                    Secret,
                    secret_activation_context(Credential, Now)))
    }.

secret_activation_context(Credential, IssuedAt) ->
    <<"lapee-secret-activation-v1\n",
      "measurement-device:snp@1.0\n",
      "method:", ?METHOD/binary, "\n",
      "issued-at-unix:", (integer_to_binary(IssuedAt))/binary, "\n",
      "credential-id:", (stable_id(Credential, #{}))/binary>>.

secret_aad(SubjectID) ->
    <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>.

hkdf_sha256(IKM, Salt, Info, Length) ->
    PRK = crypto:mac(hmac, sha256, Salt, IKM),
    hkdf_expand(PRK, Info, Length, <<>>, <<>>, 1).

hkdf_expand(_PRK, _Info, Length, Acc, _Prev, _N)
        when byte_size(Acc) >= Length ->
    binary:part(Acc, 0, Length);
hkdf_expand(PRK, Info, Length, Acc, Prev, N) ->
    Block = crypto:mac(hmac, sha256, PRK, <<Prev/binary, Info/binary, N>>),
    hkdf_expand(PRK, Info, Length, <<Acc/binary, Block/binary>>, Block, N + 1).

decode_report(ReportJSON) when is_binary(ReportJSON) ->
    hb_json:decode(ReportJSON);
decode_report(Report) when is_map(Report) ->
    Report.

encode_array_field(Key, Report) ->
    hb_util:encode(array_binary(hb_maps:get(Key, Report, [], #{}))).

array_binary(L) when is_list(L) ->
    iolist_to_binary([<<N:8>> || N <- L, is_integer(N), N >= 0, N =< 255]);
array_binary(B) when is_binary(B) ->
    B;
array_binary(_) ->
    <<>>.

decode_required(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ ->
            throw(<<Key/binary, " missing">>)
    end.

decode_secret(B) when is_binary(B) ->
    try hb_util:decode(B)
    catch _:_ -> B
    end;
decode_secret(_) ->
    throw(<<"secret must be binary/base64url">>).

stable_id(Msg, Opts) when is_map(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(canonical_payload(Msg, Opts), Opts),
        uncommitted,
        Opts);
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
canonical_payload(Value, _Opts) ->
    Value.

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body({ok, Msg}, Opts) ->
    response_body(Msg, Opts);
response_body({error, Reason}, _Opts) ->
    throw(Reason);
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
        _ ->
            case hb_maps:get(<<"body">>, Base, undefined, Opts) of
                Inner when is_map(Inner) -> Inner;
                _ -> Base
            end
    end;
resolve_envelope(_Base, Req, Opts) ->
    hb_maps:get(<<"envelope">>, Req, #{}, Opts).

safely_check(Name, Severity, Fun) ->
    try Fun() of
        ok ->
            #{<<"name">> => Name,
              <<"ok">> => true,
              <<"detail">> => <<"ok">>,
              <<"severity">> => Severity}
    catch
        _:Reason ->
            #{<<"name">> => Name,
              <<"ok">> => false,
              <<"detail">> => reason_to_text(Reason),
              <<"severity">> => Severity}
    end.

parse_integer(N, _Default) when is_integer(N) -> N;
parse_integer(B, Default) when is_binary(B) ->
    try binary_to_integer(B)
    catch _:_ -> Default
    end;
parse_integer(_, Default) ->
    Default.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

error_resp(Status, Err, Reason) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => #{
            <<"error">> => Err,
            <<"reason">> => reason_to_text(Reason)
        }
    }}.

reason_to_text(B) when is_binary(B) -> B;
reason_to_text(M) when is_map(M) -> M;
reason_to_text(A) when is_atom(A) -> atom_to_binary(A, utf8);
reason_to_text(T) -> iolist_to_binary(io_lib:format("~0p", [T])).

hkdf_roundtrip_test() ->
    Subject = secret_recipient(#{}, #{}),
    Secret = crypto:strong_rand_bytes(32),
    Credential = wrap_secret_for_subject(Subject, Secret, #{}),
    {ok, Secret} = unwrap_secret_value(Credential, #{}).

snp_verify_accepts_bound_report_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Measurement = test_measurement(Body, Recipient, Nonce, #{}),
    ?assertMatch(
        {ok, #{<<"status">> := 200,
               <<"body">> := #{<<"verified">> := true}}},
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(Nonce)},
            #{})).

snp_verify_rejects_wrong_nonce_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Measurement =
        test_measurement(Body, Recipient, crypto:strong_rand_bytes(32), #{}),
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(crypto:strong_rand_bytes(32))},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_wrong_body_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Measurement =
        (test_measurement(Body, Recipient, Nonce, #{}))#{
            <<"body">> => #{<<"system">> => #{<<"tampered">> => true}}
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(Nonce)},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_bad_signature_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Evidence =
        (test_evidence(Body, Recipient, Nonce, #{}))#{
            <<"signature-check">> => #{<<"verified">> => false}
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> =>
                #{<<"type">> => <<"lapee-measurement">>,
                  <<"body">> => Body,
                  <<"evidence">> => Evidence,
                  <<"secret-recipient">> => Recipient},
              <<"nonce">> => hb_util:encode(Nonce)},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_malformed_report_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Evidence =
        (test_evidence(Body, Recipient, Nonce, #{}))#{
            <<"report-json">> => <<"not-json">>
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> =>
                #{<<"type">> => <<"lapee-measurement">>,
                  <<"body">> => Body,
                  <<"evidence">> => Evidence,
                  <<"secret-recipient">> => Recipient},
              <<"nonce">> => hb_util:encode(Nonce)},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

test_measurement(Body, Recipient, Nonce, Opts) ->
    #{
        <<"type">> => <<"lapee-measurement">>,
        <<"body">> => Body,
        <<"evidence">> => test_evidence(Body, Recipient, Nonce, Opts),
        <<"secret-recipient">> => Recipient
    }.

test_evidence(Body, Recipient, Nonce, Opts) ->
    ReportData = report_data(Body, Nonce, Recipient, Opts),
    #{
        <<"nonce">> => hb_util:encode(Nonce),
        <<"report-data">> => hb_util:encode(ReportData),
        <<"report-json">> => #{<<"report_data">> => binary_to_list(ReportData)},
        <<"signature-check">> => #{<<"verified">> => true}
    }.

test_body() ->
    #{
        <<"system">> => #{<<"kernel">> => <<"test">>},
        <<"node">> => #{<<"address">> => <<"test-node">>}
    }.
