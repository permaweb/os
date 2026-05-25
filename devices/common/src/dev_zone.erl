%%% @doc Measurement-backed shared-identity zones.
%%%
%%% `init' creates a locally generated zone wallet/AES secret after the node's
%%% own boot measurement matches at least one template. `admit' verifies a live
%%% peer via `~measurement@1.0/verify-peer', matches the peer's boot measurement
%%% against one admissible template, wraps the AES secret to the peer's measured
%%% recipient, and returns a ring-signed admission. `join' verifies the
%%% admission, unwraps the AES key locally, decrypts the wallet, and installs it
%%% as `zone/<name>'.
%%% `member' returns only a narrow zone-signed membership proof. `start' is a
%%% boot hook that auto-joins explicitly configured zones after the HTTP listener
%%% is available.
-module(dev_zone).
-implements(<<"zone@1.0">>).
-device_libraries([lib_lapee_nonvolatile, lib_permawebos_peer_http]).
-export([info/1, info/3, init/3, status/3, admit/3, join/3, member/3, start/3]).

-include_lib("hb/include/hb.hrl").

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
            <<"member">>,
            <<"start">>
        ]
    }.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"version">> => <<"1.0">>,
            <<"exports">> => maps:get(exports, info(#{}), [])
        }
    }}.

init(_Base, Req, Opts) ->
    with_result(fun() ->
        Name = required_name(Req, Opts),
        ok = assert_zone_initialization_allowed(Name, Opts),
        Templates = request_templates(Req, Opts),
        reject_supplied_secret_material(Req, Opts),
        {_Template, Self} = self_attestation_body(Templates, Opts),
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
            install_ring_and_storage(Name, Templates, AES, Wallet, Members, Opts),
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
        Templates = zone_templates(Zone, Opts),
        RingReference = ring_reference(Name, Templates, Wallet, Opts),
        {JoinerURL, PeerAttestation} =
            peer_attestation_from_req(Req, RingReference, Opts),
        {MatchedTemplate, PolicyAttestation} =
            peer_boot_attestation_body(Templates, PeerAttestation, Opts),
        Subject = peer_attestation_payload(
            <<"peer-credential-subject">>, PeerAttestation, Opts),
        Credential = commit_unsigned_tree(
            measurement_wrap_secret(Subject, AES, Opts),
            Opts),
        EncryptedWallet = commit_unsigned_tree(encrypt_wallet(Wallet, AES), Opts),
        Members = add_member_to_members(
            hb_maps:get(<<"members">>, Zone, #{}, Opts),
            JoinerURL,
            PolicyAttestation,
            <<"member">>,
            Opts
        ),
        PublicPeerAttestation = hb_private:reset(PeerAttestation),
        NewOpts =
            install_ring_and_storage(Name, Templates, AES, Wallet, Members, Opts),
        hb_http_server:set_opts(NewOpts),
        Definition = commit_unsigned_tree(
            zone_definition(Name, Templates, Wallet, Members, Opts),
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
            <<"template">> => commit_unsigned_tree(MatchedTemplate, Opts),
            <<"peer-attestation">> => PublicPeerAttestation,
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
        ok = assert_zone_install_allowed(Name, Opts),
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
        MatchedTemplate = response_body(
            hb_maps:get(<<"template">>, Admission, #{}, Opts),
            Opts),
        Definition = response_body(hb_maps:get(<<"zone">>, Admission, #{}, Opts), Opts),
        Templates = zone_templates(Definition, Opts),
        Members = hb_maps:get(<<"members">>, Definition, #{}, Opts),
        {_SelfTemplate, SelfPolicyAttestation} =
            self_attestation_body(MatchedTemplate, Opts),
        NewMembers = add_member_to_members(
            Members,
            SelfURL,
            SelfPolicyAttestation,
            <<"member">>,
            Opts
        ),
        NewOpts =
            install_ring_and_storage(
                Name, Templates, AES, Wallet, NewMembers, Opts),
        hb_http_server:set_opts(NewOpts),
        status_body(Name, NewOpts)
    end, Opts).

start(_Base, Req, Opts) ->
    with_result(fun() ->
        NodeOpts = start_node_opts(Req, Opts),
        case zone_allow(NodeOpts) of
            {bootstrap, Entries} when map_size(Entries) > 0 ->
                ServerID = node_address(NodeOpts),
                spawn(fun() -> bootstrap_zones(ServerID, Entries) end),
                #{
                    <<"type">> => <<"zone-start">>,
                    <<"version">> => <<"1.0">>,
                    <<"bootstrap">> => <<"scheduled">>,
                    <<"zones">> => maps:keys(Entries)
                };
            _ ->
                #{
                    <<"type">> => <<"zone-start">>,
                    <<"version">> => <<"1.0">>,
                    <<"bootstrap">> => <<"not-configured">>
                }
        end
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
        Proof = maybe_add_target(maybe_add_operator(Proof0, Opts), Req, Opts),
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
        Result0 = Fun(),
        ResultBody = ensure_committed(Result0, Opts),
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
    Authorization = maps:merge(#{
        <<"type">> => <<"zone-admission-authorization">>,
        <<"version">> => <<"1.0">>,
        <<"template-matched">> => <<"true">>
    }, maps:from_list(
        [
            {Field, hb_maps:get(Field, Admission, undefined, Opts)}
         || Field <- authorization_scalar_fields()
        ] ++
        authorization_payload_ids(Admission, Opts))),
    hb_message:commit(
        Authorization,
        Opts#{<<"priv-wallet">> => Wallet},
        <<"httpsig@1.0">>
    ).

authorization_payload_ids(Admission, Opts) ->
    [
        begin
            ID = authorization_payload_id(
                AuthKey,
                hb_maps:get(AdmissionKey, Admission, #{}, Opts),
                Opts),
            {AuthKey, ID}
        end
     || {AuthKey, AdmissionKey} <- authorization_id_fields()
    ].

authorization_payload_id(<<"zone-id">>, Zone, Opts) ->
    stable_authorization_payload_id(zone_authorization_payload(Zone, Opts), Opts);
authorization_payload_id(_AuthKey, Payload, Opts) ->
    stable_authorization_payload_id(Payload, Opts).

zone_authorization_payload(Zone0, Opts) ->
    Zone = response_body(Zone0, Opts),
    #{
        <<"type">> => hb_maps:get(<<"type">>, Zone, undefined, Opts),
        <<"version">> => hb_maps:get(<<"version">>, Zone, undefined, Opts),
        <<"name">> => hb_maps:get(<<"name">>, Zone, undefined, Opts),
        <<"identity">> => hb_maps:get(<<"identity">>, Zone, undefined, Opts),
        <<"ring-address">> =>
            hb_maps:get(<<"ring-address">>, Zone, undefined, Opts),
        <<"template-id">> =>
            hb_maps:get(<<"template-id">>, Zone, undefined, Opts),
        <<"members">> =>
            members_authorization_payload(
                hb_maps:get(<<"members">>, Zone, #{}, Opts),
                Opts)
    }.

members_authorization_payload(Members0, Opts) ->
    Members = response_body(Members0, Opts),
    maps:from_list(
        [
            {Address, member_authorization_payload(Member, Opts)}
         || {Address, Member} <- hb_maps:to_list(Members, Opts),
            not detached_meta_key(Address)
        ]).

member_authorization_payload(Member0, Opts) when ?IS_LINK(Member0) ->
    member_authorization_payload(response_body(Member0, Opts), Opts);
member_authorization_payload(Member0, Opts) when is_map(Member0) ->
    Member = hb_cache:ensure_all_loaded(response_body(Member0, Opts), Opts),
    maps:with(
        [<<"address">>, <<"url">>, <<"role">>, <<"last-seen-unix">>],
        canonical_authorization_payload(Member, Opts));
member_authorization_payload(Member, _Opts) ->
    Member.

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
        {<<"zone-id">>, <<"zone">>},
        {<<"template-id">>, <<"template">>},
        {<<"peer-attestation-id">>, <<"peer-attestation">>},
        {<<"credential-id">>, <<"credential">>},
        {<<"encrypted-wallet-id">>, <<"encrypted-wallet">>}
    ].

stable_authorization_payload_id(Msg, Opts) when is_map(Msg) ->
    stable_uncommitted_id(
        canonical_authorization_payload(
            authorization_payload_body(Msg, Opts),
            Opts),
        Opts);
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

authorization_payload_body(Link, Opts) when ?IS_LINK(Link) ->
    authorization_payload_body(hb_cache:ensure_loaded(Link, Opts), Opts);
authorization_payload_body(Msg, Opts) when is_map(Msg) ->
    Decoded = hb_link:decode_all_links(Msg),
    case response_envelope_body(Decoded, Opts) of
        undefined -> Decoded;
        Body -> authorization_payload_body(Body, Opts)
    end;
authorization_payload_body(Value, _Opts) ->
    Value.

canonical_authorization_payload(Link, Opts) when ?IS_LINK(Link) ->
    canonical_authorization_payload(hb_cache:ensure_loaded(Link, Opts), Opts);
canonical_authorization_payload(Msg, Opts) when is_map(Msg) ->
    Decoded = hb_link:decode_all_links(Msg),
    case response_envelope_body(Decoded, Opts) of
        undefined ->
            maps:from_list(
                [
                    {Key, canonical_authorization_payload(Value, Opts)}
                 || {Key, Value} <- hb_maps:to_list(Decoded, Opts),
                    not detached_meta_key(Key)
                ]);
        Body ->
            canonical_authorization_payload(Body, Opts)
    end;
canonical_authorization_payload(List, Opts) when is_list(List) ->
    [canonical_authorization_payload(Value, Opts) || Value <- List];
canonical_authorization_payload(Value, _Opts) when is_atom(Value) ->
    hb_util:bin(Value);
canonical_authorization_payload(Value, _Opts) ->
    Value.

detached_meta_key(<<"commitments">>) -> true;
detached_meta_key(<<"ao-types">>) -> true;
detached_meta_key(<<"device">>) -> true;
detached_meta_key(<<"status">>) -> true;
detached_meta_key(_Key) -> false.

stable_uncommitted_id(Msg, Opts) ->
    hb_message:id(
        hb_message:uncommitted_deep(Msg, #{}),
        uncommitted,
        Opts
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

assert_zone_install_allowed(Name, Opts) ->
    Zones = hb_opts:get(<<"zones">>, #{}, Opts),
    case hb_maps:get(Name, Zones, undefined, Opts) of
        Existing when is_map(Existing) ->
            throw({zone_error, #{
                <<"error">> => <<"zone-already-joined">>,
                <<"name">> => Name
            }});
        _ ->
            ok = assert_nonvolatile_install_allowed(Name, Opts),
            assert_zone_allowed(Name, Zones, zone_allow(Opts), Opts)
    end.

assert_nonvolatile_install_allowed(Name, Opts) ->
    case lib_lapee_nonvolatile:status(Opts) of
        #{<<"mounted">> := true} = Existing ->
            throw({zone_error, #{
                <<"error">> => <<"nonvolatile-zone-conflict">>,
                <<"name">> => Name,
                <<"existing">> => Existing
            }});
        _ ->
            ok
    end.

assert_zone_initialization_allowed(Name, Opts) ->
    ok = assert_zone_install_allowed(Name, Opts),
    assert_zone_init_allowed(Name, zone_init_allow(Opts), Opts).

assert_zone_init_allowed(Name, disabled, _Opts) ->
    throw({zone_error, #{
        <<"error">> => <<"zone-init-disabled">>,
        <<"name">> => Name
    }});
assert_zone_init_allowed(_Name, unlimited, _Opts) ->
    ok;
assert_zone_init_allowed(Name, {names, Names}, _Opts) ->
    case lists:member(Name, Names) of
        true -> ok;
        false ->
            throw({zone_error, #{
                <<"error">> => <<"zone-init-not-allowed">>,
                <<"name">> => Name
            }})
    end;
assert_zone_init_allowed(Name, invalid, _Opts) ->
    throw({zone_error, #{
        <<"error">> => <<"invalid-zone-init-allow">>,
        <<"name">> => Name
    }}).

assert_zone_allowed(Name, _Zones, disabled, _Opts) ->
    throw({zone_error, #{
        <<"error">> => <<"zone-join-disabled">>,
        <<"name">> => Name
    }});
assert_zone_allowed(_Name, _Zones, unlimited, _Opts) ->
    ok;
assert_zone_allowed(_Name, Zones, {limit, Limit}, _Opts)
        when map_size(Zones) < Limit ->
    ok;
assert_zone_allowed(Name, Zones, {limit, Limit}, _Opts) ->
    throw({zone_error, #{
        <<"error">> => <<"zone-limit-exceeded">>,
        <<"name">> => Name,
        <<"joined">> => map_size(Zones),
        <<"limit">> => Limit
    }});
