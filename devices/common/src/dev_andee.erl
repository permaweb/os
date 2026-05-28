%%% @doc Android Keystore/StrongBox measurement backend for AndEE.
%%%
%%% This module implements the backend contract consumed by
%%% `~measurement@1.0'. It keeps all public evidence and secret-recipient
%%% values as AO-Core-shaped messages. Local generation and secret unwrapping
%%% use the app-private `AndeeCryptoAgent' Unix-domain socket; verification is
%%% pure BEAM so Linux/SNP/TPM nodes can validate AndEE peers.
-module(dev_andee).
-implements(<<"andee@1.0">>).
-export([info/1, info/3, supported/3, subject/3, measure/3, verify/3,
         wrap_secret/3, unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         ensure_secret_activation/5]).

-include_lib("hb/include/hb.hrl").
-include_lib("public_key/include/public_key.hrl").

-define(VERSION, <<"1.0">>).
-define(METHOD, <<"android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm">>).
-define(EVIDENCE_CONTEXT, <<"andee-android-evidence-v1">>).
-define(DEFAULT_SOCKET, <<"org.permaweb.andee.crypto">>).
-define(DEFAULT_TIMEOUT_MS, 5000).
-define(ANDROID_ATTESTATION_OID, {1, 3, 6, 1, 4, 1, 11129, 2, 1, 17}).
-define(ROOTS_PEM, "android-attestation-roots.pem").
-define(DER_UNIVERSAL, 16#00).
-define(DER_CONTEXT_SPECIFIC, 16#80).
-define(DER_SEQUENCE, 16).
-define(DER_SET, 17).
-define(DER_INTEGER, 2).
-define(DER_BOOLEAN, 1).
-define(DER_ENUMERATED, 10).
-define(DER_OCTET_STRING, 4).
-define(ROOT_OF_TRUST_TAG, 704).
-define(OS_PATCH_LEVEL_TAG, 706).
-define(ATTESTATION_APPLICATION_ID_TAG, 709).
-define(VENDOR_PATCH_LEVEL_TAG, 718).
-define(BOOT_PATCH_LEVEL_TAG, 719).

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
            <<"version">> => ?VERSION,
            <<"measurement-device">> => <<"andee@1.0">>,
            <<"method">> => ?METHOD,
            <<"supported">> => andee_supported(Opts),
            <<"policy-accepted">> => andee_policy_accepted(Opts)
        }
    }}.

supported(_Base, _Req, Opts) ->
    {ok, andee_supported(Opts)}.

subject(_Base, Req, Opts) ->
    case internal_measurement_request(Req, Opts) of
        false ->
            error_resp(403, <<"measurement-engine-internal-only">>,
                       <<"Use ~measurement@1.0 for AndEE measurement generation.">>);
        true ->
            case andee_supported(Opts) of
                true ->
                    Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
                    {ok, #{
                        <<"status">> => 200,
                        <<"body">> => secret_recipient(Body, Opts)
                    }};
                false ->
                    error_resp(503, <<"andee-unsupported">>,
                               <<"Android AndEE crypto agent is unavailable">>)
            end
    end.

measure(_Base, Req, Opts) ->
    case internal_measurement_request(Req, Opts) of
        false ->
            error_resp(403, <<"measurement-engine-internal-only">>,
                       <<"Use ~measurement@1.0 for AndEE measurement generation.">>);
        true ->
            case andee_supported(Opts) of
                false ->
                    error_resp(503, <<"andee-unsupported">>,
                               <<"Android AndEE crypto agent is unavailable">>);
                true ->
                    try
                        Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
                        Recipient = hb_maps:get(
                            <<"secret-recipient">>,
                            Req,
                            secret_recipient(Body, Opts),
                            Opts),
                        Nonce = measurement_nonce(Req, Opts),
                        Purpose = hb_maps:get(<<"purpose">>, Req, <<"fresh">>, Opts),
                        {EvidenceSubject, EvidenceSubjectID} =
                            evidence_subject(Body, Recipient, Nonce, Purpose, Opts),
                        Agent = require_agent(
                            <<"sign-evidence">>,
                            #{
                                <<"evidence-subject">> => EvidenceSubject,
                                <<"evidence-subject-id">> => EvidenceSubjectID
                            },
                            Opts),
                        {ok, #{
                            <<"status">> => 200,
                            <<"body">> =>
                                evidence(
                                    EvidenceSubject,
                                    EvidenceSubjectID,
                                    Agent,
                                    Opts)
                        }}
                    catch
                        throw:{andee_policy_error, Reason} ->
                            {ok, #{
                                <<"status">> => 200,
                                <<"body">> => policy_failure_evidence(Reason, Req, Opts)
                            }};
                        Class:Reason ->
                            error_resp(500, <<"andee-measure-failed">>,
                                       #{<<"class">> => hb_util:bin(Class),
                                         <<"reason">> => reason_to_text(Reason)})
                    end
            end
    end.

internal_measurement_request(Req, Opts) ->
    case persistent_term:get(
        {permawebos_measurement, internal_request_token},
        undefined) of
        undefined ->
            false;
        Token ->
            is_map(Req) andalso
                hb_maps:get(
                    <<"measurement-internal-token">>,
                    Req,
                    undefined,
                    Opts) =:= Token
    end.

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    Facts = attestation_facts(Evidence, Opts),
    Checks0 = [
        check_measurement_shape(Measurement, Opts),
        check_measurement_device(Measurement, Opts),
        check_evidence_shape(Evidence, Opts),
        check_evidence_subject(Measurement, Evidence, Req, Opts)
    ],
    Checks = Checks0 ++ [
        check_certificate_chain_present(Evidence, Opts),
        check_certificate_chain_parses(Evidence, Opts),
        check_certificate_chain_signatures(Evidence, Opts),
        check_certificate_root_trusted(Evidence, Opts),
        check_android_attestation_extension(Facts),
        check_reported_attestation_facts(Evidence, Facts, Opts),
        check_attestation_challenge(Evidence, Facts, Opts),
        check_reported_security_level(Evidence, Facts, Opts),
        check_keystore_signature(Evidence, Opts),
        informational_check(
            <<"Android attestation facts">>, public_attestation_facts(Facts)),
        informational_check(
            <<"Android local policy snapshot">>,
            hb_maps:get(<<"policy-snapshot">>, Evidence, #{}, Opts))
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
            <<"checks">> => Checks,
            <<"facts">> => public_attestation_facts(Facts)
        }
    }}.

