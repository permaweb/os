%%% @doc TPM-backed green-zone rings.
%%%
%%% A green-zone is a shared signing identity admitted by evidence rather than
%%% by operator fiat. The device is intentionally small:
%%%
%%% * `init' creates or loads a ring wallet, a 256-bit AES ring secret, and a
%%%   deeply-nested template.
%%% * `admit' verifies a candidate peer through `~tpm@2.0a/verify-peer',
%%%   matches the candidate boot-attestation against the template, then wraps
%%%   the ring AES secret to the peer's TPM using MakeCredential. The ring
%%%   wallet is encrypted under that AES key.
%%% * `join' asks an existing member for admission, unwraps the AES key through
%%%   `~tpm@2.0a/activate-credential', decrypts the wallet, and installs it as
%%%   the local `green-zone' identity.
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
        {JoinerURL, PeerAttestation, Publisher} =
            peer_attestation_from_req(Req, Opts),
        Boot = peer_boot_attestation_body(PeerAttestation, Opts),
        case match_template(Template, Boot, Opts) of
            true -> ok;
            false ->
                throw({green_zone_error, #{
                    <<"error">> => <<"template-mismatch">>,
                    <<"mismatch-path">> =>
                        mismatch_path(Template, Boot, Opts),
                    <<"joiner-url">> => JoinerURL
                }})
        end,
        Subject = hb_maps:get(
            <<"peer-credential-subject">>, PeerAttestation, undefined, Opts),
        Credential = dev_tpm2:make_credential_for_subject(Subject, AES),
        #{
            <<"type">> => <<"green-zone-admission">>,
            <<"version">> => <<"1.0">>,
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"joiner-url">> => JoinerURL,
            <<"template">> => Template,
            <<"template-matched">> => true,
            <<"peer-attestation-publisher">> => Publisher,
            <<"peer-attestation">> => PeerAttestation,
            <<"credential">> => Credential,
            <<"encrypted-wallet">> => encrypt_wallet(Wallet, AES),
            <<"ring-address">> => wallet_address(Wallet),
            <<"trusted-publishers">> => trusted_publishers(Opts)
        }
    end, Opts).

join(_Base, Req, Opts) ->
    with_result(fun() ->
        PeerURL = required_peer(Req, Opts),
        SelfURL = required_self(Req, Opts),
        Admission = request_admission(PeerURL, SelfURL, Req, Opts),
        Credential = hb_maps:get(<<"credential">>, Admission, undefined, Opts),
        Activation = activate_local_credential(Credential, Opts),
        AES = decode_required(<<"credential-secret">>, Activation, Opts),
        Wallet = decrypt_wallet(
            hb_maps:get(<<"encrypted-wallet">>, Admission, undefined, Opts),
            AES,
            Opts
        ),
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
        {ok, RingOpts} = hb_opts:as(?DEFAULT_IDENTITY, Opts),
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
    Address =
        case Wallet of
            undefined -> undefined;
            _ -> wallet_address(Wallet)
        end,
    #{
        <<"type">> => <<"green-zone-status">>,
        <<"version">> => <<"1.0">>,
        <<"initialized">> =>
            hb_opts:get(<<"green-zone-initialized">>, false, Opts),
        <<"identity">> => ?DEFAULT_IDENTITY,
        <<"ring-address">> => Address,
        <<"trusted-publishers">> => trusted_publishers(Opts),
        <<"template">> =>
            hb_opts:get(<<"green-zone-template">>, #{}, Opts)
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

verify_joiner(JoinerURL, Req, Opts) ->
    VerifyReq = Req#{<<"url">> => JoinerURL},
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

peer_attestation_from_req(Req, Opts) ->
    case hb_maps:get(<<"peer-attestation">>, Req, undefined, Opts) of
        PeerAttestation0 when is_map(PeerAttestation0) ->
            PeerAttestation = response_body(PeerAttestation0, Opts),
            Publisher = require_trusted_publisher(PeerAttestation, Req, Opts),
            assert_peer_attestation_body(PeerAttestation, Opts),
            JoinerURL = first_defined([
                hb_maps:get(<<"joiner-url">>, Req, undefined, Opts),
                hb_maps:get(<<"peer-url">>, PeerAttestation, undefined, Opts)
            ]),
            case JoinerURL of
                undefined ->
                    throw({green_zone_error, #{
                        <<"error">> => <<"missing-peer-attestation-url">>
                    }});
                URL ->
                    {strip_trailing_slash(URL), PeerAttestation, Publisher}
            end;
        _ ->
            JoinerURL = required_url(Req, Opts),
            {JoinerURL, verify_joiner(JoinerURL, Req, Opts), null}
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

assert_peer_attestation_body(PeerAttestation, Opts) ->
    Required = [
        {field_eq, <<"type">>, <<"lapee-peer-attestation">>},
        {nested_true, <<"verification">>, <<"verified">>},
        {nested_true, <<"credential-activation">>, <<"verified">>},
        {field_map, <<"peer-credential-subject">>},
        {field_map, <<"peer-boot-attestation">>}
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
            ({field_map, Key}) ->
                case hb_maps:get(Key, PeerAttestation, undefined, Opts) of
                    M when is_map(M) -> ok;
                    _ -> bad_peer_attestation(Key)
                end
        end,
        Required).

bad_peer_attestation(Key) ->
    throw({green_zone_error, #{
        <<"error">> => <<"peer-attestation-invalid">>,
        <<"field">> => Key
    }}).

peer_boot_attestation_body(PeerAttestation, Opts) ->
    response_body(
        hb_maps:get(
            <<"peer-boot-attestation">>, PeerAttestation, undefined, Opts),
        Opts).

request_admission(PeerURL, SelfURL, Req, Opts) ->
    Body = maps:without(
        [<<"path">>, <<"device">>, <<"method">>, <<"peer-url">>,
         <<"self-url">>, <<"url">>, <<"peer-attestation">>],
        Req
    ),
    AdmitReq = Body#{<<"joiner-url">> => SelfURL},
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

activate_local_credential(Credential, Opts) ->
    case dev_tpm2:activate_credential(#{}, Credential, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            response_body(Body, Opts);
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
    maps:from_list(
        [
            {Key, clean_template(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Template, Opts),
            not lists:member(Key, ?TEMPLATE_META_KEYS)
        ]);
clean_template(Template, _Opts) ->
    Template.

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

template_metadata_is_not_policy_test() ->
    Template = clean_template(
        #{
            <<"commitments">> => #{<<"ignored">> => true},
            <<"system">> => #{
                <<"ao-types">> => #{<<"ignored">> => true},
                <<"kernel">> => #{
                    <<"cmdline">> => <<"good">>,
                    <<"commitments">> => #{<<"ignored">> => true}
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
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}},
            <<"tpm">> => #{<<"ek-cert-source">> => #{<<"kind">> => <<"tpm-nv">>}}
        }
    }),
    Req = #{
        <<"peer-attestation">> => Attestation
    },
    Opts = #{<<"green-zone-trusted-publishers">> => [Publisher]},
    {<<"http://peer.example">>, TrustedAttestation, Publisher} =
        peer_attestation_from_req(Req, Opts),
    ?assert(match_template(
        #{<<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}},
        peer_boot_attestation_body(TrustedAttestation, Opts),
        Opts)).

untrusted_peer_attestation_publisher_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }),
    Req = #{
        <<"peer-attestation">> => Attestation
    },
    Opts = #{<<"green-zone-trusted-publishers">> => [<<"not-the-signer">>]},
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-publisher-untrusted">>
        }},
        peer_attestation_from_req(Req, Opts)).

request_supplied_publisher_trust_is_ignored_test() ->
    PublisherWallet = ar_wallet:new(),
    Publisher = wallet_address(PublisherWallet),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }),
    Req = #{
        <<"peer-attestation">> => Attestation,
        <<"trusted-publisher">> => Publisher
    },
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-publisher-untrusted">>
        }},
        peer_attestation_from_req(Req, #{})).

signed_peer_attestation(Wallet, BootAttestation) ->
    hb_message:commit(
        #{
            <<"type">> => <<"lapee-peer-attestation">>,
            <<"version">> => <<"1.0">>,
            <<"peer-url">> => <<"http://peer.example">>,
            <<"peer-boot-attestation">> => BootAttestation,
            <<"peer-credential-subject">> => #{<<"ak-name">> => <<"ak">>},
            <<"verification">> => #{<<"verified">> => true},
            <<"credential-activation">> => #{<<"verified">> => true}
        },
        #{<<"priv-wallet">> => Wallet}).

-endif.