assert_zone_allowed(Name, _Zones, {names, Names}, _Opts) ->
    case lists:member(Name, Names) of
        true -> ok;
        false ->
            throw({zone_error, #{
                <<"error">> => <<"zone-not-allowed">>,
                <<"name">> => Name
            }})
    end;
assert_zone_allowed(Name, _Zones, {bootstrap, Entries}, _Opts) ->
    case maps:is_key(Name, Entries) of
        true -> ok;
        false ->
            throw({zone_error, #{
                <<"error">> => <<"zone-not-allowed">>,
                <<"name">> => Name
            }})
    end;
assert_zone_allowed(Name, _Zones, invalid, _Opts) ->
    throw({zone_error, #{
        <<"error">> => <<"invalid-zone-allow">>,
        <<"name">> => Name
    }}).

zone_allow(Opts) ->
    normalize_zone_allow(hb_opts:get(<<"zone-allow">>, 1, Opts)).

zone_init_allow(Opts) ->
    normalize_zone_init_allow(hb_opts:get(<<"zone-init-allow">>, false, Opts)).

normalize_zone_allow(false) -> disabled;
normalize_zone_allow(0) -> disabled;
normalize_zone_allow(<<"false">>) -> disabled;
normalize_zone_allow(<<"0">>) -> disabled;
normalize_zone_allow(true) -> unlimited;
normalize_zone_allow(<<"true">>) -> unlimited;
normalize_zone_allow(1) -> {limit, 1};
normalize_zone_allow(N) when is_integer(N), N > 1 -> {limit, N};
normalize_zone_allow(Bin) when is_binary(Bin) ->
    case catch binary_to_integer(Bin) of
        0 -> disabled;
        N when is_integer(N), N > 0 -> {limit, N};
        _ -> invalid
    end;
