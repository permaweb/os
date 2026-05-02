%%% @doc TPM-backed green-zone rings.
%%%
%%% A green-zone is a shared signing identity admitted by evidence rather than
%%% by operator fiat. The device is intentionally small:
%%%
%%% * `init' creates or loads a ring wallet, a 256-bit AES ring secret, and a
%%%   deeply-nested template.
%%% * `admit' verifies a candidate peer through `~tpm@2.0a/verify-peer',
%%%   matches the candidate's nonce-bound fresh attestation against the
%%%   template, then wraps the ring AES secret to the peer's TPM using
%%%   MakeCredential. The ring wallet is encrypted under that AES key.
%%% * `join' asks an existing member for admission, checks the admission
%%%   envelope, unwraps the AES key through `~tpm@2.0a/activate-credential',
%%%   decrypts the wallet, verifies its advertised ring address, and installs
%%%   it as the local `green-zone' identity.
%%% * `sign' signs an arbitrary message with that shared ring wallet.
%%%
%%% The policy language is deliberately just deep-subset matching. A template
%%% map matches when every key in the template exists in the candidate and its
%%% value recursively matches. Non-map values match exactly, with `<<"$any">>'
%%% as the only wildcard. This makes the enforced parameters explicit AO-Core
%%% data, while leaving trust policy interpretation to callers.
-module(dev_green_zone).
-export([info/1, info/3, init/3, status/3, admit/3, join/3, sign/3,
         match/3]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(DEFAULT_IDENTITY, <<"green-zone">>).
-define(TEMPLATE_META_KEYS, [<<"commitments">>, <<"ao-types">>]).

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"init">>,
            <<"status">>,
            <<"admit">>,
            <<"join">>,
            <<"sign">>,
            <<"match">>
        ]
    }.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"description">> =>
                <<"TPM-backed green-zone ring admission and shared identity">>,
            <<"version">> => <<"1.0">>,
            <<"template-semantics">> =>
                <<"Deep map subset match; non-map values exact; '$any' wildcard">>,
            <<"peer-attestation-trust">> =>
                <<"Admission can verify a live joiner-url, or reuse a signed "
                  "lapee-peer-attestation when one of its signers is listed in "
                  "the ring's configured trusted publishers.">>
        }
    }}.

init(_Base, Req, Opts) ->
    with_result(fun() ->
        Template = template_from(Req, Opts),
        AES = existing_or_new_aes(Req, Opts),
        Wallet = existing_or_new_wallet(Req, Opts),
        TrustedPublishers = trusted_publishers_from_req(Req, Opts),
        NewOpts = install_ring(Template, AES, Wallet, TrustedPublishers, Opts),
        hb_http_server:set_opts(NewOpts),
        status_body(NewOpts)
    end, Opts).

status(_Base, _Req, Opts) ->
    with_result(fun() -> status_body(Opts) end, Opts).

match(_Base, Req, Opts) ->
    with_result(fun() ->
        Template = clean_template(
            hb_maps:get(<<"template">>, Req, template_from(Req, Opts), Opts),
            Opts),
        Candidate = hb_maps:get(<<"candidate">>, Req, undefined, Opts),
        #{
            <<"matched">> => match_template(Template, Candidate, Opts),
            <<"template">> => Template
        }
    end, Opts).

admit(_Base, Req, Opts) ->
    with_result(fun() ->
        {AES, Wallet, Template} = require_ring(Opts),
        RingScope = ring_scope(Template, Wallet, Opts),
        {JoinerURL, PeerAttestation, Publisher} =
            peer_attestation_from_req(Req, RingScope, Opts),
        PolicyAttestation = peer_policy_attestation_body(PeerAttestation, Opts),
        case match_template(Template, PolicyAttestation, Opts) of
            true -> ok;
            false ->
                throw({green_zone_error, #{
                    <<"error">> => <<"template-mismatch">>,
                    <<"mismatch-path">> =>
                        mismatch_path(Template, PolicyAttestation, Opts),
                    <<"joiner-url">> => JoinerURL
                }})
        end,
        Subject = hb_maps:get(
            <<"peer-credential-subject">>, PeerAttestation, undefined, Opts),
        Credential = dev_tpm2:make_credential_for_subject(Subject, AES),
        hb_message:commit(#{
            <<"type">> => <<"green-zone-admission">>,
            <<"version">> => <<"1.0">>,
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"validity">> => admission_validity(Req, Opts),
            <<"admission-nonce">> =>
                hb_maps:get(<<"admission-nonce">>, Req, null, Opts),
            <<"ring-scope">> => RingScope,
            <<"joiner-url">> => JoinerURL,
            <<"template">> => Template,
            <<"template-matched">> => true,
            <<"peer-attestation-publisher">> => Publisher,
            <<"peer-attestation">> => PeerAttestation,
            <<"credential">> => Credential,
            <<"encrypted-wallet">> => encrypt_wallet(Wallet, AES),
            <<"ring-address">> => wallet_address(Wallet),
            <<"trusted-publishers">> => trusted_publishers(Opts)
        }, #{<<"priv-wallet">> => Wallet})
    end, Opts).

join(_Base, Req, Opts) ->
    with_result(fun() ->
        PeerURL = required_peer(Req, Opts),
        SelfURL = required_self(Req, Opts),
        AdmissionNonce = hb_util:encode(crypto:strong_rand_bytes(32)),
        Admission =
            request_admission(PeerURL, SelfURL, AdmissionNonce, Req, Opts),
        assert_admission_body(
            Admission, PeerURL, SelfURL, AdmissionNonce, Req, Opts),
        Credential = hb_maps:get(<<"credential">>, Admission, undefined, Opts),
        AES = activate_local_credential(Credential, Opts),
        Wallet = decrypt_wallet(
            hb_maps:get(<<"encrypted-wallet">>, Admission, undefined, Opts),
            AES,
            Opts
        ),
        assert_wallet_matches_admission(Wallet, Admission, Opts),
        Template = hb_maps:get(<<"template">>, Admission, #{}, Opts),
        TrustedPublishers =
            normalize_publishers(
                hb_maps:get(<<"trusted-publishers">>, Admission, [], Opts)),
        NewOpts = install_ring(
            Template, AES, Wallet, TrustedPublishers, Opts),
        hb_http_server:set_opts(NewOpts#{
            <<"green-zone-last-admission">> => Admission
        }),
        status_body(NewOpts)
    end, Opts).

sign(_Base, Req, Opts) ->
    with_result(fun() ->
        RingOpts = green_zone_signing_opts(Opts),
        Payload = sign_payload(Req, Opts),
        hb_message:commit(Payload, RingOpts)
    end, Opts).

with_result(Fun, Opts) ->
    try
        ResultBody = ensure_committed(Fun(), Opts),
        {ok, #{<<"status">> => 200, <<"body">> => ResultBody}}
    catch
        throw:{green_zone_error, ErrorBody} ->
            {ok, #{<<"status">> => 400, <<"body">> => ErrorBody}};
        Class:Reason:Stacktrace ->
            {ok, #{
                <<"status">> => 500,
                <<"body">> => #{
                    <<"error">> => <<"green-zone-failed">>,
                    <<"class">> => hb_util:bin(Class),
                    <<"reason">> =>
                        iolist_to_binary(io_lib:format("~p", [Reason])),
                    <<"stacktrace">> =>
                        iolist_to_binary(io_lib:format("~p", [Stacktrace]))
                }
            }}
    end.

ensure_committed(Msg, Opts) when is_map(Msg) ->
    case hb_message:signers(Msg, Opts) of
        [] -> hb_message:commit(Msg, Opts);
        _ -> Msg
    end;
ensure_committed(Msg, _Opts) ->
    Msg.

template_from(Req, Opts) ->
    clean_template(
        hb_maps:get(
            <<"template">>,
            Req,
            hb_opts:get(<<"green-zone-template">>, #{}, Opts),
            Opts),
        Opts).

existing_or_new_aes(Req, Opts) ->
    case hb_maps:get(<<"aes-key">>, Req, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:decode(B);
        _ ->
            hb_opts:get(
                <<"priv-green-zone-aes">>,
                crypto:strong_rand_bytes(32),
                Opts
            )
    end.

existing_or_new_wallet(Req, Opts) ->
    case hb_maps:get(<<"wallet">>, Req, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> ar_wallet:from_json(B);
        _ ->
            hb_opts:get(
                <<"priv-green-zone-wallet">>,
                ar_wallet:new(),
                Opts
            )
    end.

install_ring(Template0, AES, Wallet, TrustedPublishers, Opts) ->
    Template = clean_template(Template0, Opts),
    ok = ensure_nonempty_template(Template),
    Identities = hb_opts:get(identities, #{}, Opts),
    Opts#{
        <<"green-zone-template">> => Template,
        <<"green-zone-initialized">> => true,
        <<"green-zone-trusted-publishers">> =>
            normalize_publishers(TrustedPublishers),
        <<"priv-green-zone-aes">> => AES,
        <<"priv-green-zone-wallet">> => Wallet,
        <<"identities">> => Identities#{
            ?DEFAULT_IDENTITY => #{<<"priv-wallet">> => Wallet}
        }
    }.

require_ring(Opts) ->
    case {
        hb_opts:get(<<"priv-green-zone-aes">>, undefined, Opts),
        hb_opts:get(<<"priv-green-zone-wallet">>, undefined, Opts),
        hb_opts:get(<<"green-zone-template">>, undefined, Opts)
    } of
        {AES, Wallet, Template}
                when is_binary(AES), tuple_size(Wallet) > 0,
                     is_map(Template) ->
            {AES, Wallet, Template};
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"green-zone-not-initialized">>
            }})
    end.

status_body(Opts) ->
    Wallet = hb_opts:get(<<"priv-green-zone-wallet">>, undefined, Opts),
    Template = hb_opts:get(<<"green-zone-template">>, #{}, Opts),
    Address =
        case Wallet of
            undefined -> undefined;
            _ -> wallet_address(Wallet)
        end,
    RingScope =
        case Wallet of
            undefined -> null;
            _ -> ring_scope(Template, Wallet, Opts)
        end,
    #{
        <<"type">> => <<"green-zone-status">>,
        <<"version">> => <<"1.0">>,
        <<"initialized">> =>
            hb_opts:get(<<"green-zone-initialized">>, false, Opts),
        <<"identity">> => ?DEFAULT_IDENTITY,
        <<"ring-address">> => Address,
        <<"ring-scope">> => RingScope,
        <<"trusted-publishers">> => trusted_publishers(Opts),
        <<"template">> => Template
    }.

ring_scope(Template, Wallet, Opts) ->
    #{
        <<"type">> => <<"green-zone-ring-scope">>,
        <<"version">> => <<"1.0">>,
        <<"ring-address">> => wallet_address(Wallet),
        <<"template-id">> => template_id(Template, Opts)
    }.

template_id(Template, Opts) ->
    hb_message:id(
        #{<<"type">> => <<"green-zone-template">>,
          <<"template">> => clean_template(Template, Opts)},
        all,
        Opts).

admission_validity(_Req, Opts) ->
    Now = erlang:system_time(second),
    TTL = admission_ttl_seconds(Opts),
    #{
        <<"not-before-unix">> => Now,
        <<"expires-at-unix">> => Now + TTL
    }.

required_url(Req, Opts) ->
    case first_defined(
        [
            hb_maps:get(<<"joiner-url">>, Req, undefined, Opts),
            hb_maps:get(<<"peer-url">>, Req, undefined, Opts),
            hb_maps:get(<<"url">>, Req, undefined, Opts)
        ]
    ) of
        undefined ->
            throw({green_zone_error, #{
                <<"error">> => <<"missing-joiner-url">>
            }});
        URL -> strip_trailing_slash(URL)
    end.

required_peer(Req, Opts) ->
    case first_defined(
        [
            hb_maps:get(<<"peer-url">>, Req, undefined, Opts),
            hb_maps:get(<<"url">>, Req, undefined, Opts),
            hb_opts:get(<<"green-zone-peer-url">>, undefined, Opts)
        ]
    ) of
        undefined ->
            throw({green_zone_error, #{<<"error">> => <<"missing-peer-url">>}});
        URL -> strip_trailing_slash(URL)
    end.

required_self(Req, Opts) ->
    case first_defined(
        [
            hb_maps:get(<<"self-url">>, Req, undefined, Opts),
            hb_opts:get(<<"green-zone-self-url">>, undefined, Opts),
            hb_opts:get(<<"public-url">>, undefined, Opts)
        ]
    ) of
        undefined ->
            throw({green_zone_error, #{<<"error">> => <<"missing-self-url">>}});
        URL -> strip_trailing_slash(URL)
    end.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

strip_trailing_slash(B) when is_binary(B), byte_size(B) > 0 ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _  -> B
    end;
strip_trailing_slash(B) ->
    B.

verify_joiner(JoinerURL, Req, RingScope, Opts) ->
    VerifyReq = Req#{
        <<"url">> => JoinerURL,
        <<"peer-attestation-scope">> => RingScope
    },
    case dev_tpm2:verify_peer(#{}, VerifyReq, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} -> Body;
        {ok, #{<<"body">> := Body}} ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-verification-failed">>,
                <<"details">> => Body
            }});
        Other ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-verification-failed">>,
                <<"details">> => hb_util:bin(io_lib:format("~p", [Other]))
            }})
    end.

peer_attestation_from_req(Req, RingScope, Opts) ->
    case hb_maps:get(<<"peer-attestation">>, Req, undefined, Opts) of
        PeerAttestation0 when is_map(PeerAttestation0) ->
            PeerAttestation = response_body(PeerAttestation0, Opts),
            Publisher = require_trusted_publisher(PeerAttestation, Req, Opts),
            assert_peer_attestation_body(PeerAttestation, RingScope, Opts),
            JoinerURL = stored_attestation_joiner_url(
                PeerAttestation, Req, Opts),
            {JoinerURL, PeerAttestation, Publisher};
        _ ->
            JoinerURL = required_url(Req, Opts),
            PeerAttestation = verify_joiner(JoinerURL, Req, RingScope, Opts),
            assert_peer_attestation_body(PeerAttestation, RingScope, Opts),
            {JoinerURL, PeerAttestation, null}
    end.

require_trusted_publisher(PeerAttestation, _Req, Opts) ->
    Signers = peer_attestation_signers(PeerAttestation, Opts),
    case hb_message:verify(PeerAttestation, Signers, Opts) of
        true -> ok;
        false ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-attestation-signature-invalid">>
            }})
    end,
    Trusted = trusted_publishers(Opts),
    case [S || S <- Signers, lists:member(S, Trusted)] of
        [Publisher | _] -> Publisher;
        [] ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-attestation-publisher-untrusted">>,
                <<"signers">> => Signers,
                <<"trusted-publishers">> => Trusted
            }})
    end.

peer_attestation_signers(PeerAttestation, Opts) ->
    try hb_message:signers(PeerAttestation, Opts) of
        [] ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-attestation-unsigned">>
            }});
        Signers -> Signers
    catch
        throw:{green_zone_error, _} = Error -> throw(Error);
        _:_ ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-attestation-signers-unreadable">>
            }})
    end.

trusted_publishers(Opts) ->
    normalize_publishers(first_defined([
        hb_opts:get(<<"green-zone-trusted-publishers">>, undefined, Opts),
        hb_opts:get(<<"green-zone-trusted-publisher">>, undefined, Opts)
    ])).

trusted_publishers_from_req(Req, Opts) ->
    normalize_publishers(first_defined([
        hb_maps:get(<<"trusted-publishers">>, Req, undefined, Opts),
        hb_maps:get(<<"trusted-publisher">>, Req, undefined, Opts),
        hb_opts:get(<<"green-zone-trusted-publishers">>, undefined, Opts),
        hb_opts:get(<<"green-zone-trusted-publisher">>, undefined, Opts)
    ])).

normalize_publishers(undefined) -> [];
normalize_publishers(B) when is_binary(B), byte_size(B) > 0 -> [B];
normalize_publishers(L) when is_list(L) ->
    [B || B <- L, is_binary(B), byte_size(B) > 0];
normalize_publishers(_) -> [].

clock_skew_seconds(Opts) ->
    parse_positive_integer(
        hb_opts:get(<<"green-zone-clock-skew-seconds">>, 300, Opts),
        300).

peer_attestation_max_age_seconds(Opts) ->
    parse_positive_integer(
        hb_opts:get(<<"green-zone-peer-attestation-max-age-seconds">>,
                    3600, Opts),
        3600).

admission_ttl_seconds(Opts) ->
    parse_positive_integer(
        hb_opts:get(<<"green-zone-admission-ttl-seconds">>, 300, Opts),
        300).

parse_positive_integer(N, _Default) when is_integer(N), N > 0 ->
    N;
parse_positive_integer(B, Default) when is_binary(B) ->
    try binary_to_integer(B) of
        N when N > 0 -> N;
        _ -> Default
    catch _:_ -> Default
    end;
parse_positive_integer(_, Default) ->
    Default.

encoded_field_sha256(Key, Msg, Opts) ->
    hb_util:encode(
        crypto:hash(
            sha256,
            safe_decode(hb_maps:get(Key, Msg, <<>>, Opts)))).

assert_peer_attestation_body(PeerAttestation, RingScope, Opts) ->
    Required = [
        {field_eq, <<"type">>, <<"lapee-peer-attestation">>},
        {field_integer, <<"issued-at-unix">>},
        {nested_true, <<"boot-verification">>, <<"verified">>},
        {nested_true, <<"verification">>, <<"verified">>},
        {nested_true, <<"freshness">>, <<"verified">>},
        {nested_true, <<"credential-activation">>, <<"verified">>},
        {field_map, <<"validity">>},
        {field_map, <<"peer-scope">>},
        {field_map, <<"peer-credential-subject">>},
        {field_map, <<"peer-boot-attestation">>},
        {field_map, <<"peer-fresh-attestation">>}
    ],
    lists:foreach(
        fun
            ({field_eq, Key, Expected}) ->
                case hb_maps:get(Key, PeerAttestation, undefined, Opts) of
                    Expected -> ok;
                    _ -> bad_peer_attestation(Key)
                end;
            ({nested_true, Outer, Inner}) ->
                case hb_maps:get(Outer, PeerAttestation, undefined, Opts) of
                    M when is_map(M) ->
                        case hb_maps:get(Inner, M, false, Opts) of
                            true -> ok;
                            _ -> bad_peer_attestation(Outer)
                        end;
                    _ -> bad_peer_attestation(Outer)
                end;
            ({field_integer, Key}) ->
                case hb_maps:get(Key, PeerAttestation, undefined, Opts) of
                    I when is_integer(I), I > 0 -> ok;
                    _ -> bad_peer_attestation(Key)
                end;
            ({field_map, Key}) ->
                case hb_maps:get(Key, PeerAttestation, undefined, Opts) of
                    M when is_map(M) -> ok;
                    _ -> bad_peer_attestation(Key)
                end
        end,
        Required),
    assert_peer_attestation_validity(PeerAttestation, Opts),
    assert_peer_attestation_scope(PeerAttestation, RingScope, Opts).

bad_peer_attestation(Key) ->
    throw({green_zone_error, #{
        <<"error">> => <<"peer-attestation-invalid">>,
        <<"field">> => Key
    }}).

assert_peer_attestation_validity(PeerAttestation, Opts) ->
    Now = erlang:system_time(second),
    Skew = clock_skew_seconds(Opts),
    MaxAge = peer_attestation_max_age_seconds(Opts),
    IssuedAt = hb_maps:get(<<"issued-at-unix">>, PeerAttestation, 0, Opts),
    Validity = hb_maps:get(<<"validity">>, PeerAttestation, #{}, Opts),
    NotBefore = hb_maps:get(<<"not-before-unix">>, Validity, IssuedAt, Opts),
    Expires = hb_maps:get(<<"expires-at-unix">>, Validity, undefined, Opts),
    case IssuedAt =< Now + Skew andalso NotBefore =< Now + Skew of
        true -> ok;
        false -> bad_peer_attestation(<<"validity.not-before-unix">>)
    end,
    case Expires of
        undefined -> ok;
        I when is_integer(I), I + Skew >= Now -> ok;
        _ -> bad_peer_attestation(<<"validity.expires-at-unix">>)
    end,
    case MaxAge of
        undefined -> ok;
        Age when is_integer(Age), Age > 0, IssuedAt + Age + Skew >= Now -> ok;
        _ -> bad_peer_attestation(<<"issued-at-unix">>)
    end.

assert_peer_attestation_scope(PeerAttestation, RingScope, Opts) ->
    Scope = hb_maps:get(<<"peer-scope">>, PeerAttestation, #{}, Opts),
    ConsumerScope =
        hb_maps:get(<<"consumer-scope">>, Scope, undefined, Opts),
    assert_scope_field(
        <<"ring-address">>, ConsumerScope, RingScope, Opts),
    assert_scope_field(
        <<"template-id">>, ConsumerScope, RingScope, Opts),
    PeerURL = strip_trailing_slash(
        hb_maps:get(<<"peer-url">>, PeerAttestation, undefined, Opts)),
    case strip_trailing_slash(
        hb_maps:get(<<"peer-url">>, Scope, undefined, Opts)) of
        PeerURL when PeerURL =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.peer-url">>)
    end,
    assert_scope_attestation_id(
        <<"boot-attestation-id">>, <<"peer-boot-attestation">>,
        PeerAttestation, Scope, Opts),
    assert_scope_attestation_id(
        <<"fresh-attestation-id">>, <<"peer-fresh-attestation">>,
        PeerAttestation, Scope, Opts),
    Subject = hb_maps:get(
        <<"peer-credential-subject">>, PeerAttestation, #{}, Opts),
    case {
        hb_maps:get(<<"ek-public-sha256">>, Scope, undefined, Opts),
        encoded_field_sha256(<<"ek-public">>, Subject, Opts),
        hb_maps:get(<<"ak-name-sha256">>, Scope, undefined, Opts),
        encoded_field_sha256(<<"ak-name">>, Subject, Opts)
    } of
        {Ek, Ek, Ak, Ak} -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.tpm-material">>)
    end.

assert_scope_attestation_id(ScopeKey, AttestationKey, PeerAttestation,
                            Scope, Opts) ->
    Attestation = response_body(
        hb_maps:get(AttestationKey, PeerAttestation, undefined, Opts),
        Opts),
    Expected = attestation_id(Attestation, Opts),
    case hb_maps:get(ScopeKey, Scope, undefined, Opts) of
        Expected -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.attestation-id">>)
    end.

attestation_id(Attestation, Opts) when is_map(Attestation) ->
    hb_message:id(Attestation, all, Opts);
attestation_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

assert_scope_field(Key, Scope, RingScope, Opts) ->
    Expected = hb_maps:get(Key, RingScope, undefined, Opts),
    case hb_maps:get(Key, Scope, undefined, Opts) of
        Expected when Expected =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.consumer-scope">>)
    end.

stored_attestation_joiner_url(PeerAttestation, Req, Opts) ->
    AttestedURL0 = hb_maps:get(
        <<"peer-url">>, PeerAttestation, undefined, Opts),
    ReqURL0 = hb_maps:get(<<"joiner-url">>, Req, undefined, Opts),
    case {AttestedURL0, ReqURL0} of
        {undefined, _} ->
            throw({green_zone_error, #{
                <<"error">> => <<"missing-peer-attestation-url">>
            }});
        {AttestedURL, undefined} ->
            strip_trailing_slash(AttestedURL);
        {AttestedURL, ReqURL} ->
            Attested = strip_trailing_slash(AttestedURL),
            Requested = strip_trailing_slash(ReqURL),
            case Attested =:= Requested of
                true -> Attested;
                false ->
                    throw({green_zone_error, #{
                        <<"error">> => <<"peer-attestation-url-mismatch">>,
                        <<"peer-url">> => Attested,
                        <<"joiner-url">> => Requested
                    }})
            end
    end.

peer_boot_attestation_body(PeerAttestation, Opts) ->
    response_body(
        hb_maps:get(
            <<"peer-boot-attestation">>, PeerAttestation, undefined, Opts),
        Opts).

peer_policy_attestation_body(PeerAttestation, Opts) ->
    response_body(
        hb_maps:get(
            <<"peer-fresh-attestation">>, PeerAttestation, undefined, Opts),
        Opts).

request_admission(PeerURL, SelfURL, AdmissionNonce, Req, Opts) ->
    Body = maps:without(
        [<<"path">>, <<"device">>, <<"method">>, <<"peer-url">>,
         <<"self-url">>, <<"url">>, <<"peer-attestation">>],
        Req
    ),
    AdmitReq = Body#{
        <<"joiner-url">> => SelfURL,
        <<"admission-nonce">> => AdmissionNonce
    },
    try
        admission_response_body(
            lapee_http_json:post(
                PeerURL,
                <<"/~green-zone@1.0/admit">>,
                AdmitReq,
                Opts),
            Opts
        )
    catch
        throw:{green_zone_error, ErrorBody} ->
            throw({green_zone_error, ErrorBody});
        Class:Reason ->
            throw({green_zone_error, #{
                <<"error">> => <<"admission-request-failed">>,
                <<"class">> => hb_util:bin(Class),
                <<"details">> => hb_util:bin(io_lib:format("~p", [Reason]))
            }})
    end.

admission_response_body(#{<<"status">> := 200, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
admission_response_body(#{<<"status">> := Status, <<"body">> := Body}, _Opts)
        when is_integer(Status), Status >= 400, is_map(Body) ->
    throw({green_zone_error, Body});
admission_response_body(Other, Opts) ->
    response_body(Other, Opts).

assert_admission_body(Admission, _PeerURL, SelfURL, AdmissionNonce, Req, Opts) ->
    Self = strip_trailing_slash(SelfURL),
    Checks = [
        {field_eq, <<"type">>, <<"green-zone-admission">>},
        {field_eq, <<"template-matched">>, true},
        {field_eq, <<"joiner-url">>, Self},
        {field_eq, <<"admission-nonce">>, AdmissionNonce},
        {field_map, <<"validity">>},
        {field_map, <<"ring-scope">>},
        {field_map, <<"credential">>},
        {field_map, <<"encrypted-wallet">>},
        {field_map, <<"peer-attestation">>},
        {field_binary, <<"ring-address">>}
    ],
    lists:foreach(
        fun
            ({field_eq, Key, Expected}) ->
                Actual0 = hb_maps:get(Key, Admission, undefined, Opts),
                Actual =
                    case Key of
                        <<"joiner-url">> -> strip_trailing_slash(Actual0);
                        _ -> Actual0
                    end,
                case Actual =:= Expected of
                    true -> ok;
                    false -> bad_admission(Key)
                end;
            ({field_map, Key}) ->
                case hb_maps:get(Key, Admission, undefined, Opts) of
                    M when is_map(M) -> ok;
                    _ -> bad_admission(Key)
                end;
            ({field_binary, Key}) ->
                case hb_maps:get(Key, Admission, undefined, Opts) of
                    B when is_binary(B), byte_size(B) > 0 -> ok;
                    _ -> bad_admission(Key)
                end
        end,
        Checks),
    assert_admission_signature(Admission, Opts),
    assert_admission_validity(Admission, Opts),
    assert_expected_ring_address(Admission, Req, Opts),
    PeerAttestation = response_body(
        hb_maps:get(<<"peer-attestation">>, Admission, undefined, Opts),
        Opts),
    case strip_trailing_slash(
        hb_maps:get(<<"peer-url">>, PeerAttestation, undefined, Opts)) of
        Self -> ok;
        _ -> bad_admission(<<"peer-attestation.peer-url">>)
    end,
    RingAddress = hb_maps:get(<<"ring-address">>, Admission, undefined, Opts),
    RingScope = hb_maps:get(<<"ring-scope">>, Admission, #{}, Opts),
    case hb_maps:get(<<"ring-address">>, RingScope, undefined, Opts) of
        RingAddress -> ok;
        _ -> bad_admission(<<"ring-scope.ring-address">>)
    end.

bad_admission(Key) ->
    throw({green_zone_error, #{
        <<"error">> => <<"admission-invalid">>,
        <<"field">> => Key
    }}).

assert_admission_signature(Admission, Opts) ->
    RingAddress = hb_maps:get(<<"ring-address">>, Admission, undefined, Opts),
    Signers = hb_message:signers(Admission, Opts),
    case hb_message:verify(Admission, Signers, Opts) of
        true -> ok;
        false -> bad_admission(<<"commitments">>)
    end,
    case lists:member(RingAddress, Signers) of
        true -> ok;
        false -> bad_admission(<<"ring-address">>)
    end.

assert_admission_validity(Admission, Opts) ->
    Now = erlang:system_time(second),
    Skew = clock_skew_seconds(Opts),
    Validity = hb_maps:get(<<"validity">>, Admission, #{}, Opts),
    NotBefore = hb_maps:get(<<"not-before-unix">>, Validity, undefined, Opts),
    Expires = hb_maps:get(<<"expires-at-unix">>, Validity, undefined, Opts),
    case {NotBefore, Expires} of
        {NB, Ex} when is_integer(NB), is_integer(Ex),
                      NB =< Now + Skew, Ex + Skew >= Now ->
            ok;
        _ -> bad_admission(<<"validity">>)
    end.

assert_expected_ring_address(Admission, Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"ring-address">>, Req, undefined, Opts),
        hb_maps:get(<<"expected-ring-address">>, Req, undefined, Opts),
        hb_opts:get(<<"green-zone-ring-address">>, undefined, Opts)
    ]) of
        undefined -> bad_admission(<<"expected-ring-address">>);
        Expected ->
            case hb_maps:get(<<"ring-address">>, Admission, undefined, Opts) of
                Expected -> ok;
                _ -> bad_admission(<<"ring-address">>)
            end
    end.

activate_local_credential(Credential, Opts) ->
    case dev_tpm2:activate_credential_secret(Credential, Opts) of
        {ok, Secret} when is_binary(Secret) ->
            Secret;
        Other ->
            throw({green_zone_error, #{
                <<"error">> => <<"credential-activation-failed">>,
                <<"details">> => hb_util:bin(io_lib:format("~p", [Other]))
            }})
    end.

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body(#{<<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
response_body(Body, _Opts) ->
    Body.

decode_required(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:decode(B);
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"missing-field">>,
                <<"field">> => Key
            }})
    end.

safe_decode(B) when is_binary(B) ->
    try hb_util:decode(B) catch _:_ -> <<>> end;
safe_decode(_) ->
    <<>>.

encrypt_wallet(Wallet, AES) ->
    IV = crypto:strong_rand_bytes(12),
    Plain = ar_wallet:to_json(Wallet),
    AAD = <<"green-zone-wallet-v1">>,
    {Cipher, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm, AES, IV, Plain, AAD, true),
    #{
        <<"alg">> => <<"AES-256-GCM">>,
        <<"iv">> => hb_util:encode(IV),
        <<"tag">> => hb_util:encode(Tag),
        <<"ciphertext">> => hb_util:encode(Cipher)
    }.

decrypt_wallet(Enc, AES, Opts) when is_map(Enc) ->
    AAD = <<"green-zone-wallet-v1">>,
    Plain =
        crypto:crypto_one_time_aead(
            aes_256_gcm,
            AES,
            decode_required(<<"iv">>, Enc, Opts),
            decode_required(<<"ciphertext">>, Enc, Opts),
            AAD,
            decode_required(<<"tag">>, Enc, Opts),
            false
        ),
    case Plain of
        error ->
            throw({green_zone_error, #{
                <<"error">> => <<"wallet-decryption-failed">>
            }});
        _ -> ar_wallet:from_json(Plain)
    end;
decrypt_wallet(_, _AES, _Opts) ->
    throw({green_zone_error, #{<<"error">> => <<"bad-encrypted-wallet">>}}).

assert_wallet_matches_admission(Wallet, Admission, Opts) ->
    Expected = hb_maps:get(<<"ring-address">>, Admission, undefined, Opts),
    case wallet_address(Wallet) of
        Expected -> ok;
        Actual ->
            throw({green_zone_error, #{
                <<"error">> => <<"ring-wallet-address-mismatch">>,
                <<"expected">> => Expected,
                <<"actual">> => Actual
            }})
    end.

green_zone_signing_opts(Opts) ->
    case hb_opts:as(?DEFAULT_IDENTITY, Opts) of
        {ok, RingOpts} -> RingOpts;
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"green-zone-not-initialized">>
            }})
    end.

sign_payload(Req, Opts) ->
    case hb_maps:get(<<"body">>, Req, undefined, Opts) of
        undefined ->
            maps:without([<<"path">>, <<"device">>, <<"method">>], Req);
        Body -> Body
    end.

wallet_address(Wallet) ->
    hb_util:human_id(ar_wallet:to_address(Wallet)).

match_template(Template, Candidate, Opts) when is_map(Template),
                                              is_map(Candidate) ->
    lists:all(
        fun({Key, Expected}) ->
            case hb_maps:get(Key, Candidate, undefined, Opts) of
                undefined -> false;
                Actual -> match_template(Expected, Actual, Opts)
            end
        end,
        hb_maps:to_list(Template, Opts)
    );
match_template(<<"$any">>, undefined, _Opts) -> false;
match_template(<<"$any">>, _Candidate, _Opts) -> true;
match_template(Expected, Expected, _Opts) -> true;
match_template(_Expected, _Candidate, _Opts) -> false.

clean_template(Template, Opts) when is_map(Template) ->
    clean_template_map(Template, true, Opts);
clean_template(Template, _Opts) ->
    Template.

clean_template_map(Template, StripMeta, Opts) ->
    maps:from_list(
        [
            {Key, clean_template_value(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Template, Opts),
            not (StripMeta andalso lists:member(Key, ?TEMPLATE_META_KEYS))
        ]).

clean_template_value(Value, Opts) when is_map(Value) ->
    clean_template_map(Value, false, Opts);
clean_template_value(Value, _Opts) ->
    Value.

ensure_nonempty_template(Template) when is_map(Template),
                                       map_size(Template) > 0 ->
    ok;
ensure_nonempty_template(_Template) ->
    throw({green_zone_error, #{<<"error">> => <<"empty-template">>}}).

mismatch_path(Template, Candidate, Opts) ->
    case mismatch_path(Template, Candidate, [], Opts) of
        [] -> <<"/">>;
        Path -> iolist_to_binary(["/", lists:join("/", lists:reverse(Path))])
    end.

mismatch_path(Template, Candidate, Path, Opts) when is_map(Template),
                                                   is_map(Candidate) ->
    case lists:dropwhile(
        fun({Key, Expected}) ->
            case hb_maps:get(Key, Candidate, undefined, Opts) of
                undefined -> false;
                Actual -> match_template(Expected, Actual, Opts)
            end
        end,
        hb_maps:to_list(Template, Opts))
    of
        [] -> [];
        [{Key, _Expected} | _] ->
            case hb_maps:get(Key, Candidate, undefined, Opts) of
                undefined -> [Key | Path];
                Actual ->
                    mismatch_path(
                        hb_maps:get(Key, Template, undefined, Opts),
                        Actual,
                        [Key | Path],
                        Opts)
            end
    end;
mismatch_path(_Template, _Candidate, Path, _Opts) ->
    Path.

-ifdef(TEST).

deep_subset_match_test() ->
    Template = #{
        <<"system">> => #{
            <<"cpu">> => #{<<"vendor">> => <<"GenuineIntel">>},
            <<"secure-boot">> => <<"enabled">>
        },
        <<"tpm">> => #{<<"ek-cert-source">> => <<"nvram">>}
    },
    Candidate = #{
        <<"system">> => #{
            <<"cpu">> => #{
                <<"vendor">> => <<"GenuineIntel">>,
                <<"model">> => <<"Framework">>
            },
            <<"secure-boot">> => <<"enabled">>
        },
        <<"tpm">> => #{<<"ek-cert-source">> => <<"nvram">>},
        <<"extra">> => true
    },
    ?assert(match_template(Template, Candidate, #{})),
    ?assertNot(match_template(
        Template,
        Candidate#{<<"system">> => #{<<"secure-boot">> => <<"disabled">>}},
        #{}
    )).

wildcard_match_test() ->
    ?assert(match_template(
        #{<<"node">> => #{<<"address">> => <<"$any">>}},
        #{<<"node">> => #{<<"address">> => <<"abc">>}},
        #{}
    )),
    ?assertNot(match_template(
        #{<<"node">> => #{<<"address">> => <<"$any">>}},
        #{<<"node">> => #{}},
        #{}
    )).

template_envelope_metadata_is_not_policy_test() ->
    Template = clean_template(
        #{
            <<"commitments">> => #{<<"ignored">> => true},
            <<"ao-types">> => #{<<"ignored">> => true},
            <<"system">> => #{
                <<"kernel">> => #{
                    <<"cmdline">> => <<"good">>
                }
            }
        },
        #{}),
    Candidate = #{
        <<"system">> => #{
            <<"kernel">> => #{<<"cmdline">> => <<"good">>}
        }
    },
    ?assertEqual(
        #{<<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}},
        Template),
    ?assert(match_template(Template, Candidate, #{})).

mismatch_path_test() ->
    Template = #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    },
    Candidate = #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"bad">>}}
    },
    ?assertEqual(
        <<"/system/kernel/cmdline">>,
        mismatch_path(Template, Candidate, #{})).

wallet_encryption_roundtrip_test() ->
    Wallet = ar_wallet:new(),
    AES = crypto:strong_rand_bytes(32),
    Enc = encrypt_wallet(Wallet, AES),
    Dec = decrypt_wallet(Enc, AES, #{}),
    ?assertEqual(wallet_address(Wallet), wallet_address(Dec)).

admission_response_body_preserves_policy_rejection_test() ->
    Rejection = #{
        <<"status">> => 400,
        <<"body">> => #{<<"error">> => <<"template-mismatch">>}
    },
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"template-mismatch">>}},
        admission_response_body(Rejection, #{})).

trusted_peer_attestation_can_be_reused_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}},
            <<"tpm">> => #{<<"ek-cert-source">> => #{<<"kind">> => <<"tpm-nv">>}}
        }
    }, RingScope),
    Req = #{
        <<"peer-attestation">> => Attestation
    },
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    {<<"http://peer.example">>, TrustedAttestation, Publisher} =
        peer_attestation_from_req(Req, RingScope, Opts),
    ?assert(match_template(
        #{<<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}},
        peer_boot_attestation_body(TrustedAttestation, Opts),
        Opts)).

untrusted_peer_attestation_publisher_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    RingScope = test_ring_scope(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope),
    Req = #{
        <<"peer-attestation">> => Attestation
    },
    Opts = #{<<"green-zone-trusted-publishers">> => [<<"not-the-signer">>]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-publisher-untrusted">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

request_supplied_publisher_trust_is_ignored_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope),
    Req = #{
        <<"peer-attestation">> => Attestation,
        <<"trusted-publisher">> => Publisher
    },
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-publisher-untrusted">>
        }},
        peer_attestation_from_req(Req, RingScope, #{})).

stored_peer_attestation_url_mismatch_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope),
    Req = #{
        <<"peer-attestation">> => Attestation,
        <<"joiner-url">> => <<"http://other.example">>
    },
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-url-mismatch">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

stored_peer_attestation_scope_mismatch_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    OtherScope = RingScope#{<<"template-id">> => <<"other-template">>},
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, OtherScope),
    Req = #{<<"peer-attestation">> => Attestation},
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-invalid">>,
            <<"field">> := <<"peer-scope.consumer-scope">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

stored_peer_attestation_peer_scope_url_mismatch_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Attestation0 = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope),
    Scope0 = hb_maps:get(<<"peer-scope">>, Attestation0, #{}, #{}),
    Attestation = hb_message:commit(
        (unsigned_message(Attestation0))#{
            <<"peer-scope">> =>
                Scope0#{<<"peer-url">> => <<"http://other.example">>}
        },
        #{<<"priv-wallet">> => PublisherWallet}),
    Req = #{<<"peer-attestation">> => Attestation},
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-invalid">>,
            <<"field">> := <<"peer-scope.peer-url">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

stored_peer_attestation_embedded_id_mismatch_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Attestation0 = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope),
    Scope0 = hb_maps:get(<<"peer-scope">>, Attestation0, #{}, #{}),
    Attestation = hb_message:commit(
        (unsigned_message(Attestation0))#{
            <<"peer-scope">> =>
                Scope0#{<<"boot-attestation-id">> => <<"wrong-id">>}
        },
        #{<<"priv-wallet">> => PublisherWallet}),
    Req = #{<<"peer-attestation">> => Attestation},
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-invalid">>,
            <<"field">> := <<"peer-scope.attestation-id">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

green_zone_policy_uses_fresh_attestation_test() ->
    PublisherWallet = ar_wallet:new(),
    RingScope = test_ring_scope(),
    Boot = #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"bad">>}}
        }
    },
    Fresh = #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
        }
    },
    Attestation = signed_peer_attestation(
        PublisherWallet, Boot, RingScope, erlang:system_time(second), Fresh),
    Template = #{<<"system">> => #{
        <<"kernel">> => #{<<"cmdline">> => <<"good">>}}},
    ?assert(match_template(
        Template, peer_policy_attestation_body(Attestation, #{}), #{})),
    ?assertNot(match_template(
        Template, peer_boot_attestation_body(Attestation, #{}), #{})).

expired_peer_attestation_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    RingScope = test_ring_scope(),
    Old = erlang:system_time(second) - 7200,
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingScope, Old),
    Req = #{<<"peer-attestation">> => Attestation},
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-invalid">>,
            <<"field">> := <<"issued-at-unix">>
        }},
        peer_attestation_from_req(Req, RingScope, Opts)).

admission_body_requires_joiner_binding_test() ->
    Wallet = ar_wallet:new(),
    Admission = (test_admission(Wallet))#{
        <<"joiner-url">> => <<"http://other.example">>
    },
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"admission-invalid">>}},
        assert_admission_body(
            Admission,
            <<"http://peer.example">>,
            <<"http://self.example">>,
            <<"nonce">>,
            #{},
            #{})).

admission_body_requires_expected_ring_test() ->
    Wallet = ar_wallet:new(),
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"admission-invalid">>,
            <<"field">> := <<"expected-ring-address">>
        }},
        assert_admission_body(
            test_admission(Wallet),
            <<"http://peer.example">>,
            <<"http://self.example">>,
            <<"nonce">>,
            #{},
            #{})).

admission_body_accepts_expected_ring_test() ->
    Wallet = ar_wallet:new(),
    RingAddress = wallet_address(Wallet),
    ?assertEqual(ok,
        assert_admission_body(
            test_admission(Wallet),
            <<"http://peer.example">>,
            <<"http://self.example">>,
            <<"nonce">>,
            #{<<"expected-ring-address">> => RingAddress},
            #{})).

ring_wallet_address_mismatch_rejected_test() ->
    Wallet = ar_wallet:new(),
    Admission = test_admission(ar_wallet:new()),
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"ring-wallet-address-mismatch">>
        }},
        assert_wallet_matches_admission(Wallet, Admission, #{})).

sign_without_ring_is_policy_error_test() ->
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"green-zone-not-initialized">>}},
        green_zone_signing_opts(#{})).

nested_commitments_template_is_policy_test() ->
    Template = clean_template(#{
        <<"system">> => #{<<"commitments">> => <<"required">>},
        <<"commitments">> => #{<<"ignored-envelope-metadata">> => true}
    }, #{}),
    ?assertEqual(
        #{<<"system">> => #{<<"commitments">> => <<"required">>}},
        Template),
    ?assert(match_template(
        Template,
        #{<<"system">> => #{<<"commitments">> => <<"required">>}},
        #{})),
    ?assertNot(match_template(
        Template,
        #{<<"system">> => #{}},
        #{})).

metadata_only_template_rejected_test() ->
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"empty-template">>}},
        install_ring(
            #{<<"commitments">> => #{<<"only-metadata">> => true}},
            crypto:strong_rand_bytes(32),
            ar_wallet:new(),
            [],
            #{})).

test_admission(Wallet) ->
    RingScope = test_ring_scope(Wallet),
    hb_message:commit(#{
        <<"type">> => <<"green-zone-admission">>,
        <<"version">> => <<"1.0">>,
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"validity">> => admission_validity(#{}, #{}),
        <<"admission-nonce">> => <<"nonce">>,
        <<"ring-scope">> => RingScope,
        <<"template-matched">> => true,
        <<"joiner-url">> => <<"http://self.example">>,
        <<"credential">> => #{},
        <<"encrypted-wallet">> => #{},
        <<"peer-attestation">> => #{<<"peer-url">> => <<"http://self.example">>},
        <<"ring-address">> => wallet_address(Wallet)
    }, #{<<"priv-wallet">> => Wallet}).

signed_peer_attestation(Wallet, BootAttestation, RingScope) ->
    signed_peer_attestation(
        Wallet, BootAttestation, RingScope, erlang:system_time(second)).

signed_peer_attestation(Wallet, BootAttestation, RingScope, Now) ->
    signed_peer_attestation(
        Wallet, BootAttestation, RingScope, Now, test_fresh_attestation()).

signed_peer_attestation(Wallet, BootAttestation, RingScope, Now,
                        FreshAttestation) ->
    Subject = test_credential_subject(),
    BootBody = response_body(BootAttestation, #{}),
    FreshBody = response_body(FreshAttestation, #{}),
    PeerURL = <<"http://peer.example">>,
    hb_message:commit(
        #{
            <<"type">> => <<"lapee-peer-attestation">>,
            <<"version">> => <<"1.0">>,
            <<"issued-at-unix">> => Now,
            <<"validity">> => #{<<"not-before-unix">> => Now},
            <<"peer-url">> => PeerURL,
            <<"peer-scope">> => #{
                <<"peer-url">> => PeerURL,
                <<"boot-attestation-id">> =>
                    attestation_id(BootBody, #{}),
                <<"fresh-attestation-id">> =>
                    attestation_id(FreshBody, #{}),
                <<"consumer-scope">> => RingScope,
                <<"ek-public-sha256">> =>
                    encoded_field_sha256(<<"ek-public">>, Subject, #{}),
                <<"ak-name-sha256">> =>
                    encoded_field_sha256(<<"ak-name">>, Subject, #{})
            },
            <<"peer-boot-attestation">> => BootAttestation,
            <<"peer-fresh-attestation">> => FreshAttestation,
            <<"peer-credential-subject">> => Subject,
            <<"boot-verification">> => #{<<"verified">> => true},
            <<"verification">> => #{<<"verified">> => true},
            <<"freshness">> => #{<<"verified">> => true},
            <<"credential-activation">> => #{<<"verified">> => true}
        },
        #{<<"priv-wallet">> => Wallet}).

test_ring_scope() ->
    #{
        <<"type">> => <<"green-zone-ring-scope">>,
        <<"version">> => <<"1.0">>,
        <<"ring-address">> => <<"ring-address">>,
        <<"template-id">> => <<"template-id">>
    }.

test_ring_scope(Wallet) ->
    (test_ring_scope())#{<<"ring-address">> => wallet_address(Wallet)}.

test_credential_subject() ->
    #{
        <<"ek-public">> => hb_util:encode(<<"ek-public">>),
        <<"ak-name">> => hb_util:encode(<<"ak-name">>)
    }.

test_fresh_attestation() ->
    #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
        }
    }.

unsigned_message(Msg) ->
    maps:without([<<"commitments">>, <<"ao-types">>], Msg).

-endif.