wrap_secret(_Base, Req, Opts) ->
    Subject = hb_maps:get(<<"subject">>, Req, #{}, Opts),
    Secret = decode_required(<<"secret">>, Req, Opts),
    {ok, #{<<"status">> => 200,
           <<"body">> => wrap_secret_for_subject(Subject, Secret, Opts)}}.

unwrap_secret(_Base, Req, Opts) ->
    try
        Credential = activation_credential(Req, Opts),
        {ok, Secret} = unwrap_secret_value(Credential, Opts),
        Msg = hb_message:commit(
            secret_activation_public_body(Secret, Credential, Opts),
            Opts),
        {ok, #{<<"status">> => 200, <<"body">> => Msg}}
    catch
        Class:Reason ->
            error_resp(500, <<"andee-unwrap-secret-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(Reason)})
    end.

andee_supported(Opts) ->
    case configured_agent_socket(Opts) of
        undefined ->
            false;
        _ ->
            agent_available(Opts)
    end.

agent_available(Opts) ->
    case agent_request(<<"policy-status">>, #{}, Opts) of
        {ok, _Body} -> true;
        _ -> false
    end.

andee_policy_accepted(Opts) ->
    case configured_agent_socket(Opts) of
        undefined ->
            false;
        _ ->
            case agent_request(<<"policy-status">>, #{}, Opts) of
                {ok, #{<<"accepted">> := true}} -> true;
                _ -> false
            end
    end.

secret_recipient(Body, Opts) ->
    {Public, _Private} = recipient_keypair(),
    BodyID = stable_id(Body, Opts),
    Binding0 = #{
        <<"evidence-context">> => ?EVIDENCE_CONTEXT,
        <<"body-id">> => BodyID,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"method">> => ?METHOD
    },
    BindingID = stable_id(Binding0, Opts),
    Recipient0 = #{
        <<"type">> => <<"lapee-secret-recipient">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"method">> => ?METHOD,
        <<"key-id">> => hb_util:encode(crypto:hash(sha256, Public)),
        <<"public-material">> => #{
            <<"x25519-public-key">> => hb_util:encode(Public)
        },
        <<"binding">> => Binding0#{
            <<"binding-id">> => BindingID
        }
    },
    Recipient0#{<<"subject-id">> => stable_id(Recipient0, Opts)}.

recipient_keypair() ->
    case persistent_term:get({dev_andee, x25519_keypair}, undefined) of
        {Public, Private} ->
            {Public, Private};
        undefined ->
            {Public, Private} = crypto:generate_key(ecdh, x25519),
            persistent_term:put({dev_andee, x25519_keypair}, {Public, Private}),
            {Public, Private}
    end.

evidence_subject(Body, Recipient, Nonce, Purpose, Opts) ->
    Now = erlang:system_time(second),
    BodyID = payload_id(Body, Opts),
    RecipientID = secret_recipient_id(Recipient, Opts),
    Subject0 = #{
        <<"type">> => <<"andee-evidence-subject">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"context">> => ?EVIDENCE_CONTEXT,
        <<"method">> => ?METHOD,
        <<"purpose">> => Purpose,
        <<"nonce">> => hb_util:encode(Nonce),
        <<"issued-at-unix">> => Now,
        <<"body-id">> => BodyID,
        <<"secret-recipient-id">> => RecipientID
    },
    Subject = canonical_payload(Subject0, Opts),
    {Subject, stable_id(Subject, Opts)}.

evidence(EvidenceSubject, EvidenceSubjectID, Agent, Opts) ->
    Policy = hb_maps:get(<<"policy-snapshot">>, Agent, #{}, Opts),
    Evidence0 = #{
        <<"type">> => <<"andee-android-evidence">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"method">> => ?METHOD,
        <<"evidence-subject">> => EvidenceSubject,
        <<"evidence-subject-id">> => EvidenceSubjectID,
        <<"android-attestation-cert-chain">> =>
            hb_maps:get(<<"android-attestation-cert-chain">>, Agent, [], Opts),
        <<"keystore-signature">> =>
            hb_maps:get(<<"keystore-signature">>, Agent, <<>>, Opts),
        <<"attestation-challenge-subject">> =>
            hb_maps:get(<<"attestation-challenge-subject">>,
                        Agent,
                        EvidenceSubjectID,
                        Opts),
        <<"policy-snapshot">> => Policy,
        <<"key-security-level">> =>
            hb_maps:get(<<"key-security-level">>, Agent, <<"unknown">>, Opts),
        <<"accepted">> => hb_maps:get(<<"accepted">>, Agent, false, Opts),
        <<"verdict">> =>
            hb_maps:get(<<"verdict">>, Agent, <<"policy-failure">>, Opts)
    },
    Evidence0#{
        <<"android-attestation-facts">> =>
            public_attestation_facts(attestation_facts(Evidence0, Opts))
    }.

policy_failure_evidence(Reason, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
    Nonce = measurement_nonce(Req, Opts),
    Purpose = hb_maps:get(<<"purpose">>, Req, <<"fresh">>, Opts),
    {Subject, SubjectID} =
        evidence_subject(Body, #{}, Nonce, Purpose, Opts),
    #{
        <<"type">> => <<"andee-android-evidence">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"method">> => ?METHOD,
        <<"evidence-subject">> => Subject,
        <<"evidence-subject-id">> => SubjectID,
        <<"accepted">> => false,
        <<"verdict">> => <<"policy-failure">>,
        <<"policy-snapshot">> => #{
            <<"accepted">> => false,
            <<"reason">> => reason_to_text(Reason)
        }
    }.

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
    Info = <<"andee-wrap-secret-v1:", SubjectID/binary>>,
    Key = hkdf_sha256(Shared, Salt, Info, 32),
    AAD = secret_aad(SubjectID),
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm, Key, IV, Secret, AAD, 16, true),
    #{
        <<"type">> => <<"lapee-wrapped-secret">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
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
    Info = <<"andee-wrap-secret-v1:", SubjectID/binary>>,
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
            secret_activation_context(Credential, IssuedAt, Opts))),
    case {GotHash, Proof} of
        {ExpectedHash, ExpectedProof} -> ok;
        _ ->
            throw({andee_error,
                   #{<<"secret-activation">> =>
                        <<"activation proof did not match challenge">>}})
    end.