normalize_zone_allow([N]) when is_integer(N), N >= 0 ->
    normalize_zone_allow(N);
normalize_zone_allow(Names) when is_list(Names) ->
    case lists:all(fun is_zone_name/1, Names) of
        true -> {names, Names};
        false -> invalid
    end;
normalize_zone_allow(Map) when is_map(Map) ->
    normalize_zone_bootstrap(Map);
normalize_zone_allow(_Other) ->
    invalid.

normalize_zone_bootstrap(Map) ->
    Entries = maps:from_list(
        [
            {Name, PeerURL}
         || {Name, PeerURL} <- maps:to_list(Map),
            is_zone_name(Name),
            is_bootstrap_url(PeerURL)
        ]),
    case map_size(Entries) =:= map_size(Map) of
        true -> {bootstrap, Entries};
        false -> invalid
    end.

is_zone_name(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> true;
is_zone_name(_Other) -> false.

is_bootstrap_url(Bin) when is_binary(Bin), byte_size(Bin) > 0 -> true;
is_bootstrap_url(_Other) -> false.

normalize_zone_init_allow(false) -> disabled;
normalize_zone_init_allow(0) -> disabled;
normalize_zone_init_allow(<<"false">>) -> disabled;
normalize_zone_init_allow(<<"0">>) -> disabled;
normalize_zone_init_allow(true) -> unlimited;
normalize_zone_init_allow(<<"true">>) -> unlimited;
normalize_zone_init_allow(Names) when is_list(Names) ->
    case lists:all(fun is_zone_name/1, Names) of
        true -> {names, Names};
        false -> invalid
    end;
normalize_zone_init_allow(_Other) ->
    invalid.

start_node_opts(Req, Opts) ->
    case hb_maps:get(<<"body">>, Req, undefined, Opts) of
        NodeOpts when is_map(NodeOpts) -> NodeOpts;
        _ -> Opts
    end.

bootstrap_zones(ServerID, Entries) ->
    timer:sleep(1000),
    Results =
        [
            bootstrap_zone(ServerID, Name, PeerURL)
         || {Name, PeerURL} <- maps:to_list(Entries)
        ],
    update_zone_start_status(ServerID, #{
        <<"type">> => <<"zone-start-status">>,
        <<"version">> => <<"1.0">>,
        <<"completed-at-unix">> => erlang:system_time(second),
        <<"results">> => Results
    }).

bootstrap_zone(ServerID, Name, PeerURL) ->
    case wait_for_server_opts(ServerID, 60) of
        Opts when is_map(Opts) ->
            case hb_maps:get(Name, hb_opts:get(<<"zones">>, #{}, Opts),
                             undefined, Opts) of
                Existing when is_map(Existing) ->
                    #{<<"name">> => Name, <<"status">> => <<"already-joined">>};
                _ ->
                    bootstrap_join(ServerID, Name, PeerURL, Opts)
            end;
        _ ->
            #{
                <<"name">> => Name,
                <<"peer-url">> => PeerURL,
                <<"status">> => <<"failed">>,
                <<"error">> => <<"server-unavailable">>
            }
    end.

bootstrap_join(_ServerID, Name, PeerURL, Opts) ->
    Req = #{
        <<"name">> => Name,
        <<"peer-url">> => PeerURL
    },
    case join(#{}, Req, Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            #{
                <<"name">> => Name,
                <<"peer-url">> => PeerURL,
                <<"status">> => <<"joined">>,
                <<"result">> => response_body(Body, Opts)
            };
        {ok, #{<<"status">> := Status, <<"body">> := Body}} ->
            #{
                <<"name">> => Name,
                <<"peer-url">> => PeerURL,
                <<"status">> => <<"failed">>,
                <<"http-status">> => Status,
                <<"error">> => response_body(Body, Opts)
            };
        Other ->
            #{
                <<"name">> => Name,
                <<"peer-url">> => PeerURL,
                <<"status">> => <<"failed">>,
                <<"error">> => hb_util:bin(io_lib:format("~0p", [Other]))
            }
    end.

wait_for_server_opts(_ServerID, 0) ->
    unavailable;
