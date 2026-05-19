%%% @doc Measurement-backed zone rings.
%%%
%%% A zone is a shared signing identity admitted by evidence rather than
%%% by operator fiat. The device is intentionally small:
%%%
%%% * `init' creates a named ring wallet, a 256-bit AES ring secret, and a
%%%   deeply-nested template after proving that the initializing node matches
%%%   the template.
%%% * `admit' verifies a candidate peer through `~measurement@1.0/verify-peer',
%%%   matches the candidate's boot attestation against the template, then
%%%   wraps the ring AES secret to the peer's measured secret recipient. The
%%%   fresh measurement and secret-activation proof establish liveness and
%%%   possession of the engine-native recipient named in that boot measurement.
%%%   The ring wallet is encrypted under the wrapped AES key.
%%% * `join' asks an existing member for a named ring admission, checks the
%%%   envelope, unwraps the AES key through `~measurement@1.0/unwrap-secret',
%%%   decrypts the wallet, verifies its advertised ring address, and installs
%%%   it as a local zone identity.
%%% * `member' returns a narrow membership proof signed by the installed
%%%   zone identity. It proves that this node address is present in the
%%%   local zone member set without exposing an arbitrary signing endpoint.
%%%   A request can set `membership-codec-device' to choose the commitment
%%%   codec used for that proof; otherwise the node's normal commitment
%%%   device is used. A request can also set `target' to bind the proof to
%%%   an index, scheduler, or process that should consume it.
%%% The ring wallet is installed as an additional HyperBEAM identity
%%% (`zone/<name>'). Signing with that identity is deliberately
%%% handled by HyperBEAM's identity system, not by a zone-specific
%%% arbitrary signing endpoint.
%%%
%%% Ring templates are normal HyperBEAM message match templates: AO metadata
%%% keys are ignored, template keys must be present in the candidate, non-map
%%% values match exactly, and the atom `_' is a wildcard. JSON callers can send
%%% the string `"_"', which is normalized to that atom before matching.
%%%
%%% The admission protocol is:
%%%
%%% 1. The initializer calls `init' with a `name' and `template'. The node
%%%    reads its own cached `~measurement@1.0/boot', verifies that the
%%%    template matches it, then generates the ring AES key and wallet locally.
%%%    Callers cannot provide those secrets.
%%% 2. A joiner calls its local `join' with the zone `name', a member
%%%    `peer-url', its own `self-url', and the expected `ring-address'.
%%% 3. The joiner sends an admission request to the peer. The peer calls
%%%    `~measurement@1.0/verify-peer' for the joiner's URL. That device verifies
%%%    the joiner's boot measurement, verifies a fresh nonce-bound measurement,
%%%    checks the secret recipient agrees, and performs the engine-native
%%%    wrap/unwrap proof to prove the joiner controls the recipient inside that
%%%    measured environment.
%%%    It returns a signed `zone-peer-attestation'.
%%% 4. The peer matches the ring template against the boot attestation inside
%%%    that peer attestation. If it matches, the peer wraps the ring AES key to
%%%    the joiner's TPM and encrypts the ring wallet under that AES key.
%%% 5. The peer returns a `zone-admission'. The top-level HTTP/JSON
%%%    envelope may acquire transport commitments, so the durable ring
%%%    signature is over the nested `authorization' message. That authorization
%%%    binds the scalar admission fields and locally recomputed stable IDs of
%%%    the nested payloads: validity, ring-reference, zone definition,
%%%    template, peer-attestation, credential, and encrypted-wallet. Nested
%%%    transport commitments are ignored for this ID calculation so an attacker
%%%    cannot smuggle a signed ID into a modified payload. JSON type metadata is
%%%    transport metadata and is ignored for this authorization hash; scalar
%%%    type checks happen in the peer-attestation and measurement verifiers.
%%% 6. The joiner verifies the ring-signed authorization, checks every payload
%%%    ID, activates the credential locally, decrypts the wallet, confirms
%%%    the wallet address equals the expected ring address, and installs the
%%%    identity as `zone/<name>'.
%%% 7. A member can call `member' to receive a signed, narrow statement that
%%%    its node address is a member of the named zone. The only signer is the
%%%    ring identity. The caller may only choose the zone, commitment codec,
%%%    and optional target/audience.
-module(dev_zone).
-export([info/1, info/3, init/3, status/3, admit/3, join/3, member/3]).