secret_activation_public_body(Secret, Credential, Opts) ->
    Now = erlang:system_time(second),
    #{
        <<"type">> => <<"lapee-secret-activation">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"andee@1.0">>,
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
                    secret_activation_context(Credential, Now, Opts)))
    }.

secret_activation_context(Credential, IssuedAt, Opts) ->
    <<"lapee-secret-activation-v1\n",
      "measurement-device:andee@1.0\n",
      "method:", ?METHOD/binary, "\n",
      "issued-at-unix:", (integer_to_binary(IssuedAt))/binary, "\n",
      "credential-id:", (wrapped_secret_id(Credential, Opts))/binary>>.

wrapped_secret_id(Credential, Opts) when is_map(Credential) ->
    stable_id(
        maps:from_list(
            [
                {Key, Value}
             || Key <- wrapped_secret_identity_keys(),
                (Value = hb_maps:get(Key, Credential, undefined, Opts))
                    =/= undefined
            ]),
        Opts);
wrapped_secret_id(Credential, Opts) ->
    stable_id(Credential, Opts).

wrapped_secret_identity_keys() ->
    [
        <<"type">>,
        <<"version">>,
        <<"measurement-device">>,
        <<"method">>,
        <<"subject-id">>,
        <<"ephemeral-public-key">>,
        <<"salt">>,
        <<"iv">>,
        <<"ciphertext">>,
        <<"tag">>
    ].

