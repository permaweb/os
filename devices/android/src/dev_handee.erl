%%% @doc Android Keystore/StrongBox measurement backend for HandEE.
%%%
%%% This module implements the backend contract consumed by
%%% `~measurement@1.0'. It keeps all public evidence and secret-recipient
%%% values as AO-Core-shaped messages. Android-specific policy checks,
%%% Keystore attestation, and Keystore signatures are delegated to the
%%% app-private `HandeeCryptoAgent' over a Unix-domain socket.
-module(dev_handee).
-implements(<<"handee@1.0">>).
-export([info/1, info/3, supported/3, subject/3, measure/3, verify/3,
         wrap_secret/3, unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         ensure_secret_activation/5]).

-include("include/hb.hrl").

-define(VERSION, <<"1.0">>).
-define(METHOD, <<"android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm">>).
-define(EVIDENCE_CONTEXT, <<"handee-android-evidence-v1">>).
-define(DEFAULT_SOCKET, <<"org.permaweb.handee.crypto">>).
-define(DEFAULT_TIMEOUT_MS, 5000).

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
            <<"measurement-device">> => <<"handee@1.0">>,
            <<"method">> => ?METHOD,
            <<"supported">> => handee_supported(Opts),
            <<"policy-accepted">> => handee_policy_accepted(Opts)
        }
    }}.