-include("include/hb.hrl").

-define(IDENTITY_PREFIX, <<"zone/">>).
-define(TEMPLATE_META_KEYS, [<<"commitments">>, <<"ao-types">>]).

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"init">>,
            <<"status">>,
            <<"admit">>,
            <<"join">>,
            <<"member">>
        ]
    }.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"description">> =>
                <<"Measurement-backed zone ring admission and shared "
                  "identity">>,
            <<"version">> => <<"1.0">>,
            <<"template-semantics">> =>
                <<"HyperBEAM message primary match; non-map values exact; "
                  "'_' wildcard">>,
            <<"peer-attestation-trust">> =>
                <<"Zone admission verifies live peers through "
                  "~measurement@1.0/verify-peer. Reusable/transitive "
                  "peer-attestation publisher trust is a measurement-device "
                  "concern, not ring state.">>
        }
    }}.

init(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        Template = clean_template(
            hb_maps:get(<<"template">>, Req, #{}, Opts),
            Opts),
        reject_supplied_secret_material(Req, Opts),
        Self = self_attestation_body(Template, Opts),
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
        NewOpts =
            install_ring_and_storage(Name, Template, AES, Wallet, Members, Opts),
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

admit(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        {AES, Wallet, Zone} = require_ring(Name, Opts),
        Template = hb_maps:get(<<"template">>, Zone, #{}, Opts),
        RingReference = ring_reference(Name, Template, Wallet, Opts),
        {JoinerURL, PeerAttestation} =
            peer_attestation_from_req(Req, RingReference, Opts),
        PolicyAttestation =
            peer_boot_attestation_body(Template, PeerAttestation, Opts),
        ok = assert_template_match(Template, PolicyAttestation, JoinerURL, Opts),
        Subject = hb_maps:get(
            <<"peer-credential-subject">>, PeerAttestation, undefined, Opts),
        Credential = commit_unsigned_tree(
            dev_measurement:wrap_secret_for_subject(Subject, AES, Opts),
            Opts),
        EncryptedWallet = commit_unsigned_tree(encrypt_wallet(Wallet, AES), Opts),
        Members = add_member_to_members(
            hb_maps:get(<<"members">>, Zone, #{}, Opts),
            JoinerURL,
            PolicyAttestation,
            <<"member">>,
            Opts
        ),
        NewOpts =
            install_ring_and_storage(Name, Template, AES, Wallet, Members, Opts),
        hb_http_server:set_opts(NewOpts),
        Definition = commit_unsigned_tree(
            zone_definition(Name, Template, Wallet, Members, Opts),
            Opts),
        Validity = commit_unsigned_tree(admission_validity(Opts), Opts),
        Admission0 = #{
            <<"type">> => <<"zone-admission">>,
            <<"version">> => <<"1.0">>,
            <<"name">> => Name,
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"validity">> => Validity,
            <<"admission-nonce">> =>
                hb_maps:get(<<"admission-nonce">>, Req, null, Opts),
            <<"ring-reference">> => commit_unsigned_tree(RingReference, Opts),
            <<"zone">> => Definition,
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
        Definition = hb_maps:get(<<"zone">>, Admission, #{}, Opts),
        Members = hb_maps:get(<<"members">>, Definition, #{}, Opts),
        NewMembers = add_member_to_members(
            Members, SelfURL, peer_boot_attestation_body(Template,
                response_body(
                    hb_maps:get(<<"peer-attestation">>, Admission, #{}, Opts),
                    Opts),
                Opts),
            <<"member">>,
            Opts
        ),
        NewOpts =
            install_ring_and_storage(
                Name, Template, AES, Wallet, NewMembers, Opts),
        hb_http_server:set_opts(NewOpts),
        status_body(Name, NewOpts)
    end, Opts).

member(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_zone(Req, Opts),
        {_AES, Wallet, Zone} = require_ring(Name, Opts),
        Address = node_address(Opts),
        Member = require_local_member(Name, Zone, Address, Opts),
        Identity = zone_identity(Name),
        Proof0 = #{
            <<"type">> => <<"zone-membership-proof">>,
            <<"version">> => <<"1.0">>,
            <<"address">> => Address,
            <<"member-of">> => Name,
            <<"identity">> => Identity,
            <<"ring-address">> => wallet_address(Wallet),
            <<"issued-at-unix">> => erlang:system_time(second),
            <<"member">> => Member
        },
        Proof = maybe_add_target(Proof0, Req, Opts),
        case hb_opts:as(Identity, Opts) of
            {ok, ZoneOpts} ->
                hb_message:commit(
                    Proof,
                    ZoneOpts,
                    membership_codec_device(Req, ZoneOpts)
                );
            {error, not_found} -> zone_not_initialized(Name)
        end
    end, Opts).

with_result(Fun, Opts) ->
    try
        ResultBody = ensure_committed(Fun(), Opts),
        {ok, #{<<"status">> => 200, <<"body">> => ResultBody}}
    catch
        throw:{zone_error, ErrorBody} ->
            {ok, #{<<"status">> => 400, <<"body">> => ErrorBody}};
        _:_ ->
            {ok, #{
                <<"status">> => 500,
                <<"body">> => #{
                    <<"error">> => <<"zone-failed">>
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
            <<"type">> => <<"zone-admission-authorization">>,
            <<"version">> => <<"1.0">>,
            <<"template-matched">> => <<"true">>
        }, maps:from_list(
            [
                {Field, hb_maps:get(Field, Admission, undefined, Opts)}
             || Field <- authorization_scalar_fields()
            ] ++
            [
                {AuthKey, stable_authorization_payload_id(
                    hb_maps:get(AdmissionKey, Admission, #{}, Opts),
                    Opts,
                    MetadataMode)}
             || {AuthKey, AdmissionKey, MetadataMode} <-
                    authorization_id_fields()
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
        {<<"validity-id">>, <<"validity">>, strip_json_metadata},
        {<<"ring-reference-id">>, <<"ring-reference">>, strip_json_metadata},
        {<<"zone-id">>, <<"zone">>, strip_json_metadata},
        {<<"template-id">>, <<"template">>, strip_json_metadata},
        {<<"peer-attestation-id">>, <<"peer-attestation">>, strip_json_metadata},
        {<<"credential-id">>, <<"credential">>, strip_json_metadata},
        {<<"encrypted-wallet-id">>, <<"encrypted-wallet">>, strip_json_metadata}
    ].

stable_authorization_payload_id(Msg, Opts) when is_map(Msg) ->
    stable_authorization_payload_id(Msg, Opts, strip_json_metadata);
stable_authorization_payload_id(Bin, _Opts)
        when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
stable_authorization_payload_id(Bin, _Opts)
        when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
stable_authorization_payload_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
stable_authorization_payload_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

stable_authorization_payload_id(Msg, Opts, MetadataMode) when is_map(Msg) ->
    stable_uncommitted_id(
        canonical_authorization_payload(
            hb_cache:ensure_all_loaded(response_body(Msg, Opts), Opts),
            Opts,
            MetadataMode));
stable_authorization_payload_id(Bin, _Opts, _MetadataMode)
        when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
stable_authorization_payload_id(Bin, _Opts, _MetadataMode)
        when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
stable_authorization_payload_id(Bin, _Opts, _MetadataMode) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
stable_authorization_payload_id(Value, _Opts, _MetadataMode) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

canonical_authorization_payload(Link, Opts, MetadataMode) when ?IS_LINK(Link) ->
    canonical_authorization_payload(response_body(Link, Opts), Opts, MetadataMode);
canonical_authorization_payload(Msg, Opts, MetadataMode) when is_map(Msg) ->
    Loaded = hb_cache:ensure_all_loaded(hb_link:decode_all_links(Msg), Opts),
    Types = authorization_ao_types(Loaded),
    maps:from_list(
        [
            {Key, canonical_authorization_value(
                Key, Value, Types, Opts, MetadataMode)}
         || {Key, Value} <- hb_maps:to_list(Loaded, Opts),
            not authorization_meta_key(Key, MetadataMode)
        ]);
canonical_authorization_payload(List, Opts, MetadataMode) when is_list(List) ->
    [
        canonical_authorization_payload(Value, Opts, MetadataMode)
     || Value <- List
    ];
canonical_authorization_payload(Value, _Opts, _MetadataMode)
        when is_atom(Value) ->
    hb_util:bin(Value);
canonical_authorization_payload(Value, _Opts, _MetadataMode) ->
    Value.

canonical_authorization_value(Key, Value, Types, Opts, MetadataMode) ->
    authorization_typed_value(
        maps:get(Key, Types, undefined),
        canonical_authorization_payload(Value, Opts, MetadataMode)).

authorization_meta_key(<<"commitments">>, _MetadataMode) -> true;
authorization_meta_key(<<"ao-types">>, strip_json_metadata) -> true;
authorization_meta_key(_Key, _MetadataMode) -> false.

authorization_ao_types(Msg) ->
    case maps:get(<<"ao-types">>, Msg, undefined) of
        Types when is_binary(Types) ->
            maps:from_list(
                [Parsed
                 || Part <- binary:split(Types, <<",">>, [global]),
                    Parsed <- [authorization_ao_type(Part)],
                    Parsed =/= undefined]);
        _ ->
            #{}
    end.

authorization_ao_type(Part0) ->
    Part = iolist_to_binary(string:trim(binary_to_list(Part0))),
    case binary:split(Part, <<"=">>) of
        [RawKey, RawType0] ->
            Key = iolist_to_binary(string:trim(binary_to_list(RawKey))),
            Type0 = iolist_to_binary(string:trim(binary_to_list(RawType0))),
            {Key, trim_type_quotes(Type0)};
        _ ->
            undefined
    end.

trim_type_quotes(<<"\"", Rest/binary>>) ->
    case Rest of
        <<Inner:(byte_size(Rest) - 1)/binary, "\"">> -> Inner;
        _ -> Rest
    end;
trim_type_quotes(Type) ->
    Type.

authorization_typed_value(<<"atom">>, Value) ->
    hb_util:bin(Value);
authorization_typed_value(<<"integer">>, Value) when is_binary(Value) ->
    try binary_to_integer(Value)
    catch _:_ -> Value
    end;
authorization_typed_value(_Type, Value) ->
    Value.

stable_uncommitted_id(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(Msg, #{}),
        uncommitted,
        #{}
    ).

reject_supplied_secret_material(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"aes-key">>, Req, undefined, Opts),
        hb_maps:get(<<"wallet">>, Req, undefined, Opts),
        hb_maps:get(<<"priv-zone-aes">>, Req, undefined, Opts),
        hb_maps:get(<<"priv-zone-wallet">>, Req, undefined, Opts)
    ]) of
        undefined -> ok;
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"secret-material-forbidden">>
            }})
    end.

install_ring(Name, Template0, AES, Wallet, Members, Opts) ->
    Template = clean_template(Template0, Opts),
    ok = ensure_nonempty_template(Template),
    Identities = hb_opts:get(identities, #{}, Opts),
    Zones = hb_opts:get(<<"zones">>, #{}, Opts),
    PrivZones = hb_opts:get(<<"priv-zones">>, #{}, Opts),
    Definition = zone_definition(Name, Template, Wallet, Members, Opts),
    Identity = zone_identity(Name),
    Opts#{
        <<"zones">> => Zones#{Name => Definition},
        <<"priv-zones">> => PrivZones#{
            Name => #{
                <<"aes">> => AES,
                <<"wallet">> => Wallet
            }
        },
        <<"identities">> => Identities#{
            Identity => #{<<"priv-wallet">> => Wallet}
        }
    }.

install_ring_and_storage(Name, Template, AES, Wallet, Members, Opts) ->
    Opts1 = install_ring(Name, Template, AES, Wallet, Members, Opts),
    case lapee_nonvolatile:activate(Name, wallet_address(Wallet), AES, Opts1) of
        {ok, Opts2} -> Opts2;
        _ -> Opts1
    end.

require_ring(Name, Opts) ->
    Priv = hb_opts:get(<<"priv-zones">>, #{}, Opts),
    Zones = hb_opts:get(<<"zones">>, #{}, Opts),
    case {hb_maps:get(Name, Priv, undefined, Opts),
          hb_maps:get(Name, Zones, undefined, Opts)} of
        {#{<<"aes">> := AES, <<"wallet">> := Wallet}, Zone}
                when is_binary(AES), tuple_size(Wallet) > 0, is_map(Zone) ->
            {AES, Wallet, Zone};
        _ -> zone_not_initialized(Name)
    end.

node_address(Opts) ->
    case hb_opts:get(priv_wallet, no_viable_wallet, Opts) of
        no_viable_wallet ->
            case hb_opts:get(<<"address">>, undefined, Opts) of
                B when is_binary(B), byte_size(B) > 0 -> B;
                _ ->
                    throw({zone_error, #{
                        <<"error">> => <<"node-address-unavailable">>
                    }})
            end;
        Wallet -> wallet_address(Wallet)
    end.

require_local_member(Name, Zone, Address, Opts) ->
    Members = response_body(
        hb_maps:get(<<"members">>, Zone, #{}, Opts),
        Opts),
    case hb_maps:get(Address, Members, undefined, Opts) of
        Member when is_map(Member) ->
            Member;
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"zone-not-member">>,
                <<"name">> => Name,
                <<"address">> => Address
            }})
    end.

membership_codec_device(Req, Opts) ->
    case hb_maps:get(<<"membership-codec-device">>, Req, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ ->
            hb_opts:get(
                commitment_device,
                no_viable_commitment_device,
                Opts
            )
    end.

maybe_add_target(Proof, Req, Opts) ->
    case hb_maps:get(<<"target">>, Req, undefined, Opts) of
        undefined -> Proof;
        B when is_binary(B), byte_size(B) > 0 -> Proof#{<<"target">> => B};
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"invalid-target">>
            }})
    end.

zone_not_initialized(Name) ->
    throw({zone_error, #{
        <<"error">> => <<"zone-not-initialized">>,
        <<"name">> => Name
    }}).

all_status_body(Opts) ->
    Zones = hb_opts:get(<<"zones">>, #{}, Opts),
    maybe_add_nonvolatile_status(#{
        <<"type">> => <<"zone-status">>,
        <<"version">> => <<"1.0">>,
        <<"initialized">> => map_size(Zones) > 0,
        <<"zones">> => Zones
    }, Opts).

status_body(Name, Opts) ->
    case hb_maps:get(Name, hb_opts:get(<<"zones">>, #{}, Opts),
                     undefined, Opts) of
        undefined -> zone_not_initialized(Name);
        Zone ->
            maybe_add_nonvolatile_status(#{
                <<"type">> => <<"zone-status">>,
                <<"version">> => <<"1.0">>,
                <<"initialized">> => true,
                <<"name">> => Name,
                <<"identity">> => zone_identity(Name),
                <<"zone">> => Zone
            }, Opts)
    end.

maybe_add_nonvolatile_status(Body, Opts) ->
    case lapee_nonvolatile:status(Opts) of
        Status when is_map(Status), map_size(Status) > 0 ->
            Body#{<<"nonvolatile-storage">> => Status};
        _ ->
            Body
    end.

zone_definition(Name, Template, Wallet, Members, Opts) ->
    #{
        <<"type">> => <<"zone-definition">>,
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
        <<"type">> => <<"zone-ring-reference">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => Name,
        <<"ring-address">> => wallet_address(Wallet),
        <<"template-id">> => template_id(Name, Template, Opts)
    }.

template_id(Name, Template, Opts) ->
    hb_message:id(
        #{<<"type">> => <<"zone-template">>,
          <<"name">> => Name,
          <<"template">> => clean_template(Template, Opts)},
        all,
        Opts).