check_measurement_device(Measurement, Opts) ->
    safely_check(
        <<"measurement device is andee@1.0">>,
        <<"core">>,
        fun() ->
            case hb_maps:get(<<"measurement-device">>, Measurement, undefined, Opts) of
                <<"andee@1.0">> -> ok;
                Other -> throw(#{<<"measurement-device">> => Other})
            end
        end).

check_evidence_subject(Measurement, Evidence, Req, Opts) ->
    safely_check(
        <<"Keystore signature subject binds body, nonce, and recipient">>,
        <<"core">>,
        fun() ->
            Body = hb_maps:get(<<"body">>, Measurement, #{}, Opts),
            Recipient = hb_maps:get(<<"secret-recipient">>, Measurement, #{}, Opts),
            Subject = hb_maps:get(<<"evidence-subject">>, Evidence, #{}, Opts),
            SubjectID = hb_maps:get(<<"evidence-subject-id">>, Evidence, <<>>, Opts),
            case expected_nonce(Req, Opts) of
                undefined -> ok;
                Nonce ->
                    ExpectedNonce = hb_util:encode(Nonce),
                    case hb_maps:get(<<"nonce">>, Subject, <<>>, Opts) of
                        ExpectedNonce -> ok;
                        _ -> throw(<<"fresh nonce does not match verifier challenge">>)
                    end
            end,
            ExpectedBodyID = payload_id(Body, Opts),
            ExpectedRecipientID = secret_recipient_id(Recipient, Opts),
            GotBodyID = hb_maps:get(<<"body-id">>, Subject, undefined, Opts),
            GotRecipientID =
                hb_maps:get(<<"secret-recipient-id">>, Subject, undefined, Opts),
            GotSubjectID = stable_id(Subject, Opts),
            case {GotBodyID, GotRecipientID, GotSubjectID} of
                {ExpectedBodyID, ExpectedRecipientID, SubjectID} -> ok;
                _ ->
                    throw(#{
                        <<"error">> => <<"evidence-subject-binding-mismatch">>,
                        <<"expected-body-id">> => ExpectedBodyID,
                        <<"got-body-id">> => GotBodyID,
                        <<"expected-secret-recipient-id">> =>
                            ExpectedRecipientID,
                        <<"got-secret-recipient-id">> => GotRecipientID,
                        <<"expected-evidence-subject-id">> => SubjectID,
                        <<"got-evidence-subject-id">> => GotSubjectID
                    })
            end
        end).

check_measurement_shape(Measurement, Opts) ->
    safely_check(
        <<"measurement shape is lapee-measurement">>,
        <<"core">>,
        fun() ->
            case {hb_maps:get(<<"type">>, Measurement, undefined, Opts),
                  hb_maps:get(<<"body">>, Measurement, undefined, Opts),
                  hb_maps:get(<<"evidence">>, Measurement, undefined, Opts),
                  hb_maps:get(<<"secret-recipient">>, Measurement, undefined, Opts)} of
                {<<"lapee-measurement">>, Body, Evidence, Recipient}
                        when is_map(Body), is_map(Evidence),
                             is_map(Recipient) ->
                    ok;
                _ ->
                    throw(<<"invalid AndEE measurement envelope">>)
            end
        end).

check_evidence_shape(Evidence, Opts) ->
    safely_check(
        <<"evidence shape is andee-android-evidence">>,
        <<"core">>,
        fun() ->
            case {hb_maps:get(<<"type">>, Evidence, undefined, Opts),
                  hb_maps:get(<<"measurement-device">>, Evidence, undefined, Opts)} of
                {<<"andee-android-evidence">>, <<"andee@1.0">>} -> ok;
                Other -> throw(#{<<"evidence-shape">> => reason_to_text(Other)})
            end
        end).

check_certificate_chain_present(Evidence, Opts) ->
    safely_check(
        <<"Android attestation certificate chain is present">>,
        <<"core">>,
        fun() ->
            case certificate_chain_entries(Evidence, Opts) of
                [_ | _] -> ok;
                [] -> throw(<<"missing android-attestation-cert-chain">>)
            end
        end).

check_certificate_chain_parses(Evidence, Opts) ->
    safely_check(
        <<"Android attestation certificates parse">>,
        <<"core">>,
        fun() ->
            DERs = certificate_ders(Evidence, Opts),
            DERs =:= [] andalso throw(<<"missing certificate chain">>),
            lists:foreach(
                fun(Der) -> public_key:pkix_decode_cert(Der, otp) end,
                DERs),
            ok
        end).

check_certificate_chain_signatures(Evidence, Opts) ->
    safely_check(
        <<"Android attestation certificate chain signatures validate">>,
        <<"core">>,
        fun() -> assert_certificate_chain(certificate_ders(Evidence, Opts)) end).

check_certificate_root_trusted(Evidence, Opts) ->
    safely_check(
        <<"Android attestation root is trusted">>,
        <<"core">>,
        fun() ->
            case certificate_ders(Evidence, Opts) of
                [] ->
                    throw(<<"missing certificate chain">>);
                DERS ->
                    Root = lists:last(DERS),
                    RootID = hb_util:encode(crypto:hash(sha256, Root)),
                    case lists:member(RootID, android_root_ids(Opts)) of
                        true -> ok;
                        false ->
                            throw(#{<<"root-sha256">> => RootID,
                                    <<"trusted-root-count">> =>
                                        length(android_root_ids(Opts))})
                    end
            end
        end).

check_android_attestation_extension(Facts) ->
    safely_check(
        <<"Android attestation extension parses">>,
        <<"core">>,
        fun() ->
            case Facts of
                #{<<"parsed">> := true} -> ok;
                #{<<"error">> := Error} -> throw(Error);
                _ -> throw(<<"missing Android attestation facts">>)
            end
        end).

check_reported_attestation_facts(Evidence, Facts, Opts) ->
    safely_check(
        <<"reported Android attestation facts match verifier parser">>,
        <<"core">>,
        fun() ->
            Expected = public_attestation_facts(Facts),
            case hb_maps:get(
                <<"android-attestation-facts">>, Evidence, undefined, Opts) of
                Expected ->
                    ok;
                undefined ->
                    throw(<<"missing android-attestation-facts">>);
                Reported ->
                    throw(#{
                        <<"expected">> => Expected,
                        <<"reported">> => Reported
                    })
            end
        end).

check_attestation_challenge(Evidence, Facts, Opts) ->
    safely_check(
        <<"attestation challenge binds enrollment subject">>,
        <<"core">>,
        fun() ->
            Subject = hb_maps:get(
                <<"attestation-challenge-subject">>, Evidence, undefined, Opts),
            Raw = maps:get(raw_attestation_challenge, Facts, undefined),
            Expected = case is_binary(Subject) of
                true -> crypto:hash(sha256, Subject);
                false -> undefined
            end,
            case {Subject, Raw} of
                {B, Expected} when is_binary(B), is_binary(Expected) ->
                    ok;
                _ ->
                    throw(<<"attestation challenge mismatch">>)
            end
        end).

check_reported_security_level(Evidence, Facts, Opts) ->
    safely_check(
        <<"reported key security level matches attestation">>,
        <<"core">>,
        fun() ->
            Reported = hb_maps:get(
                <<"key-security-level">>, Evidence, undefined, Opts),
            Parsed = maps:get(<<"keymint-security-level">>, Facts, undefined),
            case {Reported, Parsed} of
                {Level, Level} when is_binary(Level) -> ok;
                _ -> throw(#{<<"reported">> => Reported, <<"parsed">> => Parsed})
            end
        end).

check_keystore_signature(Evidence, Opts) ->
    safely_check(
        <<"Keystore signature verifies evidence subject id">>,
        <<"core">>,
        fun() ->
            [Leaf | _] = certificate_ders(Evidence, Opts),
            SubjectID = hb_maps:get(
                <<"evidence-subject-id">>, Evidence, undefined, Opts),
            Signature = decode_required(<<"keystore-signature">>, Evidence, Opts),
            case is_binary(SubjectID) andalso public_key:verify(
                SubjectID, sha256, Signature, cert_public_key(Leaf)) of
                true -> ok;
                false -> throw(<<"keystore signature invalid">>)
            end
        end).

informational_check(Name, Detail) ->
    #{
        <<"name">> => Name,
        <<"ok">> => true,
        <<"detail">> => Detail,
        <<"severity">> => <<"informational">>
    }.

safely_check(Name, Severity, Fun) ->
    try Fun() of
        ok ->
            #{<<"name">> => Name,
              <<"ok">> => true,
              <<"severity">> => Severity};
        {ok, Detail} ->
            #{<<"name">> => Name,
              <<"ok">> => true,
              <<"detail">> => Detail,
              <<"severity">> => Severity}
    catch
        throw:Detail ->
            #{<<"name">> => Name,
              <<"ok">> => false,
              <<"detail">> => reason_to_text(Detail),
              <<"severity">> => Severity};
        Class:Reason ->
            #{<<"name">> => Name,
              <<"ok">> => false,
              <<"detail">> => #{<<"class">> => hb_util:bin(Class),
                                <<"reason">> => reason_to_text(Reason)},
              <<"severity">> => Severity}
    end.

require_agent(Action, Msg, Opts) ->
    case agent_request(Action, Msg, Opts) of
        {ok, Body} ->
            Body;
        {error, Reason} ->
            throw({andee_policy_error, Reason})
    end.