wait_for_server_opts(ServerID, Attempts) ->
    case catch hb_http_server:get_opts(#{<<"http-server">> => ServerID}) of
        Opts when is_map(Opts) -> Opts;
        _ ->
            timer:sleep(500),
            wait_for_server_opts(ServerID, Attempts - 1)
    end.

update_zone_start_status(ServerID, Status) ->
    case wait_for_server_opts(ServerID, 1) of
        Opts when is_map(Opts) ->
            hb_http_server:set_opts(Opts#{<<"zone-start">> => Status});
        _ ->
            ok
    end.

install_ring(Name, Templates0, AES, Wallet, Members, Opts) ->
    Templates = normalize_templates(Templates0, Opts),
    ok = ensure_nonempty_template(Templates),
    Identities = hb_opts:get(identities, #{}, Opts),
    Zones = hb_opts:get(<<"zones">>, #{}, Opts),
    PrivZones = hb_opts:get(<<"priv-zones">>, #{}, Opts),
    Definition = zone_definition(Name, Templates, Wallet, Members, Opts),
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

install_ring_and_storage(Name, Templates, AES, Wallet, Members, Opts) ->
    Opts1 = install_ring(Name, Templates, AES, Wallet, Members, Opts),
    RingAddress = wallet_address(Wallet),
    Opts2 =
        case lib_lapee_nonvolatile:activate(Name, RingAddress, AES, Opts1) of
            {ok, ActivatedOpts} -> ActivatedOpts;
            _ -> Opts1
        end,
    maybe_install_andee_encrypted_volume(Name, RingAddress, AES, Opts, Opts2).

maybe_install_andee_encrypted_volume(Name, RingAddress, AES, OldOpts, RingOpts) ->
    case encrypted_volume_supported()
            andalso encrypted_volume_requested(Name, RingAddress, RingOpts) of
        true ->
            install_encrypted_volume(Name, RingAddress, AES, OldOpts, RingOpts);
        false ->
            RingOpts
    end.

encrypted_volume_supported() ->
    case code:ensure_loaded(hb_store_andee_encrypted) of
        {module, hb_store_andee_encrypted} -> true;
        _ -> false
    end.

install_encrypted_volume(Name, RingAddress, AES, OldOpts, RingOpts) ->
    Store = encrypted_store_spec(Name, RingAddress, RingOpts),
    SecretRef = hb_maps:get(<<"secret-ref">>, Store, undefined, RingOpts),
    ok = hb_store_andee_encrypted:register_secret(SecretRef, AES),
    try
        case encrypted_store_opened_spec(Store, OldOpts) of
            true ->
                case hb_store_andee_encrypted:flush(Store) of
                    ok -> ok;
                    FlushExisting ->
                        encrypted_volume_failed(Name, {flush, FlushExisting})
                end;
            false ->
                ok = start_encrypted_store(Name, Store, RingOpts),
                copy_existing_store_to_encrypted(OldOpts, Store),
                case hb_store:group(Store, <<"/">>, RingOpts) of
                    ok -> ok;
                    {ok, _} -> ok;
                    Other -> encrypted_volume_failed(Name, {persist_root, Other})
                end,
                case hb_store_andee_encrypted:flush(Store) of
                    ok -> ok;
                    FlushError ->
                        encrypted_volume_failed(Name, {flush, FlushError})
                end
        end,
        RingOpts#{
            <<"store">> =>
                prepend_store(Store, hb_opts:get(<<"store">>, [], RingOpts))
        }
    catch
        Class:Reason:Stack ->
            hb_store_andee_encrypted:forget_secret(SecretRef),
            catch hb_store:stop(Store),
            erlang:raise(Class, Reason, Stack)
    end.

start_encrypted_store(Name, Store, Opts) ->
    case hb_store:start(Store, #{}, Opts) of
        ok -> ok;
        {ok, _} -> ok;
        {error, Reason} -> encrypted_volume_failed(Name, Reason);
        {failure, Reason} -> encrypted_volume_failed(Name, Reason)
    end.

encrypted_volume_requested(Name, RingAddress, Opts) ->
    case hb_opts:get(<<"encrypted-volumes">>, false, Opts) of
        true -> true;
        false -> false;
        List when is_list(List) ->
            Identity = zone_identity(Name),
            lists:any(
                fun
                    (Value) when Value =:= Name;
                                 Value =:= RingAddress;
                                 Value =:= Identity ->
                        true;
                    (_) ->
                        false
                end,
                List
            );
        Other ->
            truthy(Other)
    end.

encrypted_store_spec(Name, RingAddress, Opts) ->
    StoreID = encrypted_volume_id(Name, RingAddress),
    #{
        <<"store-module">> => hb_store_andee_encrypted,
        <<"name">> => hb_util:bin(filename:join([
            hb_util:list(encrypted_volume_root(Opts)),
            hb_util:list(<<"zone-", StoreID/binary>>)
        ])),
        <<"zone">> => Name,
        <<"ring-address">> => RingAddress,
        <<"store-id">> => StoreID,
        <<"secret-ref">> => StoreID
    }.

encrypted_volume_root(Opts) ->
    case hb_opts:get(<<"encrypted-volume-root">>, undefined, Opts) of
        Root when is_binary(Root), byte_size(Root) > 0 ->
            Root;
        _ ->
            case os:getenv("ANDEE_ENCRYPTED_STORE_ROOT") of
                false -> <<"build/andee-encrypted-zones">>;
                Root -> hb_util:bin(Root)
            end
    end.

encrypted_volume_id(Name, RingAddress) ->
    hb_util:encode(
        crypto:hash(
            sha256,
            term_to_binary({andee_encrypted_volume, Name, RingAddress})
        )
    ).

encrypted_volume_failed(Name, Reason) ->
    throw({zone_error, #{
        <<"error">> => <<"encrypted-volume-failed">>,
        <<"name">> => Name,
        <<"reason">> => hb_util:bin(io_lib:format("~p", [Reason]))
    }}).

copy_existing_store_to_encrypted(OldOpts, EncryptedStore) ->
    SourceStores = remove_same_store(
        store_list(hb_opts:get(<<"store">>, [], OldOpts)),
        EncryptedStore
    ),
    case SourceStores of
        [] ->
            ok;
        _ ->
            copy_store_path(SourceStores, EncryptedStore, <<"/">>, OldOpts)
    end.

copy_store_path(SourceStores, TargetStore, Path, Opts) ->
    case hb_store:type(SourceStores, Path, Opts) of
        {ok, composite} ->
            hb_store:group(TargetStore, Path, Opts),
            case hb_store:list(SourceStores, Path, Opts) of
                {ok, Children} ->
                    lists:foreach(
                        fun(Child) ->
                            copy_store_path(
                                SourceStores,
                                TargetStore,
                                copy_child_path(Path, Child),
                                Opts
                            )
                        end,
                        Children
                    );
                _ ->
                    ok
            end;
        {ok, simple} ->
            case hb_store:read(SourceStores, Path, Opts) of
                {ok, Value} ->
                    hb_store:write(TargetStore, #{Path => Value}, Opts);
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

copy_child_path(<<"/">>, Child) ->
    hb_path:to_binary(Child);
copy_child_path(Parent, Child) ->
    hb_path:to_binary([Parent, Child]).

prepend_store(Store, Stores0) ->
    [Store | remove_same_store(store_list(Stores0), Store)].

remove_same_store(Stores, Store) ->
    [Existing || Existing <- Stores, not same_store(Existing, Store)].

same_store(
    #{<<"store-module">> := hb_store_andee_encrypted, <<"name">> := Name},
    #{<<"store-module">> := hb_store_andee_encrypted, <<"name">> := Name}
) ->
    true;
same_store(_, _) ->
    false.

store_list(Stores) when is_list(Stores) ->
    Stores;
store_list(Store) when is_map(Store) ->
    [Store];
store_list(_) ->
    [].

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

maybe_add_operator(Proof, Opts) ->
    case hb_opts:get(operator, undefined, Opts) of
        Operator when ?IS_ID(Operator) ->
            Proof#{<<"operator">> => hb_util:human_id(Operator)};
        Operator when is_binary(Operator), byte_size(Operator) > 0 ->
            Proof#{<<"operator">> => Operator};
        _ ->
            Proof
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
    maybe_add_runtime_status(#{
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
            maybe_add_encrypted_volume_status(#{
                <<"type">> => <<"zone-status">>,
                <<"version">> => <<"1.0">>,
                <<"initialized">> => true,
                <<"name">> => Name,
                <<"identity">> => zone_identity(Name),
                <<"zone">> => Zone
            }, Name, Zone, Opts)
    end.

maybe_add_runtime_status(Body, Opts) ->
    maybe_add_nonvolatile_status(maybe_add_start_status(Body, Opts), Opts).

maybe_add_start_status(Body, Opts) ->
    case hb_opts:get(<<"zone-start">>, undefined, Opts) of
        Status when is_map(Status) ->
            Body#{<<"zone-start">> => Status};
        _ ->
            Body
    end.

maybe_add_nonvolatile_status(Body, Opts) ->
    case lib_lapee_nonvolatile:status(Opts) of
        Status when is_map(Status), map_size(Status) > 0 ->
            Body#{<<"nonvolatile-storage">> => Status};
        _ ->
            Body
    end.

maybe_add_encrypted_volume_status(Body, Name, Zone, Opts) ->
    RingAddress = hb_maps:get(<<"ring-address">>, Zone, undefined, Opts),
    case encrypted_volume_supported()
            orelse encrypted_volume_requested(Name, RingAddress, Opts) of
        true ->
            maybe_add_runtime_status(Body#{
                <<"encrypted-volume">> =>
                    encrypted_volume_status(Name, RingAddress, Opts)
            }, Opts);
        false ->
            maybe_add_runtime_status(Body, Opts)
    end.

encrypted_volume_status(Name, RingAddress, Opts) ->
    StoreID =
        case RingAddress of
            B when is_binary(B), byte_size(B) > 0 ->
                encrypted_volume_id(Name, RingAddress);
            _ ->
                null
        end,
    #{
        <<"enabled">> => encrypted_volume_requested(Name, RingAddress, Opts),
        <<"opened">> => encrypted_store_opened(Name, RingAddress, Opts),
        <<"store-id">> => StoreID
    }.

encrypted_store_opened(Name, RingAddress, Opts)
        when is_binary(RingAddress), byte_size(RingAddress) > 0 ->
    encrypted_store_opened_spec(encrypted_store_spec(Name, RingAddress, Opts), Opts);
encrypted_store_opened(_Name, _RingAddress, _Opts) ->
    false.

encrypted_store_opened_spec(Expected, Opts) ->
    lists:any(
        fun(Store) -> same_store(Store, Expected) end,
        store_list(hb_opts:get(<<"store">>, [], Opts))
    ).

zone_definition(Name, Templates0, Wallet, Members, Opts) ->
    Templates = normalize_templates(Templates0, Opts),
    #{
        <<"type">> => <<"zone-definition">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => Name,
        <<"identity">> => zone_identity(Name),
        <<"ring-address">> => wallet_address(Wallet),
        <<"ring-reference">> => ring_reference(Name, Templates, Wallet, Opts),
        <<"template-id">> => template_id(Name, Templates, Opts),
        <<"template">> => first_template(Templates),
        <<"templates">> => Templates,
        <<"members">> => Members
    }.

ring_reference(Name, Templates, Wallet, Opts) ->
    #{
        <<"type">> => <<"zone-ring-reference">>,
        <<"version">> => <<"1.0">>,
        <<"name">> => Name,
        <<"ring-address">> => wallet_address(Wallet),
        <<"template-id">> => template_id(Name, Templates, Opts)
    }.