admission_validity(Opts) ->
    Now = erlang:system_time(second),
    TTL = parse_positive_integer(
        hb_opts:get(<<"zone-admission-ttl-seconds">>, 300, Opts),
        300),
    #{
        <<"not-before-unix">> => Now,
        <<"expires-at-unix">> => Now + TTL
    }.

required_url(Req, Opts) ->
    case hb_maps:get(<<"joiner-url">>, Req, undefined, Opts) of
        undefined ->
            throw({zone_error, #{
                <<"error">> => <<"missing-joiner-url">>
            }});
        URL -> strip_trailing_slash(URL)
    end.

required_peer(Req, Opts) ->
    case first_defined(
        [
            hb_maps:get(<<"peer-url">>, Req, undefined, Opts),
            hb_opts:get(<<"zone-peer-url">>, undefined, Opts)
        ]
    ) of
        undefined ->
            throw({zone_error, #{<<"error">> => <<"missing-peer-url">>}});
        URL -> strip_trailing_slash(URL)
    end.

required_self(Req, Opts) ->
    case first_defined(
        [
            hb_maps:get(<<"self-url">>, Req, undefined, Opts),
            hb_opts:get(<<"zone-self-url">>, undefined, Opts),
            hb_opts:get(<<"public-url">>, undefined, Opts)
        ]
    ) of
        undefined ->
            throw({zone_error, #{<<"error">> => <<"missing-self-url">>}});
        URL -> strip_trailing_slash(URL)
    end.

required_name(Req, Opts) ->
    case optional_name(Req, Opts) of
        undefined ->
            throw({zone_error, #{<<"error">> => <<"missing-name">>}});
        Name -> Name
    end.

optional_name(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"name">>, Req, undefined, Opts),
        hb_opts:get(<<"zone-name">>, undefined, Opts)
    ]) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> undefined
    end.

required_zone(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"member">>, Req, undefined, Opts),
        hb_maps:get(<<"zone">>, Req, undefined, Opts),
        hb_maps:get(<<"name">>, Req, undefined, Opts),
        hb_opts:get(<<"zone-name">>, undefined, Opts)
    ]) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"missing-zone">>
            }})
    end.