supported(_Base, _Req, Opts) ->
    {ok, handee_supported(Opts)}.

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
                evidence(EvidenceSubject, EvidenceSubjectID, Agent, Opts)
        }}
    catch
        throw:{handee_policy_error, Reason} ->
            {ok, #{
                <<"status">> => 200,
                <<"body">> => policy_failure_evidence(Reason, Req, Opts)
            }};
        Class:Reason ->
            error_resp(500, <<"handee-measure-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(Reason)})
    end.

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    Checks0 = [
        check_measurement_device(Measurement, Opts),
        check_evidence_subject(Measurement, Evidence, Req, Opts)
    ],
    AgentCheck = verify_with_agent(Measurement, Evidence, Req, Opts),
    Checks = Checks0 ++ [AgentCheck],
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
            error_resp(500, <<"handee-unwrap-secret-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(Reason)})
    end.

handee_supported(_Opts) ->
    true.

handee_policy_accepted(Opts) ->
    case agent_request(<<"policy-status">>, #{}, Opts) of
        {ok, #{<<"accepted">> := true}} -> true;
        _ -> false
    end.

secret_recipient(Body, Opts) ->
    {Public, _Private} = recipient_keypair(),
    BodyID = stable_id(Body, Opts),
    Binding0 = #{
        <<"evidence-context">> => ?EVIDENCE_CONTEXT,
        <<"body-id">> => BodyID,
        <<"measurement-device">> => <<"handee@1.0">>,
        <<"method">> => ?METHOD,
        <<"node-binding">> => node_binding(Opts)
    },
    BindingID = stable_id(Binding0, Opts),
    Recipient0 = #{
        <<"type">> => <<"lapee-secret-recipient">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
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
    case persistent_term:get({dev_handee, x25519_keypair}, undefined) of
        {Public, Private} ->
            {Public, Private};
        undefined ->
            {Public, Private} = crypto:generate_key(ecdh, x25519),
            persistent_term:put({dev_handee, x25519_keypair}, {Public, Private}),
            {Public, Private}
    end.

evidence_subject(Body, Recipient, Nonce, Purpose, Opts) ->
    Now = erlang:system_time(second),
    Subject0 = #{
        <<"type">> => <<"handee-evidence-subject">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
        <<"context">> => ?EVIDENCE_CONTEXT,
        <<"method">> => ?METHOD,
        <<"purpose">> => Purpose,
        <<"nonce">> => hb_util:encode(Nonce),
        <<"issued-at-unix">> => Now,
        <<"body">> => Body,
        <<"body-id">> => stable_id(Body, Opts),
        <<"secret-recipient">> => Recipient,
        <<"secret-recipient-id">> => secret_recipient_id(Recipient, Opts),
        <<"node-binding">> => node_binding(Opts)
    },
    Subject = canonical_payload(Subject0, Opts),
    {Subject, stable_id(Subject, Opts)}.

evidence(EvidenceSubject, EvidenceSubjectID, Agent, Opts) ->
    Policy = hb_maps:get(<<"policy-snapshot">>, Agent, #{}, Opts),
    #{
        <<"type">> => <<"handee-android-evidence">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
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
        <<"node-key-binding">> =>
            hb_maps:get(<<"node-key-binding">>, Agent, node_binding(Opts), Opts),
        <<"policy-snapshot">> => Policy,
        <<"key-security-level">> =>
            hb_maps:get(<<"key-security-level">>, Agent, <<"unknown">>, Opts),
        <<"accepted">> => hb_maps:get(<<"accepted">>, Agent, false, Opts),
        <<"verdict">> =>
            hb_maps:get(<<"verdict">>, Agent, <<"policy-failure">>, Opts)
    }.

policy_failure_evidence(Reason, Req, Opts) ->
    Body = hb_maps:get(<<"body">>, Req, #{}, Opts),
    Nonce = measurement_nonce(Req),
    Purpose = hb_maps:get(<<"purpose">>, Req, <<"fresh">>, Opts),
    {Subject, SubjectID} =
        evidence_subject(Body, #{}, Nonce, Purpose, Opts),
    #{
        <<"type">> => <<"handee-android-evidence">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
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
    Info = <<"handee-wrap-secret-v1:", SubjectID/binary>>,
    Key = hkdf_sha256(Shared, Salt, Info, 32),
    AAD = secret_aad(SubjectID),
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm, Key, IV, Secret, AAD, 16, true),
    #{
        <<"type">> => <<"lapee-wrapped-secret">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
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
    Info = <<"handee-wrap-secret-v1:", SubjectID/binary>>,
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
            throw({handee_error,
                   #{<<"secret-activation">> =>
                        <<"activation proof did not match challenge">>}})
    end.

secret_activation_public_body(Secret, Credential, Opts) ->
    Now = erlang:system_time(second),
    #{
        <<"type">> => <<"lapee-secret-activation">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"handee@1.0">>,
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
      "measurement-device:handee@1.0\n",
      "method:", ?METHOD/binary, "\n",
      "issued-at-unix:", (integer_to_binary(IssuedAt))/binary, "\n",
      "credential-id:", (wrapped_secret_id(Credential, Opts))/binary>>.

wrapped_secret_id(Credential, Opts) when is_map(Credential) ->
    stable_id(
        maps:from_list(
            [
                {Key, Value}
             || Key <- wrapped_secret_identity_keys(),
                (Value = hb_maps:get(Key, Credential, undefined, #{}))
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
        <<"measurement device is handee@1.0">>,
        <<"core">>,
        fun() ->
            case hb_maps:get(<<"measurement-device">>, Measurement, undefined, Opts) of
                <<"handee@1.0">> -> ok;
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
            case expected_nonce(Req) of
                undefined -> ok;
                Nonce ->
                    ExpectedNonce = hb_util:encode(Nonce),
                    case hb_maps:get(<<"nonce">>, Subject, <<>>, Opts) of
                        ExpectedNonce -> ok;
                        _ -> throw(<<"fresh nonce does not match verifier challenge">>)
                    end
            end,
            ExpectedBodyID = stable_id(Body, Opts),
            ExpectedRecipientID = secret_recipient_id(Recipient, Opts),
            case {
                hb_maps:get(<<"body-id">>, Subject, undefined, Opts),
                hb_maps:get(<<"secret-recipient-id">>, Subject, undefined, Opts),
                stable_id(Subject, Opts)
            } of
                {ExpectedBodyID, ExpectedRecipientID, SubjectID} -> ok;
                _ -> throw(<<"evidence subject binding mismatch">>)
            end
        end).

verify_with_agent(Measurement, Evidence, Req, Opts) ->
    safely_check(
        <<"Android attestation chain, package identity, policy, and signature verify">>,
        <<"core">>,
        fun() ->
            case agent_request(
                    <<"verify-evidence">>,
                    #{
                        <<"measurement">> => Measurement,
                        <<"evidence">> => Evidence,
                        <<"request">> => Req
                    },
                    Opts) of
                {ok, #{<<"verified">> := true}} -> ok;
                {ok, Body} -> throw(Body);
                {error, Reason} -> throw(Reason)
            end
        end).

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
            throw({handee_policy_error, Reason})
    end.

agent_request(Action, Msg, Opts) ->
    SocketPath = agent_socket(Opts),
    Timeout = agent_timeout(Opts),
    Request = #{
        <<"type">> => <<"handee-agent-request">>,
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
                <<"error">> => <<"handee-agent-unavailable">>,
                <<"socket">> => SocketPath,
                <<"class">> => hb_util:bin(Class),
                <<"reason">> => reason_to_text(Reason)
            }}
    end.

agent_socket(Opts) ->
    first_defined([
        hb_opts:get(<<"handee-agent-socket">>, undefined, Opts),
        os:getenv("HANDEE_CRYPTO_SOCKET"),
        ?DEFAULT_SOCKET
    ]).

agent_timeout(Opts) ->
    case hb_opts:get(<<"handee-agent-timeout-ms">>, ?DEFAULT_TIMEOUT_MS, Opts) of
        I when is_integer(I), I > 0 -> I;
        B when is_binary(B) -> binary_to_integer(B);
        _ -> ?DEFAULT_TIMEOUT_MS
    end.

node_binding(Opts) ->
    #{
        <<"node-address">> =>
            hb_opts:get(<<"address">>, <<"unknown">>, Opts),
        <<"node-message-id">> =>
            hb_opts:get(<<"handee-node-message-id">>, <<"unknown">>, Opts),
        <<"node-key-scope">> => <<"ephemeral-memory">>,
        <<"measurement-device">> => <<"handee@1.0">>
    }.

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
detached_transport_key(_) -> false.

stable_id(Msg, Opts) when is_map(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(canonical_payload(Msg, Opts), Opts),
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

secret_recipient_id(Recipient, Opts) when is_map(Recipient) ->
    case hb_maps:get(<<"subject-id">>, Recipient, undefined, Opts) of
        ID when is_binary(ID), byte_size(ID) > 0 -> ID;
        _ -> stable_id(Recipient, Opts)
    end;
secret_recipient_id(Recipient, Opts) ->
    stable_id(Recipient, Opts).

decode_required(Key, Msg, Opts) when is_map(Msg) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:decode(B);
        _ ->
            throw({handee_error, #{
                <<"error">> => <<"missing-field">>,
                <<"field">> => Key
            }})
    end.

secret_aad(SubjectID) ->
    <<"handee-wrap-secret-v1:", SubjectID/binary>>.

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