agent_request(Action, Msg, Opts) ->
    SocketPath = agent_socket(Opts),
    Timeout = agent_timeout(Opts),
    Request = #{
        <<"type">> => <<"andee-agent-request">>,
        <<"version">> => ?VERSION,
        <<"action">> => Action,
        <<"payload">> => Msg
    },
    try
        {ok, Socket} = gen_tcp:connect(
            {local, binary_to_list(SocketPath)},
            0,
            [binary, {active, false}, {packet, 4}],
            Timeout),
        ok = gen_tcp:send(Socket, iolist_to_binary(hb_json:encode(Request))),
        Reply =
            case gen_tcp:recv(Socket, 0, Timeout) of
                {ok, Bin} -> hb_json:decode(Bin);
                {error, RecvReason} -> #{<<"error">> => hb_util:bin(RecvReason)}
            end,
        gen_tcp:close(Socket),
        case Reply of
            #{<<"status">> := <<"ok">>, <<"body">> := Body} -> {ok, Body};
            #{<<"body">> := Body} when is_map(Body) -> {ok, Body};
            #{<<"error">> := _} -> {error, Reply};
            Body when is_map(Body) -> {ok, Body}
        end
    catch
        Class:Reason ->
            {error, #{
                <<"error">> => <<"andee-agent-unavailable">>,
                <<"socket">> => SocketPath,
                <<"class">> => hb_util:bin(Class),
                <<"reason">> => reason_to_text(Reason)
            }}
    end.

agent_socket(Opts) ->
    first_defined([
        configured_agent_socket(Opts),
        ?DEFAULT_SOCKET
    ]).

configured_agent_socket(Opts) ->
    first_defined([
        hb_opts:get(<<"andee-agent-socket">>, undefined, Opts),
        os:getenv("ANDEE_CRYPTO_SOCKET")
    ]).

agent_timeout(Opts) ->
    case hb_opts:get(<<"andee-agent-timeout-ms">>, ?DEFAULT_TIMEOUT_MS, Opts) of
        I when is_integer(I), I > 0 -> I;
        B when is_binary(B) -> binary_to_integer(B);
        _ -> ?DEFAULT_TIMEOUT_MS
    end.

measurement_nonce(Req, Opts) ->
    case expected_nonce(Req, Opts) of
        undefined -> crypto:strong_rand_bytes(32);
        Nonce -> Nonce
    end.

expected_nonce(Req, Opts) ->
    case hb_maps:get(<<"nonce">>, Req, undefined, Opts) of
        undefined -> undefined;
        B when is_binary(B) ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ -> undefined
    end.

activation_credential(Req, Opts) when is_map(Req) ->
    first_defined([
        hb_maps:get(<<"credential">>, Req, undefined, Opts),
        hb_maps:get(<<"wrapped-secret">>, Req, undefined, Opts),
        Req
    ]);
activation_credential(Req, _Opts) ->
    Req.

resolve_envelope(Base, Req, Opts) when is_map(Base) ->
    case hb_maps:get(<<"envelope">>, Req, undefined, Opts) of
        E when is_map(E) -> E;
        _ -> Base
    end;