zone_identity(Name) ->
    <<?IDENTITY_PREFIX/binary, Name/binary>>.

self_attestation_body(Template, Opts) ->
    case dev_measurement:boot(#{}, #{}, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            measurement_template_target(Template, response_body(Body, Opts), Opts);
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"self-attestation-failed">>
            }})
    end.

assert_template_match(Template, Candidate, Subject, Opts) ->
    case hb_message:match(Template, Candidate, primary, Opts) of
        true -> ok;
        {mismatch, _Type, Path, _Expected, _Actual} ->
            throw({zone_error, #{
                <<"error">> => <<"template-mismatch">>,
                <<"mismatch-path">> => canonical_mismatch_path(Path),
                <<"subject">> => Subject
            }});
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"template-mismatch">>,
                <<"subject">> => Subject
            }})
    end.

%% Add a member entry keyed by the attestation's node wallet address.
%% Members may already carry a `commitments' key from a previous admission
%% snapshot. A plain Erlang `Map#{K => V}' update would leave that stale
%% commitment in place, and the next `hb_message:commit' on a parent that
%% holds Members linkifies it through the cache: the cache write honours
%% the existing signature's `committed' list and silently drops the new
%% key. Strip the stale commitments first, then set via the AO-Core
%% primitive so callers (`commit_unsigned_tree') can re-sign over the
%% updated content.
add_member_to_members(Members, URL, Attestation, Role, Opts) ->
    case attestation_node_address(Attestation, Opts) of
        undefined -> Members;
        Address ->
            hb_ao:set(
                hb_message:uncommitted(Members, Opts),
                Address,
                #{
                    <<"address">> => Address,
                    <<"url">> => null_or_url(URL),
                    <<"role">> => Role,
                    <<"last-seen-unix">> => erlang:system_time(second)
                },
                Opts
            )
    end.

attestation_node_address(Attestation, Opts) ->
    Body = measurement_body(response_body(Attestation, Opts), Opts),
    Node = hb_maps:get(<<"node">>, Body, #{}, Opts),
    case hb_maps:get(<<"address">>, Node, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> undefined
    end.

null_or_url(undefined) -> <<>>;
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
    case dev_measurement:verify_peer(#{}, VerifyReq, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} -> Body;
        _ ->
            throw({zone_error, #{
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
        hb_opts:get(<<"zone-clock-skew-seconds">>, 300, Opts),
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

assert_peer_attestation_body(PeerAttestation, RingReference, Opts) ->
    Required = [
        {eq, <<"type">>, <<"zone-peer-attestation">>},
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
    throw({zone_error, #{
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
        hb_opts:get(<<"zone-peer-attestation-max-age-seconds">>,
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
    case IssuedAt + MaxAge + Skew >= Now of
        true -> ok;
        false -> bad_peer_attestation(<<"issued-at-unix">>)
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
        hb_maps:get(<<"measurement-device">>, Scope, undefined, Opts),
        hb_maps:get(<<"measurement-device">>, Subject, undefined, Opts),
        hb_maps:get(<<"secret-recipient-id">>, Scope, undefined, Opts),
        stable_authorization_payload_id(Subject, Opts)
    } of
        {Device, Device, ID, ID} when Device =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.secret-recipient">>)
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
    stable_authorization_payload_id(Attestation, Opts);
attestation_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
attestation_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
attestation_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
attestation_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

assert_scope_field(Key, Scope, RingReference, Opts) ->
    Expected = hb_maps:get(Key, RingReference, undefined, Opts),
    case hb_maps:get(Key, Scope, undefined, Opts) of
        Expected when Expected =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.consumer-scope">>)
    end.

peer_boot_attestation_body(Template, PeerAttestation, Opts) ->
    measurement_template_target(
        Template,
        response_body(
            hb_maps:get(
                <<"peer-boot-attestation">>, PeerAttestation, undefined, Opts),
            Opts),
        Opts).

measurement_template_target(Template, Measurement, Opts) ->
    Candidate = materialize_measurement_candidate(Template, Measurement, Opts),
    case template_mentions_measurement(Template, Opts) of
        true -> Candidate;
        false -> measurement_body(Candidate, Opts)
    end.

materialize_measurement_candidate(Template, Measurement, Opts)
        when is_map(Measurement) ->
    Decoded = hb_link:decode_all_links(Measurement),
    lists:foldl(
        fun(Key, Acc) -> materialize_measurement_key(Key, Acc, Opts) end,
        Decoded,
        materialized_measurement_keys(Template, Opts));
materialize_measurement_candidate(_Template, Measurement, _Opts) ->
    Measurement.

materialized_measurement_keys(Template, Opts) ->
    [<<"body">> |
        [
            Key
         || Key <- [<<"evidence">>, <<"secret-recipient">>],
            hb_maps:get(Key, Template, undefined, Opts) =/= undefined
        ]].

materialize_measurement_key(Key, Measurement, Opts) ->
    LinkKey = <<Key/binary, "+link">>,
    WithoutLink = maps:remove(LinkKey, Measurement),
    case hb_maps:get(Key, Measurement, undefined, Opts) of
        undefined -> WithoutLink;
        Value ->
            WithoutLink#{Key => hb_cache:ensure_all_loaded(Value, Opts)}
    end.

template_mentions_measurement(Template, Opts) when is_map(Template) ->
    lists:any(
        fun(Key) ->
            hb_maps:get(Key, Template, undefined, Opts) =/= undefined
        end,
        [<<"measurement-device">>, <<"evidence">>, <<"body">>,
         <<"secret-recipient">>]);
template_mentions_measurement(_Template, _Opts) ->
    false.

measurement_body(Measurement, Opts) when is_map(Measurement) ->
    Decoded = hb_link:decode_all_links(Measurement),
    case hb_maps:get(<<"type">>, Decoded, undefined, Opts) of
        <<"lapee-measurement">> ->
            hb_cache:ensure_all_loaded(
                hb_maps:get(<<"body">>, Decoded, #{}, Opts),
                Opts);
        _ ->
            Decoded
    end;
measurement_body(Other, _Opts) ->
    Other.

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
            lapee_peer_http:post(
                PeerURL,
                <<"/~zone@1.0/admit">>,
                AdmitReq,
                Opts),
            Opts
        )
    catch
        throw:{zone_error, ErrorBody} ->
            throw({zone_error, ErrorBody});
        Class:Reason:_Stack ->
            throw({zone_error, #{
                <<"error">> => <<"admission-request-failed">>,
                <<"class">> => hb_util:bin(Class),
                <<"reason">> =>
                    iolist_to_binary(io_lib:format("~0p", [Reason]))
            }})
    end.

admission_response_body(
        #{<<"status">> := 200, <<"body">> := #{<<"status">> := _} = Body},
        Opts) ->
    admission_response_body(Body, Opts);
admission_response_body(#{<<"status">> := 200, <<"body">> := Body}, Opts) ->
    admission_or_error_body(response_body(Body, Opts), Opts);
admission_response_body(#{<<"status">> := Status, <<"body">> := Body}, _Opts)
        when is_integer(Status), Status >= 400, is_map(Body) ->
    throw({zone_error, Body});
admission_response_body(#{<<"body">> := Body}, Opts) when is_map(Body) ->
    admission_response_body(Body, Opts);
admission_response_body(Other, Opts) ->
    admission_or_error_body(response_body(Other, Opts), Opts).

admission_or_error_body(Body, Opts) when is_map(Body) ->
    case {
        hb_maps:get(<<"type">>, Body, undefined, Opts),
        hb_maps:get(<<"error">>, Body, undefined, Opts)
    } of
        {undefined, Error} when is_binary(Error) ->
            throw({zone_error, Body});
        _ ->
            Body
    end;
admission_or_error_body(Body, _Opts) ->
    Body.

assert_admission_body(Admission, SelfURL, AdmissionNonce, Req, Opts) ->
    Self = strip_trailing_slash(SelfURL),
    Checks = [
        {eq, <<"type">>, <<"zone-admission">>},
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
    throw({zone_error, #{
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
        fun({AuthKey, AdmissionKey, MetadataMode}) ->
            Payload = hb_maps:get(AdmissionKey, Admission, undefined, Opts),
            Expected =
                stable_authorization_payload_id(Payload, Opts, MetadataMode),
            case hb_maps:get(AuthKey, Authorization, undefined, Opts) of
                Expected -> ok;
                _ -> bad_admission(<<"authorization.", AuthKey/binary>>)
            end
        end,
        authorization_id_fields()).

assert_admission_validity(Admission, Opts) ->
    Validity = hb_maps:get(<<"validity">>, Admission, #{}, Opts),
    NotBefore = hb_maps:get(<<"not-before-unix">>, Validity, undefined, Opts),
    Expires = hb_maps:get(<<"expires-at-unix">>, Validity, undefined, Opts),
    % The admission's replay protection is the fresh admission-nonce above.
    % Keep the signed validity window as metadata without requiring commodity
    % laptop RTCs to agree before a ring can form.
    case {NotBefore, Expires} of
        {NB, Ex} when is_integer(NB), is_integer(Ex), NB =< Ex ->
            ok;
        _ -> bad_admission(<<"validity">>)
    end.

assert_expected_ring_address(Admission, Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"expected-ring-address">>, Req, undefined, Opts),
        hb_opts:get(<<"zone-ring-address">>, undefined, Opts)
    ]) of
        undefined -> bad_admission(<<"expected-ring-address">>);
        Expected ->
            case hb_maps:get(<<"ring-address">>, Admission, undefined, Opts) of
                Expected -> ok;
                _ -> bad_admission(<<"ring-address">>)
            end
    end.

activate_local_credential(Credential, Opts) ->
    case dev_measurement:unwrap_secret_value(Credential, Opts) of
        {ok, Secret} when is_binary(Secret) ->
            Secret;
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"credential-activation-failed">>
            }})
    end.

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body(#{<<"status">> := _Status, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
response_body(#{<<"body">> := Body} = Msg, Opts) ->
    case hb_maps:get(<<"type">>, Msg, undefined, Opts) of
        <<"lapee-measurement">> -> Msg;
        _ -> response_body(Body, Opts)
    end;
response_body(Body, _Opts) ->
    Body.

decode_required(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:decode(B);
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"missing-field">>,
                <<"field">> => Key
            }})
    end.

encrypt_wallet(Wallet, AES) ->
    IV = crypto:strong_rand_bytes(12),
    Plain = ar_wallet:to_json(Wallet),
    AAD = <<"zone-wallet-v1">>,
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
    AAD = <<"zone-wallet-v1">>,
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
            throw({zone_error, #{
                <<"error">> => <<"wallet-decryption-failed">>
            }});
        _ -> ar_wallet:from_json(Plain)
    end;
decrypt_wallet(_, _AES, _Opts) ->
    throw({zone_error, #{<<"error">> => <<"bad-encrypted-wallet">>}}).

assert_wallet_matches_admission(Wallet, Admission, Opts) ->
    Expected = hb_maps:get(<<"ring-address">>, Admission, undefined, Opts),
    case wallet_address(Wallet) of
        Expected -> ok;
        Actual ->
            throw({zone_error, #{
                <<"error">> => <<"ring-wallet-address-mismatch">>,
                <<"expected">> => Expected,
                <<"actual">> => Actual
            }})
    end.

wallet_address(Wallet) ->
    hb_util:human_id(ar_wallet:to_address(Wallet)).

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
    throw({zone_error, #{<<"error">> => <<"empty-template">>}}).

canonical_mismatch_path(<<"/", _/binary>> = Path) ->
    Path;
canonical_mismatch_path(Path) when is_binary(Path) ->
    <<"/", Path/binary>>.