first_template([Template | _]) -> Template;
first_template([]) -> #{}.

template_id(Name, Templates, Opts) ->
    hb_message:id(
        #{<<"type">> => <<"zone-template">>,
          <<"name">> => Name,
          <<"templates">> => normalize_templates(Templates, Opts)},
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

request_templates(Req, Opts) ->
    Templates = first_defined([
        nonempty_template_value(
            hb_maps:get(<<"templates">>, Req, undefined, Opts)),
        nonempty_template_value(
            hb_maps:get(<<"template">>, Req, undefined, Opts)),
        query_template(Req, Opts)
    ]),
    Clean = normalize_templates(Templates, Opts),
    ok = ensure_nonempty_template(Clean),
    Clean.

nonempty_template_value(Template) when is_map(Template), map_size(Template) > 0 ->
    Template;
nonempty_template_value([_ | _] = Templates) ->
    Templates;
nonempty_template_value(_Other) ->
    undefined.

query_template(Req, Opts) ->
    case hb_maps:get(<<"template-measurement-device">>, Req, undefined, Opts) of
        Device when is_binary(Device), byte_size(Device) > 0 ->
            #{<<"measurement-device">> => Device};
        _ ->
            undefined
    end.

zone_templates(Zone, Opts) when is_map(Zone) ->
    normalize_templates(
        first_defined([
            hb_maps:get(<<"templates">>, Zone, undefined, Opts),
            hb_maps:get(<<"template">>, Zone, #{}, Opts)
        ]),
        Opts);
zone_templates(Template, Opts) ->
    normalize_templates(Template, Opts).

normalize_templates(Templates, Opts) when is_list(Templates) ->
    [clean_template(Template, Opts) || Template <- Templates];
normalize_templates(undefined, Opts) ->
    [clean_template(#{}, Opts)];
normalize_templates(Template, Opts) ->
    [clean_template(Template, Opts)].

zone_identity(Name) ->
    <<?IDENTITY_PREFIX/binary, Name/binary>>.

self_attestation_body(Templates, Opts) ->
    case measurement_boot(Opts) of
        {ok, #{<<"status">> := 200, <<"body">> := Body}} ->
            matching_template(Templates, response_body(Body, Opts), <<"self">>, Opts);
        {ok, Measurement} ->
            matching_template(
                Templates,
                response_body(Measurement, Opts),
                <<"self">>,
                Opts);
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"self-attestation-failed">>
            }})
    end.

matching_template(Templates, Measurement, Subject, Opts) ->
    Candidates =
        [
            {Template, measurement_template_target(Template, Measurement, Opts)}
         || Template <- normalize_templates(Templates, Opts)
        ],
    case [Pair || {Template, Candidate} = Pair <- Candidates,
                  template_matches(Template, Candidate, Opts)] of
        [Match | _] ->
            Match;
        [] ->
            throw_template_mismatch(Templates, hd_or_undefined(Candidates), Subject, Opts)
    end.

template_matches(Template, Candidate, Opts) ->
    case hb_message:match(Template, Candidate, primary, Opts) of
        true -> true;
        _ -> false
    end.

throw_template_mismatch(Templates, {_Template, Candidate}, Subject, Opts) ->
    Mismatches =
        [
            template_mismatch(Template, Candidate, Opts)
         || Template <- normalize_templates(Templates, Opts)
        ],
    throw({zone_error, #{
        <<"error">> => <<"template-mismatch">>,
        <<"subject">> => Subject,
        <<"mismatches">> => Mismatches
    }});