resolve_envelope(_Base, Req, Opts) ->
    hb_maps:get(<<"envelope">>, Req, #{}, Opts).

response_body(#{<<"type">> := _} = Body, _Opts) ->
    Body;
response_body(#{<<"status">> := Status, <<"body">> := Body}, Opts)
        when is_integer(Status), Status < 400 ->
    response_body(Body, Opts);
response_body(#{<<"body">> := Body}, Opts) when is_map(Body) ->
    response_body(Body, Opts);
response_body(Body, _Opts) ->
    Body.

canonical_payload(Msg, Opts) when is_map(Msg) ->
    maps:from_list(
        [
            {Key, canonical_payload(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Msg, Opts),
            not detached_transport_key(Key)
        ]);
canonical_payload(List, Opts) when is_list(List) ->
    [canonical_payload(Value, Opts) || Value <- List];
canonical_payload(Value, _Opts) when is_atom(Value) ->
    hb_util:bin(Value);
canonical_payload(Value, _Opts) ->
    Value.

detached_transport_key(<<"commitments">>) -> true;
detached_transport_key(commitments) -> true;
detached_transport_key(<<"ao-types">>) -> true;
detached_transport_key('ao-types') -> true;
detached_transport_key(ao_types) -> true;
detached_transport_key(<<"status">>) -> true;
detached_transport_key(status) -> true;
detached_transport_key(_) -> false.

stable_id(Msg, Opts) when is_map(Msg) ->
    hb_message:id(
        canonical_payload(Msg, Opts),
        uncommitted,
        Opts);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    try hb_util:native_id(Bin) of
        Native when byte_size(Native) =:= 32 -> Bin;
        _ -> hb_util:encode(hb_crypto:sha256(Bin))
    catch
        _:_ -> hb_util:encode(hb_crypto:sha256(Bin))
    end;
stable_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
stable_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

payload_id(Msg, Opts) when is_map(Msg) ->
    stable_id(Msg, Opts);
payload_id(Value, Opts) ->
    stable_id(Value, Opts).

secret_recipient_id(Recipient, Opts) when is_map(Recipient) ->
    ID = stable_id(maps:remove(<<"subject-id">>, Recipient), Opts),
    case hb_maps:get(<<"subject-id">>, Recipient, undefined, Opts) of
        undefined -> ID;
        ID -> ID;
        _ -> throw(<<"recipient subject-id does not match recipient">>)
    end;
secret_recipient_id(Recipient, Opts) ->
    stable_id(Recipient, Opts).

certificate_chain_entries(Evidence, Opts) ->
    Chain = hb_maps:get(
        <<"android-attestation-cert-chain">>, Evidence, [], Opts),
    case Chain of
        List when is_list(List) ->
            [Entry || Entry <- List, is_binary(Entry), byte_size(Entry) > 0];
        Map when is_map(Map) ->
            [
                Value
             || {_Key, Value} <- indexed_map_values(Map),
                is_binary(Value),
                byte_size(Value) > 0
            ];
        _ ->
            []
    end.

indexed_map_values(Map) ->
    lists:sort(
        fun({A, _}, {B, _}) -> index_key(A) =< index_key(B) end,
        maps:to_list(Map)).

index_key(Key) when is_integer(Key) ->
    Key;
index_key(Key) when is_binary(Key) ->
    try binary_to_integer(Key)
    catch _:_ -> Key
    end;
index_key(Key) ->
    Key.

certificate_ders(Evidence, Opts) ->
    [
        try hb_util:decode(Entry)
        catch
            Class:Reason ->
                throw(#{<<"certificate-decode">> =>
                            #{<<"class">> => hb_util:bin(Class),
                              <<"reason">> => reason_to_text(Reason)}})
        end
     || Entry <- certificate_chain_entries(Evidence, Opts)
    ].

assert_certificate_chain([]) ->
    throw(<<"empty certificate chain">>);
assert_certificate_chain([_Only]) ->
    ok;
assert_certificate_chain(DERs) ->
    Root = lists:last(DERs),
    Path = lists:reverse(lists:droplast(DERs)),
    case public_key:pkix_path_validation(
        Root,
        Path,
        [{verify_fun, {fun android_chain_verify_fun/3, []}}]) of
        {ok, _} -> ok;
        {error, Reason} ->
            throw(#{<<"certificate-chain">> => reason_to_text(Reason)})
    end.

android_chain_verify_fun(_, valid, UserState) ->
    {valid, UserState};
android_chain_verify_fun(_, valid_peer, UserState) ->
    {valid, UserState};
android_chain_verify_fun(_, {extension, _}, UserState) ->
    {unknown, UserState};
android_chain_verify_fun(_, {bad_cert, Reason}, _UserState) ->
    {fail, Reason}.

android_root_ids(Opts) ->
    [hb_util:encode(crypto:hash(sha256, Der)) || Der <- android_root_ders(Opts)].

android_root_ders(Opts) ->
    case hb_opts:get(<<"andee-android-root-pem">>, undefined, Opts) of
        Pem when is_binary(Pem), byte_size(Pem) > 0 ->
            pem_cert_ders(Pem);
        _ ->
            pem_cert_ders(read_android_roots_pem(Opts))
    end.

read_android_roots_pem(Opts) ->
    case first_existing_priv_file(?ROOTS_PEM, Opts) of
        undefined -> <<>>;
        Path -> case file:read_file(Path) of
            {ok, Pem} -> Pem;
            _ -> <<>>
        end
    end.

first_existing_priv_file(Name, Opts) ->
    first_defined(
        [
            device_priv_file([Name], Opts),
            device_priv_file(["dev_andee", Name], Opts),
            priv_file(lapee_devices, ["dev_andee", Name]),
            priv_file(andee_devices, ["dev_andee", Name]),
            source_priv_file(Name)
        ]).

device_priv_file(Parts, Opts) ->
    case hb_opts:get(preloaded_store, undefined, Opts) of
        undefined ->
            undefined;
        _ ->
            try hb_device_archive:implementation_dir(?MODULE) of
                Dir -> existing_file(filename:join([Dir | Parts]))
            catch _:_ -> undefined
            end
    end.

priv_file(App, Parts) ->
    case code:priv_dir(App) of
        {error, _} ->
            undefined;
        Dir ->
            existing_file(filename:join([Dir | Parts]))
    end.

source_priv_file(Name) ->
    case code:which(?MODULE) of
        non_existing ->
            undefined;
        Beam ->
            existing_file(
                filename:join([
                    filename:dirname(Beam),
                    "..", "..", "..", "..", "..", "src", "priv",
                    "dev_andee", Name
                ]))
    end.

existing_file(Path) ->
    case filelib:is_regular(Path) of
        true -> Path;
        false -> undefined
    end.

pem_cert_ders(Pem) when is_binary(Pem) ->
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)];
pem_cert_ders(_) ->
    [].

cert_public_key(Der) ->
    #'OTPCertificate'{
        tbsCertificate =
            #'OTPTBSCertificate'{
                subjectPublicKeyInfo =
                    #'OTPSubjectPublicKeyInfo'{
                        algorithm =
                            #'PublicKeyAlgorithm'{parameters = Parameters},
                        subjectPublicKey = Key}}} =
        public_key:pkix_decode_cert(Der, otp),
    {Key, Parameters}.

attestation_facts(Evidence, Opts) ->
    try
        case certificate_ders(Evidence, Opts) of
            [] ->
                throw(<<"missing certificate chain">>);
            [Leaf | _] ->
                Facts = parse_android_attestation_extension(
                    android_attestation_extension(Leaf)),
                Facts#{<<"parsed">> => true}
        end
    catch
        Class:Reason ->
            #{
                <<"parsed">> => false,
                <<"error">> => #{
                    <<"class">> => hb_util:bin(Class),
                    <<"reason">> => reason_to_text(Reason)
                }
            }
    end.

public_attestation_facts(Facts) when is_map(Facts) ->
    maps:without([raw_attestation_challenge], Facts);
public_attestation_facts(Other) ->
    Other.

android_attestation_extension(Der) ->
    #'OTPCertificate'{tbsCertificate = Tbs} =
        public_key:pkix_decode_cert(Der, otp),
    Extensions = cert_extensions(Tbs),
    case extension_value(?ANDROID_ATTESTATION_OID, Extensions) of
        null -> throw(<<"Android attestation extension missing">>);
        Value -> Value
    end.

cert_extensions(#'OTPTBSCertificate'{extensions = Extensions})
        when is_list(Extensions) ->
    Extensions;
cert_extensions(_) ->
    [].

extension_value(Oid, Extensions) ->
    case [Value || #'Extension'{extnID = ExtOid, extnValue = Value}
                       <- Extensions,
                   ExtOid =:= Oid] of
        [Value | _] -> Value;
        [] -> null
    end.

parse_android_attestation_extension(Der) ->
    case read_der_value(Der, 0) of
        {#{tag_class := ?DER_UNIVERSAL, tag := ?DER_SEQUENCE,
           value := Body}, End} when End =:= byte_size(Der) ->
            parse_key_description(Body);
        {#{tag_class := ?DER_UNIVERSAL, tag := ?DER_OCTET_STRING,
           value := Wrapped}, End} when End =:= byte_size(Der) ->
            parse_android_attestation_extension(Wrapped);
        _ ->
            throw(<<"Android attestation extension is not a sequence">>)
    end.

