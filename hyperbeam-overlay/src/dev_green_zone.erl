%%% @doc TPM-backed green-zone rings.
%%%
%%% A green-zone is a shared signing identity admitted by evidence rather than
%%% by operator fiat. The device is intentionally small:
%%%
%%% * `init' creates a named ring wallet, a 256-bit AES ring secret, and a
%%%   deeply-nested template after proving that the initializing node matches
%%%   the template.
%%% * `admit' verifies a candidate peer through `~tpm@2.0a/verify-peer',
%%%   matches the candidate's boot attestation against the template, then
%%%   wraps the ring AES secret to the peer's TPM using MakeCredential. The
%%%   fresh attestation and ActivateCredential proof establish liveness and
%%%   possession of the AK named in that boot attestation. The ring wallet is
%%%   encrypted under the wrapped AES key.
%%% * `join' asks an existing member for a named ring admission, checks the
%%%   envelope, unwraps the AES key through `~tpm@2.0a/activate-credential',
%%%   decrypts the wallet, verifies its advertised ring address, and installs
%%%   it as a local green-zone identity.
%%% * `sign' signs an arbitrary message with a named shared ring wallet.
%%%
%%% Ring templates are normal HyperBEAM message match templates: AO metadata
%%% keys are ignored, template keys must be present in the candidate, non-map
%%% values match exactly, and the atom `_' is a wildcard. JSON callers can send
%%% the string `"_"', which is normalized to that atom before matching.
%%%
%%% The admission protocol is:
%%%
%%% 1. The initializer calls `init' with a `name' and `template'. The node
%%%    reads its own cached `~tpm@2.0a/boot-attestation', verifies that the
%%%    template matches it, then generates the ring AES key and wallet locally.
%%%    Callers cannot provide those secrets.
%%% 2. A joiner calls its local `join' with the green-zone `name', a member
%%%    `peer-url', its own `self-url', and the expected `ring-address'.
%%% 3. The joiner sends an admission request to the peer. The peer calls
%%%    `~tpm@2.0a/verify-peer' for the joiner's URL. That TPM device verifies
%%%    the joiner's boot attestation, verifies a fresh nonce-bound quote, checks
%%%    the EK/AK/credential subject agree, and performs MakeCredential /
%%%    ActivateCredential to prove the joiner controls the AK inside that TPM.
%%%    It returns a signed `green-zone-peer-attestation'.
%%% 4. The peer matches the ring template against the boot attestation inside
%%%    that peer attestation. If it matches, the peer wraps the ring AES key to
%%%    the joiner's TPM and encrypts the ring wallet under that AES key.
%%% 5. The peer returns a `green-zone-admission'. The top-level HTTP/JSON
%%%    envelope may acquire transport commitments, so the durable ring
%%%    signature is over the nested `authorization' message. That authorization
%%%    binds the scalar admission fields and stable IDs of the nested payloads:
%%%    validity, ring-reference, green-zone definition, template,
%%%    peer-attestation, credential, and encrypted-wallet.
%%% 6. The joiner verifies the ring-signed authorization, checks every payload
%%%    ID, activates the TPM credential locally, decrypts the wallet, confirms
%%%    the wallet address equals the expected ring address, and installs the
%%%    identity as `green-zone/<name>'.
-module(dev_green_zone).
-export([info/1, info/3, init/3, status/3, admit/3, join/3, sign/3,
         match/3]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(IDENTITY_PREFIX, <<"green-zone/">>).
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
                <<"HyperBEAM message primary match; non-map values exact; "
                  "'_' wildcard">>,
            <<"peer-attestation-trust">> =>
                <<"Green-zone admission verifies live peers through "
                  "~tpm@2.0a/verify-peer. Reusable/transitive peer-attestation "
                  "publisher trust is a TPM-device concern, not ring state.">>
        }
    }}.

init(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        Template = clean_template(
            hb_maps:get(<<"template">>, Req, #{}, Opts),
            Opts),
        reject_supplied_secret_material(Req, Opts),
        Self = self_attestation_body(Opts),
        ok = assert_template_match(Template, Self, <<"self">>, Opts),
        AES = crypto:strong_rand_bytes(32),
        Wallet = ar_wallet:new(),
        Members = add_member_to_members(
            #{},
            hb_maps:get(<<"self-url">>, Req, undefined, Opts),
            Self,
            <<"initializer">>,
            Opts
        ),
        NewOpts = install_ring(Name, Template, AES, Wallet, Members, Opts),
        hb_http_server:set_opts(NewOpts),
        status_body(Name, NewOpts)
    end, Opts).

status(_Base, Req, Opts) ->
    with_result(fun() ->
        case optional_name(Req, Opts) of
            undefined -> all_status_body(Opts);
            Name -> status_body(Name, Opts)
        end
    end, Opts).

match(_Base, Req, Opts) ->
    with_result(fun() ->
        Template = clean_template(
            hb_maps:get(<<"template">>, Req, #{}, Opts),
            Opts),
        Candidate = hb_maps:get(<<"candidate">>, Req, undefined, Opts),
        #{
            <<"matched">> => match_template(Template, Candidate, Opts),
            <<"template">> => Template
        }
    end, Opts).

admit(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        {AES, Wallet, Zone} = require_ring(Name, Opts),
        Template = hb_maps:get(<<"template">>, Zone, #{}, Opts),
        RingReference = ring_reference(Name, Template, Wallet, Opts),
        {JoinerURL, PeerAttestation} =
            peer_attestation_from_req(Req, RingReference, Opts),
        PolicyAttestation = peer_boot_attestation_body(PeerAttestation, Opts),
        ok = assert_template_match(Template, PolicyAttestation, JoinerURL, Opts),
        Subject = hb_maps:get(
            <<"peer-credential-subject">>, PeerAttestation, undefined, Opts),
        Credential = commit_unsigned_tree(
            dev_tpm2:make_credential_for_subject(Subject, AES),
            Opts),
        EncryptedWallet = commit_unsigned_tree(encrypt_wallet(Wallet, AES), Opts),
        Members = add_member_to_members(
            hb_maps:get(<<"members">>, Zone, #{}, Opts),
            JoinerURL,
            PolicyAttestation,
            <<"member">>,
            Opts
        ),
        NewOpts = install_ring(Name, Template, AES, Wallet, Members, Opts),
        hb_http_server:set_opts(NewOpts),
        Definition = commit_unsigned_tree(
            zone_definition(Name, Template, Wallet, Members, Opts),
            Opts),
        Validity = commit_unsigned_tree(admission_validity(Opts), Opts),
        Admission0 = #{
            <<"type">> => <<"green-zone-admission">>,
            <<"version">> => <<"1.0">>,
            <<"name">> => Name,
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"validity">> => Validity,
            <<"admission-nonce">> =>
                hb_maps:get(<<"admission-nonce">>, Req, null, Opts),
            <<"ring-reference">> => commit_unsigned_tree(RingReference, Opts),
            <<"green-zone">> => Definition,
            <<"joiner-url">> => JoinerURL,
            <<"template">> => commit_unsigned_tree(Template, Opts),
            <<"peer-attestation">> => PeerAttestation,
            <<"credential">> => Credential,
            <<"encrypted-wallet">> => EncryptedWallet,
            <<"ring-address">> => wallet_address(Wallet)
        },
        Admission0#{
            <<"authorization">> =>
                admission_authorization(Admission0, Wallet, Opts)
        }
    end, Opts).

join(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        PeerURL = required_peer(Req, Opts),
        SelfURL = required_self(Req, Opts),
        AdmissionNonce = hb_util:encode(crypto:strong_rand_bytes(32)),
        Admission =
            request_admission(PeerURL, SelfURL, AdmissionNonce, Req, Opts),
        assert_admission_body(
            Admission, SelfURL, AdmissionNonce, Req, Opts),
        Credential = hb_maps:get(<<"credential">>, Admission, undefined, Opts),
        AES = activate_local_credential(Credential, Opts),
        Wallet = decrypt_wallet(
            hb_maps:get(<<"encrypted-wallet">>, Admission, undefined, Opts),
            AES,
            Opts
        ),
        assert_wallet_matches_admission(Wallet, Admission, Opts),
        Template = hb_maps:get(<<"template">>, Admission, #{}, Opts),
        Definition = hb_maps:get(<<"green-zone">>, Admission, #{}, Opts),
        Members = hb_maps:get(<<"members">>, Definition, #{}, Opts),
        NewMembers = add_member_to_members(
            Members, SelfURL, peer_boot_attestation_body(
                response_body(
                    hb_maps:get(<<"peer-attestation">>, Admission, #{}, Opts),
                    Opts),
                Opts),
            <<"member">>,
            Opts
        ),
        NewOpts = install_ring(Name, Template, AES, Wallet, NewMembers, Opts),
        hb_http_server:set_opts(NewOpts),
        status_body(Name, NewOpts)
    end, Opts).

sign(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        Payload = sign_payload(Req, Opts),
        hb_message:commit(Payload, green_zone_signing_opts(Name, Opts))
    end, Opts).

with_result(Fun, Opts) ->
    try
        ResultBody = ensure_committed(Fun(), Opts),
        {ok, #{<<"status">> => 200, <<"body">> => ResultBody}}
    catch
        throw:{green_zone_error, ErrorBody} ->
            {ok, #{<<"status">> => 400, <<"body">> => ErrorBody}};
        _:_ ->
            {ok, #{
                <<"status">> => 500,
                <<"body">> => #{
                    <<"error">> => <<"green-zone-failed">>
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

commit_unsigned_tree(Msg, Opts) when is_map(Msg) ->
    case hb_message:signers(Msg, Opts) of
        [] ->
            hb_message:commit(
                maps:map(
                    fun(_Key, Value) -> commit_unsigned_tree(Value, Opts) end,
                    Msg
                ),
                Opts
            );
        _ -> Msg
    end;
commit_unsigned_tree(List, Opts) when is_list(List) ->
    [commit_unsigned_tree(Value, Opts) || Value <- List];
commit_unsigned_tree(Value, _Opts) ->
    Value.

admission_authorization(Admission, Wallet, Opts) ->
    hb_message:commit(
        maps:merge(#{
            <<"type">> => <<"green-zone-admission-authorization">>,
            <<"version">> => <<"1.0">>,
            <<"template-matched">> => <<"true">>
        }, maps:from_list(
            [
                {Field, hb_maps:get(Field, Admission, undefined, Opts)}
             || Field <- authorization_scalar_fields()
            ] ++
            [
                {AuthKey, stable_message_id(
                    hb_maps:get(AdmissionKey, Admission, #{}, Opts), Opts)}
             || {AuthKey, AdmissionKey} <- authorization_id_fields()
            ])),
        #{<<"priv-wallet">> => Wallet}
    ).

authorization_scalar_fields() ->
    [
        <<"name">>,
        <<"issued-at-unix">>,
        <<"admission-nonce">>,
        <<"joiner-url">>,
        <<"ring-address">>
    ].

authorization_id_fields() ->
    [
        {<<"validity-id">>, <<"validity">>},
        {<<"ring-reference-id">>, <<"ring-reference">>},
        {<<"green-zone-id">>, <<"green-zone">>},
        {<<"template-id">>, <<"template">>},
        {<<"peer-attestation-id">>, <<"peer-attestation">>},
        {<<"credential-id">>, <<"credential">>},
        {<<"encrypted-wallet-id">>, <<"encrypted-wallet">>}
    ].

stable_message_id(Msg, Opts) when is_map(Msg) ->
    Body = response_body(Msg, Opts),
    case lists:sort(unsigned_commitment_ids(Body, Opts)) of
        [ID | _] -> ID;
        [] -> stable_uncommitted_id(Body)
    end;
stable_message_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

stable_uncommitted_id(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(Msg, #{}),
        uncommitted,
        #{}
    ).

unsigned_commitment_ids(Msg, Opts) when is_map(Msg) ->
    Commitments = hb_maps:get(<<"commitments">>, Msg, #{}, Opts),
    [
        ID
     || {ID, Commitment} <- hb_maps:to_list(Commitments, Opts),
        hb_maps:get(<<"type">>, Commitment, undefined, Opts) =:=
            <<"hmac-sha256">>,
        hb_maps:get(<<"committer">>, Commitment, undefined, Opts) =:=
            undefined
    ];
unsigned_commitment_ids(_Msg, _Opts) ->
    [].

reject_supplied_secret_material(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"aes-key">>, Req, undefined, Opts),
        hb_maps:get(<<"wallet">>, Req, undefined, Opts),
        hb_maps:get(<<"priv-green-zone-aes">>, Req, undefined, Opts),
        hb_maps:get(<<"priv-green-zone-wallet">>, Req, undefined, Opts)
    ]) of
        undefined -> ok;
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"secret-material-forbidden">>
            }})
    end.

install_ring(Name, Template0, AES, Wallet, Members, Opts) ->
    Template = clean_template(Template0, Opts),
    ok = ensure_nonempty_template(Template),
    Identities = hb_opts:get(identities, #{}, Opts),
    GreenZones = hb_opts:get(<<"green-zones">>, #{}, Opts),
    PrivGreenZones = hb_opts:get(<<"priv-green-zones">>, #{}, Opts),
    Definition = zone_definition(Name, Template, Wallet, Members, Opts),
    Identity = zone_identity(Name),
    Opts#{
        <<"green-zones">> => GreenZones#{Name => Definition},
        <<"priv-green-zones">> => PrivGreenZones#{
            Name => #{
                <<"aes">> => AES,
                <<"wallet">> => Wallet
            }
        },
        <<"identities">> => Identities#{
            Identity => #{<<"priv-wallet">> => Wallet}
        }
    }.

require_ring(Name, Opts) ->
    Priv = hb_opts:get(<<"priv-green-zones">>, #{}, Opts),
    Zones = hb_opts:get(<<"green-zones">>, #{}, Opts),
    case {hb_maps:get(Name, Priv, undefined, Opts),
          hb_maps:get(Name, Zones, undefined, Opts)} of
        {#{<<"aes">> := AES, <<"wallet">> := Wallet}, Zone}
                when is_binary(AES), tuple_size(Wallet) > 0, is_map(Zone) ->
            {AES, Wallet, Zone};
        _ -> green_zone_not_initialized(Name)
    end.

green_zone_not_initialized(Name) ->
    throw({green_zone_error, #{
        <<"error">> => <<"green-zone-not-initialized">>,
        <<"name">> => Name
    }}).

all_status_body(Opts) ->
    Zones = hb_opts:get(<<"green-zones">>, #{}, Opts),
    #{
        <<"type">> => <<"green-zone-status">>,
        <<"version">> => <<"1.0">>,
        <<"initialized">> => map_size(Zones) > 0,
        <<"green-zones">> => Zones
    }.

status_body(Name, Opts) ->
    case hb_maps:get(Name, hb_opts:get(<<"green-zones">>, #{}, Opts),
                     undefined, Opts) of
        undefined -> green_zone_not_initialized(Name);
        Zone ->
            #{
                <<"type">> => <<"green-zone-status">>,
                <<"version">> => <<"1.0">>,
                <<"initialized">> => true,
                <<"name">> => Name,
                <<"identity">> => zone_identity(Name),
                <<"green-zone">> => Zone
            }
    end.

zone_definition(Name, Template, Wallet, Members, Opts) ->
    #{
        <<"type">> => <<"green-zone-definition">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => Name,
        <<"identity">> => zone_identity(Name),
        <<"ring-address">> => wallet_address(Wallet),
        <<"ring-reference">> => ring_reference(Name, Template, Wallet, Opts),
        <<"template-id">> => template_id(Name, Template, Opts),
        <<"template">> => Template,
        <<"members">> => Members
    }.

ring_reference(Name, Template, Wallet, Opts) ->
    #{
        <<"type">> => <<"green-zone-ring-reference">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => Name,
        <<"ring-address">> => wallet_address(Wallet),
        <<"template-id">> => template_id(Name, Template, Opts)
    }.

template_id(Name, Template, Opts) ->
    hb_message:id(
        #{<<"type">> => <<"green-zone-template">>,
          <<"name">> => Name,
          <<"template">> => clean_template(Template, Opts)},
        all,
        Opts).

admission_validity(Opts) ->
    Now = erlang:system_time(second),
    TTL = parse_positive_integer(
        hb_opts:get(<<"green-zone-admission-ttl-seconds">>, 300, Opts),
        300),
    #{
        <<"not-before-unix">> => Now,
        <<"expires-at-unix">> => Now + TTL
    }.

required_url(Req, Opts) ->
    case hb_maps:get(<<"joiner-url">>, Req, undefined, Opts) of
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

required_name(Req, Opts) ->
    case optional_name(Req, Opts) of
        undefined ->
            throw({green_zone_error, #{<<"error">> => <<"missing-name">>}});
        Name -> Name
    end.

optional_name(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"name">>, Req, undefined, Opts),
        hb_opts:get(<<"green-zone-name">>, undefined, Opts)
    ]) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> undefined
    end.

zone_identity(Name) ->
    <<?IDENTITY_PREFIX/binary, Name/binary>>.

self_attestation_body(Opts) ->
    case dev_tpm2:boot_attestation(#{}, #{}, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            response_body(Body, Opts);
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"self-attestation-failed">>
            }})
    end.

assert_template_match(Template, Candidate, Subject, Opts) ->
    case hb_message:match(Template, Candidate, primary, Opts) of
        true -> ok;
        {mismatch, _Type, Path, _Expected, _Actual} ->
            throw({green_zone_error, #{
                <<"error">> => <<"template-mismatch">>,
                <<"mismatch-path">> => canonical_mismatch_path(Path),
                <<"subject">> => Subject
            }});
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"template-mismatch">>,
                <<"subject">> => Subject
            }})
    end.

add_member_to_members(Members, URL, Attestation, Role, Opts) ->
    Address = attestation_node_address(Attestation, Opts),
    case Address of
        undefined -> Members;
        _ ->
            Members#{
                Address => #{
                    <<"address">> => Address,
                    <<"url">> => null_or_url(URL),
                    <<"role">> => Role,
                    <<"last-seen-unix">> => erlang:system_time(second)
                }
            }
    end.

attestation_node_address(Attestation, Opts) ->
    Body = response_body(Attestation, Opts),
    Node = hb_maps:get(<<"node">>, Body, #{}, Opts),
    case hb_maps:get(<<"address">>, Node, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> undefined
    end.

null_or_url(undefined) -> null;
null_or_url(URL) -> strip_trailing_slash(URL).

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

verify_joiner(JoinerURL, Req, RingReference, Opts) ->
    VerifyReq = Req#{
        <<"url">> => JoinerURL,
        <<"peer-attestation-scope">> => RingReference
    },
    case dev_tpm2:verify_peer(#{}, VerifyReq, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} -> Body;
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"peer-verification-failed">>
            }})
    end.

peer_attestation_from_req(Req, RingReference, Opts) ->
    JoinerURL = required_url(Req, Opts),
    PeerAttestation = verify_joiner(JoinerURL, Req, RingReference, Opts),
    assert_peer_attestation_body(PeerAttestation, RingReference, Opts),
    {JoinerURL, PeerAttestation}.

clock_skew_seconds(Opts) ->
    parse_positive_integer(
        hb_opts:get(<<"green-zone-clock-skew-seconds">>, 300, Opts),
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

assert_peer_attestation_body(PeerAttestation, RingReference, Opts) ->
    Required = [
        {eq, <<"type">>, <<"green-zone-peer-attestation">>},
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
    assert_fields(PeerAttestation, Required, fun bad_peer_attestation/1, Opts),
    assert_peer_attestation_validity(PeerAttestation, Opts),
    assert_peer_attestation_scope(PeerAttestation, RingReference, Opts).

bad_peer_attestation(Key) ->
    throw({green_zone_error, #{
        <<"error">> => <<"peer-attestation-invalid">>,
        <<"field">> => Key
    }}).

assert_fields(Msg, Checks, Bad, Opts) ->
    lists:foreach(
        fun(Check) -> assert_field(Msg, Check, Bad, Opts) end,
        Checks).

assert_field(Msg, {eq, Key, Expected}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        Expected -> ok;
        _ -> Bad(Key)
    end;
assert_field(Msg, {eq_normalized, Key, Expected, Normalize}, Bad, Opts) ->
    case Normalize(hb_maps:get(Key, Msg, undefined, Opts)) of
        Expected -> ok;
        _ -> Bad(Key)
    end;
assert_field(Msg, {nested_true, Outer, Inner}, Bad, Opts) ->
    case hb_maps:get(Outer, Msg, undefined, Opts) of
        M when is_map(M) ->
            case hb_maps:get(Inner, M, false, Opts) of
                true -> ok;
                _ -> Bad(Outer)
            end;
        _ -> Bad(Outer)
    end;
assert_field(Msg, {field_integer, Key}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        I when is_integer(I), I > 0 -> ok;
        _ -> Bad(Key)
    end;
assert_field(Msg, {field_map, Key}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        M when is_map(M) -> ok;
        _ -> Bad(Key)
    end;
assert_field(Msg, {field_binary, Key}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> ok;
        _ -> Bad(Key)
    end.

assert_peer_attestation_validity(PeerAttestation, Opts) ->
    Now = erlang:system_time(second),
    Skew = clock_skew_seconds(Opts),
    MaxAge = parse_positive_integer(
        hb_opts:get(<<"green-zone-peer-attestation-max-age-seconds">>,
                    3600, Opts),
        3600),
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

assert_peer_attestation_scope(PeerAttestation, RingReference, Opts) ->
    Scope = hb_maps:get(<<"peer-scope">>, PeerAttestation, #{}, Opts),
    ConsumerScope =
        hb_maps:get(<<"consumer-scope">>, Scope, undefined, Opts),
    assert_scope_field(
        <<"name">>, ConsumerScope, RingReference, Opts),
    assert_scope_field(
        <<"ring-address">>, ConsumerScope, RingReference, Opts),
    assert_scope_field(
        <<"template-id">>, ConsumerScope, RingReference, Opts),
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

assert_scope_field(Key, Scope, RingReference, Opts) ->
    Expected = hb_maps:get(Key, RingReference, undefined, Opts),
    case hb_maps:get(Key, Scope, undefined, Opts) of
        Expected when Expected =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.consumer-scope">>)
    end.

peer_boot_attestation_body(PeerAttestation, Opts) ->
    response_body(
        hb_maps:get(
            <<"peer-boot-attestation">>, PeerAttestation, undefined, Opts),
        Opts).

request_admission(PeerURL, SelfURL, AdmissionNonce, Req, Opts) ->
    Body = maps:with(
        [<<"trusted-ca">>],
        Req
    ),
    AdmitReq = Body#{
        <<"name">> => required_name(Req, Opts),
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
        _:_ ->
            throw({green_zone_error, #{
                <<"error">> => <<"admission-request-failed">>
            }})
    end.

admission_response_body(#{<<"status">> := 200, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
admission_response_body(#{<<"status">> := Status, <<"body">> := Body}, _Opts)
        when is_integer(Status), Status >= 400, is_map(Body) ->
    throw({green_zone_error, Body});
admission_response_body(Other, Opts) ->
    response_body(Other, Opts).

assert_admission_body(Admission, SelfURL, AdmissionNonce, Req, Opts) ->
    Self = strip_trailing_slash(SelfURL),
    Checks = [
        {eq, <<"type">>, <<"green-zone-admission">>},
        {eq, <<"name">>, required_name(Req, Opts)},
        {eq_normalized, <<"joiner-url">>, Self, fun strip_trailing_slash/1},
        {eq, <<"admission-nonce">>, AdmissionNonce},
        {field_map, <<"validity">>},
        {field_map, <<"ring-reference">>},
        {field_map, <<"authorization">>},
        {field_map, <<"credential">>},
        {field_map, <<"encrypted-wallet">>},
        {field_map, <<"peer-attestation">>},
        {field_binary, <<"ring-address">>}
    ],
    assert_fields(Admission, Checks, fun bad_admission/1, Opts),
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
    RingReference = hb_maps:get(<<"ring-reference">>, Admission, #{}, Opts),
    case hb_maps:get(<<"ring-address">>, RingReference, undefined, Opts) of
        RingAddress -> ok;
        _ -> bad_admission(<<"ring-reference.ring-address">>)
    end,
    Name = hb_maps:get(<<"name">>, Admission, undefined, Opts),
    case hb_maps:get(<<"name">>, RingReference, undefined, Opts) of
        Name -> ok;
        _ -> bad_admission(<<"ring-reference.name">>)
    end.

bad_admission(Key) ->
    throw({green_zone_error, #{
        <<"error">> => <<"admission-invalid">>,
        <<"field">> => Key
    }}).

assert_admission_signature(Admission, Opts) ->
    Authorization = response_body(
        hb_maps:get(<<"authorization">>, Admission, undefined, Opts),
        Opts),
    RingAddress = hb_maps:get(<<"ring-address">>, Admission, undefined, Opts),
    Signers = hb_message:signers(Authorization, Opts),
    case hb_message:verify(Authorization, Signers, Opts) of
        true -> ok;
        false -> bad_admission(<<"authorization.commitments">>)
    end,
    case lists:member(RingAddress, Signers) of
        true -> ok;
        false -> bad_admission(<<"ring-address">>)
    end,
    assert_authorization_fields(Authorization, Admission, Opts),
    assert_authorization_ids(Authorization, Admission, Opts).

assert_authorization_fields(Authorization, Admission, Opts) ->
    lists:foreach(
        fun(Field) ->
            case {
                hb_maps:get(Field, Authorization, undefined, Opts),
                hb_maps:get(Field, Admission, undefined, Opts)
            } of
                {Same, Same} when Same =/= undefined -> ok;
                _ -> bad_admission(<<"authorization.", Field/binary>>)
            end
        end,
        authorization_scalar_fields()),
    case hb_maps:get(<<"template-matched">>, Authorization, undefined, Opts) of
        <<"true">> -> ok;
        _ -> bad_admission(<<"authorization.template-matched">>)
    end.

assert_authorization_ids(Authorization, Admission, Opts) ->
    lists:foreach(
        fun({AuthKey, AdmissionKey}) ->
            Payload = hb_maps:get(AdmissionKey, Admission, undefined, Opts),
            case hb_maps:get(AuthKey, Authorization, undefined, Opts) of
                ID when is_binary(ID) ->
                    case lists:member(ID, acceptable_payload_ids(Payload, Opts)) of
                        true -> ok;
                        false ->
                            bad_admission(<<"authorization.", AuthKey/binary>>)
                    end;
                _ ->
                    bad_admission(<<"authorization.", AuthKey/binary>>)
            end
        end,
        authorization_id_fields()).

acceptable_payload_ids(Payload, Opts) when is_map(Payload) ->
    Body = response_body(Payload, Opts),
    [stable_uncommitted_id(Body) | unsigned_commitment_ids(Body, Opts)];
acceptable_payload_ids(Payload, _Opts) ->
    [hb_util:encode(crypto:hash(sha256, term_to_binary(Payload)))].

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
        _ ->
            throw({green_zone_error, #{
                <<"error">> => <<"credential-activation-failed">>
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

green_zone_signing_opts(Name, Opts) ->
    {_AES, Wallet, _Zone} = require_ring(Name, Opts),
    #{<<"priv-wallet">> => Wallet}.

sign_payload(Req, Opts) ->
    case hb_maps:get(<<"body">>, Req, undefined, Opts) of
        undefined ->
            maps:without([<<"path">>, <<"device">>, <<"method">>], Req);
        Body -> Body
    end.

wallet_address(Wallet) ->
    hb_util:human_id(ar_wallet:to_address(Wallet)).

match_template(Template, Candidate, Opts) ->
    hb_message:match(Template, Candidate, primary, Opts) =:= true.

clean_template(Template, Opts) when is_map(Template) ->
    clean_template_map(Template, Opts);
clean_template(Template, _Opts) ->
    Template.

clean_template_map(Template, Opts) ->
    maps:from_list(
        [
            {Key, clean_template_value(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Template, Opts),
            not lists:member(Key, ?TEMPLATE_META_KEYS)
        ]).

clean_template_value(Value, Opts) when is_map(Value) ->
    clean_template_map(Value, Opts);
clean_template_value(<<"_">>, _Opts) ->
    '_';
clean_template_value(Value, _Opts) ->
    Value.

ensure_nonempty_template(Template) when is_map(Template),
                                       map_size(Template) > 0 ->
    ok;
ensure_nonempty_template(_Template) ->
    throw({green_zone_error, #{<<"error">> => <<"empty-template">>}}).

canonical_mismatch_path(<<"/", _/binary>> = Path) ->
    Path;
canonical_mismatch_path(Path) when is_binary(Path) ->
    <<"/", Path/binary>>.

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
    Template = clean_template(
        #{<<"node">> => #{<<"address">> => <<"_">>}},
        #{}),
    ?assert(match_template(
        Template,
        #{<<"node">> => #{<<"address">> => <<"abc">>}},
        #{}
    )),
    ?assertNot(match_template(
        Template,
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

stored_peer_attestation_is_not_green_zone_trust_input_test() ->
    PublisherWallet = ar_wallet:new(),
    RingReference = test_ring_reference(),
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingReference),
    Req = #{<<"peer-attestation">> => Attestation},
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"missing-joiner-url">>}},
        peer_attestation_from_req(Req, RingReference, #{})).

green_zone_policy_uses_boot_attestation_test() ->
    PublisherWallet = ar_wallet:new(),
    RingReference = test_ring_reference(),
    Boot = #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
        }
    },
    Fresh = #{
        <<"body">> => #{
            <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"bad">>}}
        }
    },
    Attestation = signed_peer_attestation(
        PublisherWallet, Boot, RingReference, erlang:system_time(second), Fresh),
    Template = #{<<"system">> => #{
        <<"kernel">> => #{<<"cmdline">> => <<"good">>}}},
    ?assert(match_template(
        Template, peer_boot_attestation_body(Attestation, #{}), #{})),
    ?assertNot(match_template(
        Template,
        response_body(
            hb_maps:get(
                <<"peer-fresh-attestation">>, Attestation, undefined, #{}),
            #{}),
        #{})).

expired_peer_attestation_rejected_test() ->
    PublisherWallet = ar_wallet:new(),
    RingReference = test_ring_reference(),
    Old = erlang:system_time(second) - 7200,
    Attestation = signed_peer_attestation(PublisherWallet, #{
        <<"system">> => #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}}
    }, RingReference, Old),
    ?assertThrow(
        {green_zone_error, #{
            <<"error">> := <<"peer-attestation-invalid">>,
            <<"field">> := <<"issued-at-unix">>
        }},
        assert_peer_attestation_body(Attestation, RingReference, #{})).

admission_body_requires_joiner_binding_test() ->
    Wallet = ar_wallet:new(),
    Admission = (test_admission(Wallet))#{
        <<"joiner-url">> => <<"http://other.example">>
    },
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"admission-invalid">>}},
        assert_admission_body(
            Admission,
            <<"http://self.example">>,
            <<"nonce">>,
            #{<<"name">> => test_name()},
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
            <<"http://self.example">>,
            <<"nonce">>,
            #{<<"name">> => test_name()},
            #{})).

admission_body_accepts_expected_ring_test() ->
    Wallet = ar_wallet:new(),
    RingAddress = wallet_address(Wallet),
    ?assertEqual(ok,
        assert_admission_body(
            test_admission(Wallet),
            <<"http://self.example">>,
            <<"nonce">>,
            #{
                <<"name">> => test_name(),
                <<"expected-ring-address">> => RingAddress
            },
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
        green_zone_signing_opts(test_name(), #{})).

metadata_keys_are_stripped_recursively_test() ->
    Template = clean_template(#{
        <<"system">> => #{<<"commitments">> => <<"required">>},
        <<"commitments">> => #{<<"ignored-envelope-metadata">> => true}
    }, #{}),
    ?assertEqual(#{<<"system">> => #{}}, Template),
    ?assert(match_template(
        Template,
        #{<<"system">> => #{}},
        #{})).

metadata_only_template_rejected_test() ->
    ?assertThrow(
        {green_zone_error, #{<<"error">> := <<"empty-template">>}},
        install_ring(
            test_name(),
            #{<<"commitments">> => #{<<"only-metadata">> => true}},
            crypto:strong_rand_bytes(32),
            ar_wallet:new(),
            #{},
            #{})).

test_admission(Wallet) ->
    RingReference = test_ring_reference(Wallet),
    Admission = #{
        <<"type">> => <<"green-zone-admission">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => test_name(),
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"validity">> => admission_validity(#{}),
        <<"admission-nonce">> => <<"nonce">>,
        <<"ring-reference">> => RingReference,
        <<"green-zone">> => #{
            <<"name">> => test_name(),
            <<"members">> => #{}
        },
        <<"template">> => #{},
        <<"joiner-url">> => <<"http://self.example">>,
        <<"credential">> => #{},
        <<"encrypted-wallet">> => #{},
        <<"peer-attestation">> => #{<<"peer-url">> => <<"http://self.example">>},
        <<"ring-address">> => wallet_address(Wallet)
    },
    Admission#{
        <<"authorization">> => admission_authorization(Admission, Wallet, #{})
    }.

signed_peer_attestation(Wallet, BootAttestation, RingReference) ->
    signed_peer_attestation(
        Wallet, BootAttestation, RingReference, erlang:system_time(second)).

signed_peer_attestation(Wallet, BootAttestation, RingReference, Now) ->
    signed_peer_attestation(
        Wallet, BootAttestation, RingReference, Now, test_fresh_attestation()).

signed_peer_attestation(Wallet, BootAttestation, RingReference, Now,
                        FreshAttestation) ->
    Subject = test_credential_subject(),
    BootBody = response_body(BootAttestation, #{}),
    FreshBody = response_body(FreshAttestation, #{}),
    PeerURL = <<"http://peer.example">>,
    hb_message:commit(
        #{
            <<"type">> => <<"green-zone-peer-attestation">>,
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
                <<"consumer-scope">> => RingReference,
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

test_ring_reference() ->
    #{
        <<"type">> => <<"green-zone-ring-reference">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => test_name(),
        <<"ring-address">> => <<"ring-address">>,
        <<"template-id">> => <<"template-id">>
    }.

test_ring_reference(Wallet) ->
    (test_ring_reference())#{<<"ring-address">> => wallet_address(Wallet)}.

test_name() ->
    <<"book-shelf">>.

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

-endif.