throw_template_mismatch(_Templates, undefined, Subject, _Opts) ->
            throw({zone_error, #{
                <<"error">> => <<"template-mismatch">>,
                <<"subject">> => Subject
            }}).

template_mismatch(Template, Candidate, Opts) ->
    case hb_message:match(Template, Candidate, primary, Opts) of
        {mismatch, _Type, Path, _Expected, _Actual} ->
            #{<<"mismatch-path">> => canonical_mismatch_path(Path)};
        Other ->
            #{<<"mismatch">> => hb_util:bin(io_lib:format("~0p", [Other]))}
    end.

hd_or_undefined([H | _]) -> H;
hd_or_undefined([]) -> undefined.

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

verify_joiner(JoinerURL, _Req, RingReference, Opts) ->
    VerifyReq = #{
        <<"url">> => JoinerURL,
        <<"peer-attestation-scope">> => RingReference
    },
    case measurement_verify_peer(VerifyReq, Opts) of
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
        {flat_true, <<"boot-verified">>, <<"boot-verification">>},
        {flat_true, <<"fresh-verified">>, <<"verification">>},
        {flat_true, <<"freshness-verified">>, <<"freshness">>},
        {flat_true, <<"credential-activation-verified">>,
            <<"credential-activation">>},
        {field_binary, <<"peer-boot-attestation-id">>},
        {field_binary, <<"peer-fresh-attestation-id">>},
        {field_binary, <<"peer-credential-subject-id">>}
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
assert_field(Msg, {flat_true, Key, LegacyOuter}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        true -> ok;
        _ -> assert_field(Msg, {nested_true, LegacyOuter, <<"verified">>}, Bad, Opts)
    end;
assert_field(Msg, {field_bool, Key}, Bad, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_boolean(B) -> ok;
        _ -> Bad(Key)
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
    NotBefore = first_defined([
        hb_maps:get(
            <<"validity-not-before-unix">>, PeerAttestation, undefined, Opts),
        hb_maps:get(<<"not-before-unix">>, Validity, IssuedAt, Opts)
    ]),
    Expires = first_defined([
        hb_maps:get(
            <<"validity-expires-at-unix">>, PeerAttestation, undefined, Opts),
        hb_maps:get(<<"expires-at-unix">>, Validity, undefined, Opts)
    ]),
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
    assert_scope_value(
        <<"peer-scope-name">>, <<"name">>, Scope, RingReference,
        PeerAttestation, Opts),
    assert_scope_value(
        <<"peer-scope-ring-address">>, <<"ring-address">>, Scope,
        RingReference, PeerAttestation, Opts),
    assert_scope_value(
        <<"peer-scope-template-id">>, <<"template-id">>, Scope, RingReference,
        PeerAttestation, Opts),
    PeerURL = strip_trailing_slash(
        hb_maps:get(<<"peer-url">>, PeerAttestation, undefined, Opts)),
    ScopePeerURL = first_defined([
        hb_maps:get(<<"peer-url">>, Scope, undefined, Opts),
        hb_maps:get(<<"peer-url">>, PeerAttestation, undefined, Opts)
    ]),
    case strip_trailing_slash(ScopePeerURL) of
        PeerURL when PeerURL =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.peer-url">>)
    end,
    assert_scope_attestation_id(
        <<"boot-attestation-id">>, <<"peer-boot-attestation">>,
        PeerAttestation, Scope, Opts),
    assert_scope_attestation_id(
        <<"fresh-attestation-id">>, <<"peer-fresh-attestation">>,
        PeerAttestation, Scope, Opts),
    Subject = peer_attestation_payload(
        <<"peer-credential-subject">>, PeerAttestation, Opts),
    ScopeDevice = first_defined([
        hb_maps:get(<<"measurement-device">>, Scope, undefined, Opts),
        hb_maps:get(<<"measurement-device">>, PeerAttestation, undefined, Opts)
    ]),
    SubjectDevice =
        case Subject of
            M when is_map(M) ->
                hb_maps:get(<<"measurement-device">>, M, ScopeDevice, Opts);
            _ ->
                ScopeDevice
        end,
    SubjectID =
        hb_maps:get(
            <<"peer-credential-subject-id">>,
            PeerAttestation,
            undefined,
            Opts),
    ScopeSubjectID = first_defined([
        hb_maps:get(<<"secret-recipient-id">>, Scope, undefined, Opts),
        SubjectID
    ]),
    case {
        ScopeDevice,
        SubjectDevice,
        ScopeSubjectID,
        SubjectID,
        peer_subject_id(Subject, Opts)
    } of
        {Device, Device, ID, ID, ID} when Device =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.secret-recipient">>)
    end.

assert_scope_value(FlatKey, ScopeKey, Scope, RingReference,
                   PeerAttestation, Opts) ->
    Expected = hb_maps:get(ScopeKey, RingReference, undefined, Opts),
    Actual = first_defined([
        hb_maps:get(FlatKey, PeerAttestation, undefined, Opts),
        hb_maps:get(
            ScopeKey,
            hb_maps:get(<<"consumer-scope">>, Scope, #{}, Opts),
            undefined,
            Opts)
    ]),
    case Actual of
        Expected when Expected =/= undefined -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.consumer-scope">>)
    end.

assert_scope_attestation_id(ScopeKey, AttestationKey, PeerAttestation,
                            Scope, Opts) ->
    PayloadID = peer_attestation_payload_id(
        AttestationKey, PeerAttestation, Opts),
    Expected = first_defined([
        hb_maps:get(
            <<AttestationKey/binary, "-id">>,
            PeerAttestation,
            undefined,
            Opts),
        PayloadID
    ]),
    case PayloadID of
        undefined -> ok;
        Expected -> ok;
        _ -> bad_peer_attestation(<<AttestationKey/binary, "-id">>)
    end,
    Actual = first_defined([
        hb_maps:get(ScopeKey, Scope, undefined, Opts),
        hb_maps:get(
            <<AttestationKey/binary, "-id">>,
            PeerAttestation,
            undefined,
            Opts)
    ]),
    case Actual of
        Expected -> ok;
        _ -> bad_peer_attestation(<<"peer-scope.attestation-id">>)
    end.

peer_attestation_payload(Key, PeerAttestation, Opts) ->
    case hb_private:get(Key, PeerAttestation, undefined, Opts) of
        undefined -> hb_maps:get(Key, PeerAttestation, undefined, Opts);
        Value -> Value
    end.

peer_attestation_payload_id(Key, PeerAttestation, Opts) ->
    case peer_attestation_payload(Key, PeerAttestation, Opts) of
        undefined -> undefined;
        Attestation -> attestation_id(response_body(Attestation, Opts), Opts)
    end.

peer_subject_id(Subject, Opts) when is_map(Subject) ->
    Module = measurement_module(Opts),
    Module:secret_recipient_id(Subject, Opts);
peer_subject_id(_Subject, _Opts) ->
    undefined.

attestation_id(Attestation, Opts) when is_map(Attestation) ->
    case hb_maps:get(<<"type">>, Attestation, undefined, Opts) of
        <<"lapee-measurement">> ->
            Module = measurement_module(Opts),
            Module:measurement_id(Attestation, Opts);
        _ ->
            stable_uncommitted_id(
                canonical_authorization_payload(Attestation, Opts),
                Opts)
    end;
attestation_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
attestation_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
attestation_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
attestation_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

peer_boot_attestation_body(Templates, PeerAttestation, Opts) ->
    matching_template(
        Templates,
        response_body(
            peer_attestation_payload(
                <<"peer-boot-attestation">>, PeerAttestation, Opts),
            Opts),
        <<"peer">>,
        Opts).

measurement_template_target(Template, Measurement, Opts) ->
    Candidate = response_body(Measurement, Opts),
    case template_mentions_measurement(Template, Opts) of
        true -> Candidate;
        false -> measurement_body(Candidate, Opts)
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
    AdmitReq = #{
        <<"name">> => required_name(Req, Opts),
        <<"joiner-url">> => SelfURL,
        <<"admission-nonce">> => AdmissionNonce
    },
    try
        admission_response_body(
            lib_permawebos_peer_http:post(
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
    Definition = response_body(
        hb_maps:get(<<"zone">>, Admission, #{}, Opts),
        Opts),
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
    assert_zone_definition_consistent(Definition, RingAddress, Opts),
    case hb_maps:get(<<"ring-address">>, RingReference, undefined, Opts) of
        RingAddress -> ok;
        _ -> bad_admission(<<"ring-reference.ring-address">>)
    end,
    Name = hb_maps:get(<<"name">>, Admission, undefined, Opts),
    case hb_maps:get(<<"name">>, RingReference, undefined, Opts) of
        Name -> ok;
        _ -> bad_admission(<<"ring-reference.name">>)
    end.

assert_zone_definition_consistent(Definition, RingAddress, Opts) ->
    Name = hb_maps:get(<<"name">>, Definition, undefined, Opts),
    case Name of
        B when is_binary(B), byte_size(B) > 0 -> ok;
        _ -> bad_admission(<<"zone.name">>)
    end,
    Templates = zone_templates(Definition, Opts),
    Checks = [
        {<<"type">>, <<"zone-definition">>},
        {<<"version">>, <<"1.0">>},
        {<<"ring-address">>, RingAddress},
        {<<"identity">>, zone_identity(Name)},
        {<<"template-id">>, template_id(Name, Templates, Opts)}
    ],
    lists:foreach(
        fun({Key, Expected}) ->
            case hb_maps:get(Key, Definition, undefined, Opts) of
                Expected when Expected =/= undefined -> ok;
                _ -> bad_admission(<<"zone.", Key/binary>>)
            end
        end,
        Checks).

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
        fun({AuthKey, AdmissionKey}) ->
            Payload = hb_maps:get(AdmissionKey, Admission, undefined, Opts),
            Expected = authorization_payload_id(AuthKey, Payload, Opts),
            case hb_maps:get(AuthKey, Authorization, undefined, Opts) of
                Expected -> ok;
                Actual ->
                    throw({zone_error, #{
                        <<"error">> => <<"admission-invalid">>,
                        <<"field">> => <<"authorization.", AuthKey/binary>>,
                        <<"expected">> => Expected,
                        <<"actual">> => Actual
                    }})
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
    case measurement_unwrap_secret_value(Credential, Opts) of
        {ok, Secret} when is_binary(Secret) ->
            Secret;
        _ ->
            throw({zone_error, #{
                <<"error">> => <<"credential-activation-failed">>
            }})
    end.

measurement_module(Opts) ->
    case hb_device_load:reference(<<"measurement@1.0">>, Opts) of
        {ok, Module} -> Module;
        {error, Reason} ->
            throw({zone_error, #{
                <<"error">> => <<"measurement-device-unavailable">>,
                <<"reason">> => hb_util:bin(Reason)
            }})
    end.

measurement_boot(Opts) ->
    Module = measurement_module(Opts),
    Module:boot(#{}, #{}, Opts).

measurement_verify_peer(Req, Opts) ->
    Module = measurement_module(Opts),
    Module:verify_peer(#{}, Req, Opts).

measurement_wrap_secret(Subject, Secret, Opts) ->
    Module = measurement_module(Opts),
    Module:wrap_secret_for_subject(Subject, Secret, Opts).

measurement_unwrap_secret_value(Credential, Opts) ->
    Module = measurement_module(Opts),
    Module:unwrap_secret_value(Credential, Opts).

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body(Msg, Opts) when is_map(Msg) ->
    Decoded = hb_link:decode_all_links(Msg),
    case {hb_maps:get(<<"type">>, Decoded, undefined, Opts),
          response_wrapper_body(Decoded, Opts)}
    of
        {<<"lapee-measurement">>, Body} when Body =/= undefined ->
            Decoded;
        {_Type, Body} when Body =/= undefined ->
            response_body(Body, Opts);
        _ ->
            Decoded
    end;
response_body(Body, _Opts) ->
    Body.

response_wrapper_body(Msg, Opts) ->
    hb_maps:get(<<"body">>, Msg, undefined, Opts).

response_envelope_body(Msg, Opts) ->
    case hb_maps:get(<<"status">>, Msg, undefined, Opts) of
        undefined -> undefined;
        _Status -> hb_maps:get(<<"body">>, Msg, undefined, Opts)
    end.

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
clean_template(Templates, Opts) when is_list(Templates) ->
    [clean_template(Template, Opts) || Template <- Templates];
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
clean_template_value(Value, Opts) when is_list(Value) ->
    [clean_template_value(Item, Opts) || Item <- Value];
clean_template_value(<<"_">>, _Opts) ->
    '_';
clean_template_value(Value, _Opts) ->
    Value.

ensure_nonempty_template(Template) when is_map(Template),
                                       map_size(Template) > 0 ->
    ok;
ensure_nonempty_template(Templates) when is_list(Templates) ->
    case [Template || Template <- Templates,
                      is_map(Template),
                      map_size(Template) > 0] of
        [_ | _] -> ok;
        [] -> ensure_nonempty_template(undefined)
    end;
ensure_nonempty_template(_Template) ->
    throw({zone_error, #{<<"error">> => <<"empty-template">>}}).

canonical_mismatch_path(<<"/", _/binary>> = Path) ->
    Path;
canonical_mismatch_path(Path) when is_binary(Path) ->
    <<"/", Path/binary>>.

truthy(true) -> true;
truthy(<<"true">>) -> true;
truthy(<<"1">>) -> true;
truthy(1) -> true;
truthy(_) -> false.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

zone_allow_values_test() ->
    ?assertEqual(disabled, normalize_zone_allow(false)),
    ?assertEqual(disabled, normalize_zone_allow(0)),
    ?assertEqual({limit, 1}, normalize_zone_allow(1)),
    ?assertEqual({limit, 3}, normalize_zone_allow(3)),
    ?assertEqual({limit, 2}, normalize_zone_allow([2])),
    ?assertEqual(unlimited, normalize_zone_allow(true)),
    ?assertEqual({names, [<<"alpha">>, <<"beta">>]},
                 normalize_zone_allow([<<"alpha">>, <<"beta">>])),
    ?assertEqual({bootstrap, #{<<"alpha">> => <<"http://peer">>}},
                 normalize_zone_allow(#{<<"alpha">> => <<"http://peer">>})).

zone_allow_policy_test() ->
    ?assertEqual(ok, assert_zone_install_allowed(<<"alpha">>, #{})),
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"zone-limit-exceeded">>}},
        assert_zone_install_allowed(
            <<"beta">>,
            #{<<"zones">> => #{<<"alpha">> => #{}}})),
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"zone-not-allowed">>}},
        assert_zone_install_allowed(
            <<"beta">>,
            #{<<"zone-allow">> => [<<"alpha">>]})),
    ?assertEqual(
        ok,
        assert_zone_install_allowed(
            <<"alpha">>,
            #{<<"zone-allow">> => [<<"alpha">>]})).

nonvolatile_store_blocks_different_zone_test() ->
    Mounted = #{
        <<"mounted">> => true,
        <<"zone">> => <<"alpha">>,
        <<"ring-address">> => <<"ring-a">>
    },
    ?assertEqual(
        ok,
        assert_zone_install_allowed(<<"beta">>, #{<<"zone-allow">> => 2})),
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"nonvolatile-zone-conflict">>}},
        assert_zone_install_allowed(
            <<"beta">>,
            #{
                <<"zone-allow">> => 2,
                <<"lapee-nonvolatile-status">> => Mounted
            })).

zone_init_allow_policy_test() ->
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"zone-init-disabled">>}},
        assert_zone_initialization_allowed(<<"alpha">>, #{})),
    ?assertEqual(
        ok,
        assert_zone_initialization_allowed(
            <<"alpha">>,
            #{<<"zone-init-allow">> => true})),
    ?assertEqual(
        ok,
        assert_zone_initialization_allowed(
            <<"alpha">>,
            #{<<"zone-init-allow">> => [<<"alpha">>]})),
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"zone-init-not-allowed">>}},
        assert_zone_initialization_allowed(
            <<"beta">>,
            #{<<"zone-init-allow">> => [<<"alpha">>]})),
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"invalid-zone-init-allow">>}},
        assert_zone_initialization_allowed(
            <<"alpha">>,
            #{<<"zone-init-allow">> => 1})).

alternative_templates_match_first_viable_test() ->
    Measurement = #{
        <<"type">> => <<"lapee-measurement">>,
        <<"measurement-device">> => <<"andee@1.0">>,
        <<"body">> => #{
            <<"node">> => #{<<"initialized">> => <<"permanent">>}
        }
    },
    AndeeTemplate = #{<<"measurement-device">> => <<"andee@1.0">>},
    {_Template, Candidate} =
        matching_template(
            [
                #{<<"measurement-device">> => <<"snp@1.0">>},
                AndeeTemplate
            ],
            Measurement,
            <<"test">>,
            #{}
        ),
    ?assertEqual(<<"andee@1.0">>,
                 hb_maps:get(<<"measurement-device">>, Candidate, undefined, #{})).

rejected_peer_attestations_never_admit_test() ->
    Now = erlang:system_time(second),
    RingReference = #{
        <<"name">> => <<"book-shelf">>,
        <<"ring-address">> => <<"ring">>,
        <<"template-id">> => <<"template">>
    },
    Rejected = #{
        <<"type">> => <<"zone-peer-attestation">>,
        <<"issued-at-unix">> => Now,
        <<"validity-not-before-unix">> => Now - 1,
        <<"validity-expires-at-unix">> => Now + 60,
        <<"peer-scope-name">> => <<"book-shelf">>,
        <<"peer-scope-ring-address">> => <<"ring">>,
        <<"peer-scope-template-id">> => <<"template">>,
        <<"boot-verified">> => false,
        <<"fresh-verified">> => false,
        <<"allow-rejected-peer-attestation">> => true,
        <<"freshness-verified">> => true,
        <<"credential-activation-verified">> => true,
        <<"peer-boot-attestation-id">> => <<"boot">>,
        <<"peer-fresh-attestation-id">> => <<"fresh">>,
        <<"peer-credential-subject-id">> => <<"subject">>
    },
    ?assertThrow(
        {zone_error, #{<<"error">> := <<"peer-attestation-invalid">>}},
        assert_peer_attestation_body(Rejected, RingReference, #{})).

-endif.