parse_key_description(Body) ->
    Fields = read_der_values(Body, 8),
    AttestationSecurity = der_int(lists:nth(2, Fields), ?DER_ENUMERATED),
    KeyMintSecurity = der_int(lists:nth(4, Fields), ?DER_ENUMERATED),
    Challenge = der_octet(lists:nth(5, Fields)),
    SoftwareAuth = parse_authorization_list(lists:nth(7, Fields)),
    HardwareAuth = parse_authorization_list(lists:nth(8, Fields)),
    Root = case maps:get(?ROOT_OF_TRUST_TAG, HardwareAuth, undefined) of
        undefined -> #{};
        RootValue -> parse_root_of_trust(RootValue)
    end,
    AppID = case maps:get(?ATTESTATION_APPLICATION_ID_TAG,
                          SoftwareAuth,
                          undefined) of
        undefined -> #{};
        AppValue -> parse_attestation_application_id(AppValue)
    end,
    #{
        <<"attestation-version">> =>
            der_int(lists:nth(1, Fields), ?DER_INTEGER),
        <<"attestation-security-level">> =>
            security_level_name(AttestationSecurity),
        <<"keymint-version">> =>
            der_int(lists:nth(3, Fields), ?DER_INTEGER),
        <<"keymint-security-level">> =>
            security_level_name(KeyMintSecurity),
        <<"attestation-challenge">> => hb_util:encode(Challenge),
        raw_attestation_challenge => Challenge,
        <<"device-locked">> => maps:get(<<"device-locked">>, Root, null),
        <<"verified-boot-state">> =>
            maps:get(<<"verified-boot-state">>, Root, null),
        <<"verified-boot-key">> =>
            maps:get(<<"verified-boot-key">>, Root, null),
        <<"verified-boot-hash">> =>
            maps:get(<<"verified-boot-hash">>, Root, null),
        <<"os-patch-level">> =>
            auth_integer(?OS_PATCH_LEVEL_TAG, HardwareAuth),
        <<"vendor-patch-level">> =>
            auth_integer(?VENDOR_PATCH_LEVEL_TAG, HardwareAuth),
        <<"boot-patch-level">> =>
            auth_integer(?BOOT_PATCH_LEVEL_TAG, HardwareAuth),
        <<"attestation-application-id">> => AppID
    }.

parse_authorization_list(
        #{tag_class := ?DER_UNIVERSAL, tag := ?DER_SEQUENCE, value := Body}) ->
    parse_authorization_list(Body, #{});
parse_authorization_list(_) ->
    throw(<<"authorization list is not a sequence">>).

parse_authorization_list(<<>>, Acc) ->
    Acc;
parse_authorization_list(Bin, Acc) ->
    {Explicit, End} = read_der_value(Bin, 0),
    Rest = binary:part(Bin, End, byte_size(Bin) - End),
    case Explicit of
        #{tag_class := ?DER_CONTEXT_SPECIFIC, tag := Tag, value := Inner} ->
            {Value, _} = read_der_value(Inner, 0),
            parse_authorization_list(Rest, Acc#{Tag => Value});
        _ ->
            parse_authorization_list(Rest, Acc)
    end.

parse_root_of_trust(
        #{tag_class := ?DER_UNIVERSAL, tag := ?DER_SEQUENCE, value := Body}) ->
    [BootKey, Locked, BootState | Rest] = read_der_values(Body, all),
    Root0 = #{
        <<"verified-boot-key">> => hb_util:encode(der_octet(BootKey)),
        <<"device-locked">> => der_bool(Locked),
        <<"verified-boot-state">> =>
            verified_boot_state_name(der_int(BootState, ?DER_ENUMERATED))
    },
    case Rest of
        [BootHash | _] ->
            Root0#{<<"verified-boot-hash">> => hb_util:encode(der_octet(BootHash))};
        [] ->
            Root0
    end;
parse_root_of_trust(_) ->
    throw(<<"root of trust is not a sequence">>).

parse_attestation_application_id(
        #{tag_class := ?DER_UNIVERSAL, tag := ?DER_OCTET_STRING,
          value := Wrapped}) ->
    {#{tag_class := ?DER_UNIVERSAL, tag := ?DER_SEQUENCE, value := Body}, _} =
        read_der_value(Wrapped, 0),
    [PackageSet, DigestSet] = read_der_values(Body, 2),
    #{
        <<"package-infos">> => parse_package_infos(PackageSet),
        <<"signature-digests">> => parse_octet_set(DigestSet)
    };
parse_attestation_application_id(_) ->
    throw(<<"attestationApplicationId is not an octet string">>).

parse_package_infos(
        #{tag_class := ?DER_UNIVERSAL, tag := ?DER_SET, value := Body}) ->
    [
        begin
            [Name, Version] = read_der_values(InfoBody, 2),
            #{
                <<"package-name">> => der_octet(Name),
                <<"version">> => der_int(Version, ?DER_INTEGER)
            }
        end
     || #{tag_class := ?DER_UNIVERSAL, tag := ?DER_SEQUENCE,
          value := InfoBody} <- read_der_values(Body, all)
    ];
parse_package_infos(_) ->
    throw(<<"attestation package infos are not a set">>).

parse_octet_set(
        #{tag_class := ?DER_UNIVERSAL, tag := ?DER_SET, value := Body}) ->
    [hb_util:encode(der_octet(Value)) || Value <- read_der_values(Body, all)];
parse_octet_set(_) ->
    throw(<<"attestation signature digests are not a set">>).

auth_integer(Tag, Auth) ->
    case maps:get(Tag, Auth, undefined) of
        undefined -> null;
        Value -> der_int(Value, ?DER_INTEGER)
    end.

read_der_values(Bin, all) ->
    read_der_values_all(Bin, []);
read_der_values(Bin, Count) when is_integer(Count), Count >= 0 ->
    Values = read_der_values_all(Bin, []),
    case length(Values) >= Count of
        true -> lists:sublist(Values, Count);
        false -> throw(<<"DER sequence missing required fields">>)
    end.

read_der_values_all(<<>>, Acc) ->
    lists:reverse(Acc);
read_der_values_all(Bin, Acc) ->
    {Value, End} = read_der_value(Bin, 0),
    read_der_values_all(
        binary:part(Bin, End, byte_size(Bin) - End),
        [Value | Acc]).

read_der_value(Bin, Offset) when is_binary(Bin), Offset < byte_size(Bin) ->
    First = binary:at(Bin, Offset),
    TagClass = First band 16#C0,
    Tag0 = First band 16#1F,
    {Tag, AfterTag} = read_der_tag(Bin, Offset + 1, Tag0),
    {Length, AfterLength} = read_der_length(Bin, AfterTag),
    End = AfterLength + Length,
    case End =< byte_size(Bin) of
        true ->
            {#{tag_class => TagClass,
               tag => Tag,
               value => binary:part(Bin, AfterLength, Length)},
             End};
        false ->
            throw(<<"DER length escapes buffer">>)
    end;
read_der_value(_, _) ->
    throw(<<"short DER">>).

read_der_tag(_Bin, Offset, Tag) when Tag =/= 16#1F ->
    {Tag, Offset};
read_der_tag(Bin, Offset, 16#1F) ->
    read_high_der_tag(Bin, Offset, 0).

read_high_der_tag(Bin, Offset, Acc) when Offset < byte_size(Bin) ->
    Next = binary:at(Bin, Offset),
    Tag = (Acc bsl 7) bor (Next band 16#7F),
    case Next band 16#80 of
        0 -> {Tag, Offset + 1};
        _ -> read_high_der_tag(Bin, Offset + 1, Tag)
    end;
read_high_der_tag(_, _, _) ->
    throw(<<"short high-tag DER">>).

read_der_length(Bin, Offset) when Offset < byte_size(Bin) ->
    First = binary:at(Bin, Offset),
    case First band 16#80 of
        0 ->
            {First, Offset + 1};
        _ ->
            Count = First band 16#7F,
            case Count > 0 andalso Count =< 4
                    andalso Offset + 1 + Count =< byte_size(Bin) of
                true ->
                    LengthBytes = binary:part(Bin, Offset + 1, Count),
                    {binary:decode_unsigned(LengthBytes), Offset + 1 + Count};
                false ->
                    throw(<<"bad DER length">>)
            end
    end;
read_der_length(_, _) ->
    throw(<<"short DER length">>).

der_int(#{tag_class := ?DER_UNIVERSAL, tag := Expected, value := Value},
        Expected) ->
    binary:decode_unsigned(Value);
der_int(_, _) ->
    throw(<<"unexpected DER integer tag">>).

der_bool(#{tag_class := ?DER_UNIVERSAL, tag := ?DER_BOOLEAN, value := Value}) ->
    lists:any(fun(Byte) -> Byte =/= 0 end, binary:bin_to_list(Value));
der_bool(_) ->
    throw(<<"unexpected DER boolean tag">>).

der_octet(#{tag_class := ?DER_UNIVERSAL, tag := ?DER_OCTET_STRING,
            value := Value}) ->
    Value;
der_octet(_) ->
    throw(<<"unexpected DER octet-string tag">>).

security_level_name(0) -> <<"SOFTWARE">>;
security_level_name(1) -> <<"TEE">>;
security_level_name(2) -> <<"STRONGBOX">>;
security_level_name(Other) -> Other.

verified_boot_state_name(0) -> <<"VERIFIED">>;
verified_boot_state_name(1) -> <<"SELF_SIGNED">>;
verified_boot_state_name(2) -> <<"UNVERIFIED">>;
verified_boot_state_name(3) -> <<"FAILED">>;
verified_boot_state_name(Other) -> Other.

decode_required(Key, Msg, Opts) when is_map(Msg) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:decode(B);
        _ ->
            throw({andee_error, #{
                <<"error">> => <<"missing-field">>,
                <<"field">> => Key
            }})
    end.

secret_aad(SubjectID) ->
    <<"andee-wrap-secret-v1:", SubjectID/binary>>.

hkdf_sha256(IKM, Salt, Info, Length) ->
    PRK = crypto:mac(hmac, sha256, Salt, IKM),
    hkdf_expand(PRK, Info, Length, <<>>, <<>>, 1).

hkdf_expand(_PRK, _Info, Length, Acc, _Prev, _N)
        when byte_size(Acc) >= Length ->
    binary:part(Acc, 0, Length);
hkdf_expand(PRK, Info, Length, Acc, Prev, N) ->
    Block = crypto:mac(hmac, sha256, PRK, <<Prev/binary, Info/binary, N>>),
    hkdf_expand(PRK, Info, Length, <<Acc/binary, Block/binary>>, Block, N + 1).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([false | Rest]) -> first_defined(Rest);
first_defined([V | _]) when is_list(V) -> unicode:characters_to_binary(V);
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

raw_measurement_generation_requires_internal_token_test() ->
    ?assertMatch(
        {error, #{<<"status">> := 403}},
        subject(#{}, #{<<"body">> => #{}}, #{})),
    ?assertMatch(
        {error, #{<<"status">> := 403}},
        measure(#{}, #{<<"body">> => #{}}, #{})).

reported_attestation_facts_must_match_verifier_parser_test() ->
    Facts = #{
        <<"parsed">> => true,
        <<"verified-boot-state">> => <<"VERIFIED">>,
        <<"attestation-application-id">> => #{
            <<"package-infos">> => [
                #{<<"package-name">> => <<"org.permaweb.andee">>}
            ],
            <<"signature-digests">> => [<<"digest">>]
        },
        raw_attestation_challenge => <<"private-challenge">>
    },
    Public = public_attestation_facts(Facts),
    ?assertMatch(
        #{<<"ok">> := true},
        check_reported_attestation_facts(
            #{<<"android-attestation-facts">> => Public}, Facts, #{})),
    ?assertMatch(
        #{<<"ok">> := false},
        check_reported_attestation_facts(
            #{<<"android-attestation-facts">> =>
                  Public#{<<"verified-boot-state">> => <<"UNVERIFIED">>}},
            Facts,
            #{})),
    ?assertMatch(
        #{<<"ok">> := false},
        check_reported_attestation_facts(#{}, Facts, #{})).

-endif.
