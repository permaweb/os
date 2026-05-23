%%% @doc Common PermawebOS hardware-measurement protocol.
%%%
%%% This device owns the standard measured subject:
%%% `#{<<"system">> => ~system@1.0/all, <<"node">> => ~meta@1.0/info}'.
%%% TPM, SNP, HandEE, and later engines supply only native evidence and
%%% recipient handling. Policy stays outside the device; measurements expose
%%% facts and provenance as signed AO-Core messages.
-module(dev_measurement).
-implements(<<"measurement@1.0">>).
-device_libraries([lib_permawebos_peer_http]).
-export([info/1, info/3, boot/3, fresh/3, verify/3, verify_peer/3,
         unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         measurement_body/1, measurement_body_id/2]).

-include_lib("hb/include/hb.hrl").

-define(VERSION, <<"1.0">>).
-define(TYPE, <<"lapee-measurement">>).
-define(BOOT_PATH, <<"~measurement@1.0/boot">>).
-define(PEER_ATTESTATION_PREFIX,
        <<"~measurement@1.0/peer-attestations">>).
-define(DEFAULT_DEVICES, [<<"snp@1.0">>, <<"tpm@2.0a">>, <<"handee@1.0">>]).
-define(DEFAULT_TIMEOUT_MS, 30000).

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"boot">>,
            <<"fresh">>,
            <<"verify">>,
            <<"verify-peer">>,
            <<"unwrap-secret">>
        ]
    }.

info(_Base, _Req, Opts) ->
    {Selected, Reason} = selected_device_or_reason(Opts),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"version">> => ?VERSION,
            <<"selected-measurement-device">> => Selected,
            <<"selection-reason">> => Reason,
            <<"available-candidates">> => candidate_devices(Opts)
        }
    }}.

boot(_Base, _Req, Opts) ->
    case persistent_term:get({dev_measurement, boot}, undefined) of
        Msg when is_map(Msg) ->
            {ok,
                materialize_measurement(
                    publish_cached_measurement(Msg, Opts),
                    Opts
                )};
        undefined ->
            global:trans(
                {dev_measurement, boot},
                fun() -> boot_locked(Opts) end,
                [node()])
    end.

boot_locked(Opts) ->
    case persistent_term:get({dev_measurement, boot}, undefined) of
        Msg when is_map(Msg) ->
            {ok,
                materialize_measurement(
                    publish_cached_measurement(Msg, Opts),
                    Opts
                )};
        undefined ->
            case generate_measurement(boot, #{}, Opts) of
                {ok, Signed0} ->
                    Signed = cacheable_measurement(Signed0, Opts),
                    persistent_term:put({dev_measurement, boot}, Signed),
                    publish_cached_measurement(Signed, Opts),
                    {ok, materialize_measurement(Signed, Opts)};
                {error, Reason} ->
                    error_resp(500, <<"measurement-boot-failed">>, Reason)
            end
    end.

cacheable_measurement(Msg, Opts) ->
    materialize_peer_value(Msg, Opts).

publish_cached_measurement(Msg, Opts) ->
    SignedID = hb_message:id(Msg, signed, Opts),
    {ok, _UnsignedID} = hb_cache:write(Msg, Opts),
    ok = hb_cache:link(SignedID, ?BOOT_PATH, Opts),
    Msg.

fresh(_Base, Req, Opts) ->
    case generate_measurement(fresh, Req, Opts) of
        {ok, Signed} ->
            {ok, materialize_measurement(Signed, Opts)};
        {error, Reason} ->
            error_resp(500, <<"measurement-fresh-failed">>, Reason)
    end.

verify(Base, Req, Opts) ->
    Measurement = materialize_peer_measurement(
        response_body(resolve_envelope(Base, Req, Opts), Opts),
        Opts),
    Device = measurement_device(Measurement, Opts),
    resolve_device_response(
        Device,
        <<"verify">>,
        Req#{<<"envelope">> => Measurement},
        Opts).

verify_peer(_Base, Req, Opts) ->
    case peer_url(Req, Opts) of
        undefined ->
            error_resp(400, <<"missing-peer-url">>,
                       <<"verify-peer requires `url' or `peer'.">>);
        Url0 ->
            Url = strip_trailing_slash(Url0),
            case verify_peer_url(Url, Req, Opts) of
                {ok, Signed} ->
                    {ok, #{<<"status">> => 200, <<"body">> => Signed}};
                {error, #{<<"status">> := _} = Body} ->
                    {ok, Body};
                {error, Reason} ->
                    error_resp(502, <<"measurement-verify-peer-failed">>,
                               Reason)
            end
    end.

unwrap_secret(_Base, Req, Opts) ->
    with_ok(
        fun() ->
            % Bundled HTTPSig requests can carry transport links; only the
            % credential is part of the secret-recipient contract.
            Credential0 = credential_from_request(Req, Opts),
            Credential = materialize_peer_value(Credential0, Opts),
            Device = measurement_device(Credential, Opts),
            resolve_device_body(Device, <<"unwrap-secret">>, Credential, Opts)
        end,
        <<"unwrap-secret-failed">>).

credential_from_request(Req, Opts) when is_map(Req) ->
    case credential_reference_from_request(Req, Opts) of
        {NodeURL, CredentialID} ->
            fetch_linked_credential(NodeURL, CredentialID, Opts);
        undefined ->
            credential_body_from_request(Req, Opts)
    end;
credential_from_request(Req, _Opts) ->
    Req.

credential_body_from_request(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"credential">>, Req, undefined, Opts),
        hb_maps:get(<<"wrapped-secret">>, Req, undefined, Opts)
    ]) of
        undefined ->
            Body = hb_maps:get(<<"body">>, Req, undefined, Opts),
            case Body of
                BodyMap when is_map(BodyMap) ->
                    case first_defined([
                        hb_maps:get(<<"credential">>, BodyMap, undefined, Opts),
                        hb_maps:get(<<"wrapped-secret">>, BodyMap, undefined, Opts)
                    ]) of
                        undefined -> BodyMap;
                        Credential -> Credential
                    end;
                _ -> Req
            end;
        Credential ->
            Credential
    end.

credential_reference_from_request(Req, Opts) ->
    case {
        first_defined([
            hb_maps:get(<<"credential-node-url">>, Req, undefined, Opts),
            hb_maps:get(<<"credential-source-url">>, Req, undefined, Opts)
        ]),
        hb_maps:get(<<"credential-id">>, Req, undefined, Opts)
    } of
        {NodeURL, CredentialID}
                when is_binary(NodeURL), byte_size(NodeURL) > 0,
                     is_binary(CredentialID), byte_size(CredentialID) > 0 ->
            {strip_trailing_slash(NodeURL), CredentialID};
        _ ->
            undefined
    end.

fetch_linked_credential(NodeURL, CredentialID, Opts) ->
    PeerOpts = lib_permawebos_peer_http:peer_opts(NodeURL, Opts),
    materialize_peer_value(
        response_body(
            lib_permawebos_peer_http:get(
                NodeURL,
                credential_json_path(CredentialID),
                Opts),
            PeerOpts),
        PeerOpts).

credential_path(<<"/", _/binary>> = Path) -> Path;
credential_path(ID) -> <<"/", ID/binary>>.

credential_json_path(CredentialID) ->
    Path = credential_path(CredentialID),
    <<Path/binary, "?accept=application%2Fjson">>.

generate_measurement(Purpose, Req, Opts) ->
    with_raw_ok(fun() ->
        Body = measurement_body(Opts),
        Device = selected_device(Opts),
        Recipient = timed(
            <<"measurement-subject">>,
            fun() ->
                resolve_device_body(
                    Device,
                    <<"subject">>,
                    #{<<"body">> => Body},
                    Opts)
            end,
            Opts),
        Evidence = timed(
            <<"measurement-evidence">>,
            fun() ->
                resolve_device_body(
                    Device,
                    <<"measure">>,
                    #{
                        <<"body">> => Body,
                        <<"nonce">> => nonce_for(Purpose, Req, Opts),
                        <<"purpose">> => purpose_name(Purpose),
                        <<"secret-recipient">> => Recipient
                    },
                    Opts)
            end,
            Opts),
        {ok, hb_message:commit(
            #{
                <<"type">> => ?TYPE,
                <<"version">> => ?VERSION,
                <<"issued-at-unix">> => erlang:system_time(second),
                <<"measurement-device">> => Device,
                <<"body">> => Body,
                <<"evidence">> => Evidence,
                <<"secret-recipient">> => Recipient
            },
            Opts)}
    end).

measurement_body(Opts) ->
    case persistent_term:get({dev_measurement, body}, undefined) of
        Body when is_map(Body) ->
            Body;
        undefined ->
            measurement_body_locked(Opts)
    end.

measurement_body_locked(Opts) ->
    case persistent_term:get({dev_measurement, body}, undefined) of
        Body when is_map(Body) ->
            Body;
        undefined ->
            System = timed(
                <<"system-report">>,
                fun() ->
                    resolve_body(hb_ao:resolve(<<"~system@1.0/all">>, Opts))
                end,
                Opts),
            Node0 = timed(
                <<"node-message">>,
                fun() ->
                    resolve_body(hb_ao:resolve(<<"~meta@1.0/info">>, Opts))
                end,
                Opts),
            Body = canonical_payload(
                #{<<"system">> => System, <<"node">> => Node0},
                Opts),
            persistent_term:put({dev_measurement, body}, Body),
            persistent_term:put(
                {dev_measurement, body_id},
                measurement_body_id(Body, Opts)),
            Body
    end.

measurement_body_id(Body, Opts) when is_map(Body) ->
    stable_id(Body, Opts).

verify_peer_url(Url, Req, Opts) ->
    with_raw_ok(fun() ->
        PeerOpts = lib_permawebos_peer_http:peer_opts(Url, Opts),
        Boot = peer_measurement_payload(response_body(
            lib_permawebos_peer_http:get(Url, <<"/~measurement@1.0/boot">>, Opts),
            PeerOpts), PeerOpts),
        FreshNonce = crypto:strong_rand_bytes(32),
        Fresh = peer_measurement_payload(response_body(
            lib_permawebos_peer_http:get(
                Url,
                <<"/~measurement@1.0/fresh?nonce=",
                  (hb_util:encode(FreshNonce))/binary>>,
                Opts),
            PeerOpts), PeerOpts),
        ok = ensure_measurement_shape(Boot),
        ok = ensure_measurement_shape(Fresh),
        Subject = secret_recipient(Boot, Opts),
        ok = ensure_same_subject(Boot, Fresh, Opts),
        ok = ensure_subject_matches_measurement(Subject, Boot, Opts),
        ok = ensure_subject_matches_measurement(Subject, Fresh, Opts),
        AllowRejected = allow_rejected_peer_attestation(Req, Opts),
        BootVerify = verify_measurement_body(
            <<"boot-verification">>, Boot, Req, AllowRejected, Opts),
        FreshVerify = verify_measurement_body(
            <<"fresh-verification">>,
            Fresh,
            Req#{<<"nonce">> => hb_util:encode(FreshNonce)},
            AllowRejected,
            Opts),
        Challenge = crypto:strong_rand_bytes(32),
        Credential = wrap_secret_for_subject(Subject, Challenge, Opts),
        Activation = activate_peer_secret(Url, Credential, Req, Opts),
        ok = ensure_secret_activation(
            Activation, Credential, Challenge, Subject, Opts),
        Now = erlang:system_time(second),
        SubjectID = secret_recipient_id(Subject, Opts),
        BootID = measurement_id(Boot, Opts),
        FreshID = measurement_id(Fresh, Opts),
        Validity = peer_attestation_validity(Now, Req, Opts),
        ConsumerScope =
            hb_maps:get(<<"peer-attestation-scope">>, Req, #{}, Opts),
        Signed0 = hb_message:commit(
            #{
                <<"type">> => <<"zone-peer-attestation">>,
                <<"version">> => <<"1.0">>,
                <<"issued-at-unix">> => Now,
                <<"measurement-device">> => measurement_device(Boot, Opts),
                <<"secret-method">> =>
                    hb_maps:get(<<"method">>, Subject, null, Opts),
                <<"validity-not-before-unix">> =>
                    hb_maps:get(<<"not-before-unix">>, Validity, Now, Opts),
                <<"validity-expires-at-unix">> =>
                    hb_maps:get(<<"expires-at-unix">>, Validity, Now, Opts),
                <<"peer-url">> => Url,
                <<"peer-scope-name">> =>
                    hb_maps:get(<<"name">>, ConsumerScope, null, Opts),
                <<"peer-scope-ring-address">> =>
                    hb_maps:get(<<"ring-address">>, ConsumerScope, null, Opts),
                <<"peer-scope-template-id">> =>
                    hb_maps:get(<<"template-id">>, ConsumerScope, null, Opts),
                <<"peer-boot-attestation-id">> => BootID,
                <<"peer-fresh-attestation-id">> => FreshID,
                <<"peer-credential-subject-id">> => SubjectID,
                <<"peer-secret-subject-id">> => SubjectID,
                <<"boot-verified">> =>
                    hb_maps:get(<<"verified">>, BootVerify, false, Opts),
                <<"fresh-verified">> =>
                    hb_maps:get(<<"verified">>, FreshVerify, false, Opts),
                <<"allow-rejected-peer-attestation">> => AllowRejected,
                <<"freshness-verified">> => true,
                <<"nonce-sha256">> =>
                    hb_util:encode(crypto:hash(sha256, FreshNonce)),
                <<"credential-activation-verified">> => true,
                <<"challenge-sha256">> =>
                    hb_util:encode(crypto:hash(sha256, Challenge))
            },
            Opts,
            <<"httpsig@1.0">>),
        ok = store_peer_attestation(Signed0, Opts),
        Signed = hb_private:set(Signed0, #{
            <<"peer-boot-attestation">> => Boot,
            <<"peer-fresh-attestation">> => Fresh,
            <<"peer-credential-subject">> => Subject,
            <<"credential">> => Credential,
            <<"secret-activation">> => Activation,
            <<"boot-verification">> => BootVerify,
            <<"fresh-verification">> => FreshVerify
        }, Opts),
        {ok, Signed}
    end).

peer_measurement_payload(Msg, Opts) ->
    materialize_peer_measurement(
        response_body(Msg, Opts),
        Opts).

materialize_peer_measurement(Measurement, Opts) when is_map(Measurement) ->
    materialize_peer_value(Measurement, Opts);
materialize_peer_measurement(Measurement, _Opts) ->
    Measurement.

materialize_peer_value(Value, Opts) ->
    materialize_peer_value(Value, Opts, 8).

materialize_peer_value(Value, Opts, Remaining) ->
    Loaded = hb_cache:ensure_all_loaded(decode_links_deep(Value), Opts),
    case Remaining =< 0 orelse Loaded =:= Value of
        true -> Loaded;
        false -> materialize_peer_value(Loaded, Opts, Remaining - 1)
    end.

normalize_top_keys(Msg) when is_map(Msg) ->
    maps:from_list(
        [{normalize_key(Key), Value} || {Key, Value} <- maps:to_list(Msg)]);
normalize_top_keys(Value) ->
    Value.

normalize_key(Key) when is_atom(Key) -> atom_to_binary(Key, utf8);
normalize_key(Key) -> Key.

verify_measurement_body(Label, Measurement, Req, AllowRejected, Opts) ->
    {ok, #{<<"status">> := 200, <<"body">> := Body}} =
        verify(Measurement, Req#{<<"envelope">> => Measurement}, Opts),
    case hb_maps:get(<<"verified">>, Body, false, Opts) of
        true -> Body;
        false when AllowRejected ->
            Body;
        false ->
            throw({measurement_error,
                   #{Label => verification_failure(Measurement, Body, Opts)}})
    end.

allow_rejected_peer_attestation(Req, Opts) ->
    RequestAllows = truthy(first_defined([
        hb_maps:get(<<"allow-rejected-peer-attestation">>, Req, undefined, Opts),
        hb_maps:get(<<"allow-rejected">>, Req, undefined, Opts)
    ])),
    ConfigAllows = truthy(
        hb_opts:get(<<"allow-rejected-peer-attestation">>, false, Opts)),
    RequestAllows andalso ConfigAllows.

truthy(true) -> true;
truthy(<<"true">>) -> true;
truthy(<<"1">>) -> true;
truthy(1) -> true;
truthy(_) -> false.

verification_failure(Measurement, Verification, Opts) ->
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    #{
        <<"verification">> => Verification,
        <<"measurement-type">> =>
            hb_maps:get(<<"type">>, Measurement, undefined, Opts),
        <<"measurement-keys">> => sorted_binary_keys(Measurement),
        <<"evidence-keys">> => sorted_binary_keys(Evidence)
    }.

sorted_binary_keys(Msg) when is_map(Msg) ->
    lists:sort([hb_util:bin(Key) || Key <- maps:keys(Msg)]);
sorted_binary_keys(_Value) ->
    [].

wrap_secret_for_subject(Subject, Secret, Opts) when is_map(Subject) ->
    Device = measurement_device(Subject, Opts),
    {ok, Module} = hb_device_load:reference(Device, Opts),
    case Device of
        <<"tpm@2.0a">> ->
            (Module:make_credential_for_subject(Subject, Secret))#{
                <<"type">> => <<"lapee-wrapped-secret">>,
                <<"measurement-device">> => Device,
                <<"method">> => <<"tpm2-activate-credential">>,
                <<"subject-id">> => stable_id(Subject, Opts)
            };
        <<"snp@1.0">> ->
            Module:wrap_secret_for_subject(Subject, Secret, Opts);
        <<"handee@1.0">> ->
            Module:wrap_secret_for_subject(Subject, Secret, Opts);
        _ ->
            resolve_device_body(
                Device,
                <<"wrap-secret">>,
                #{
                    <<"subject">> => Subject,
                    <<"secret">> => hb_util:encode(Secret)
                },
                Opts)
    end.

unwrap_secret_value(Credential, Opts) when is_map(Credential) ->
    Device = measurement_device(Credential, Opts),
    {ok, Module} = hb_device_load:reference(Device, Opts),
    case Device of
        <<"tpm@2.0a">> -> Module:activate_credential_secret(Credential, Opts);
        <<"snp@1.0">> -> Module:unwrap_secret_value(Credential, Opts);
        <<"handee@1.0">> -> Module:unwrap_secret_value(Credential, Opts);
        Device ->
            throw({measurement_error,
                   #{<<"unwrap-secret">> =>
                        <<"No local raw-secret helper for ", Device/binary>>}})
    end.

activate_peer_secret(Url, Credential, Req, Opts) ->
    case credential_source_url(Req, Opts) of
        undefined ->
            activate_peer_secret_body(Url, Credential, Opts);
        SourceURL ->
            activate_peer_secret_link(Url, Credential, SourceURL, Opts)
    end.

activate_peer_secret_body(Url, Credential, Opts) ->
    PeerOpts = lib_permawebos_peer_http:peer_opts(Url, Opts),
    materialize_peer_value(response_body(
        lib_permawebos_peer_http:post(
            Url,
            <<"/~measurement@1.0/unwrap-secret">>,
            #{<<"credential">> => Credential},
            Opts),
        PeerOpts), PeerOpts).

activate_peer_secret_link(Url, Credential, SourceURL, Opts) ->
    {ok, CredentialID} = hb_cache:write(Credential, Opts),
    PeerOpts = lib_permawebos_peer_http:peer_opts(Url, Opts),
    materialize_peer_value(response_body(
        lib_permawebos_peer_http:get(
            Url,
            <<"/~measurement@1.0/unwrap-secret?credential-node-url=",
              (uri_string:quote(strip_trailing_slash(SourceURL)))/binary,
              "&credential-id=",
              (uri_string:quote(CredentialID))/binary>>,
            Opts),
        PeerOpts), PeerOpts).

credential_source_url(Req, Opts) ->
    case first_defined([
        hb_maps:get(<<"credential-source-url">>, Req, undefined, Opts),
        hb_maps:get(<<"secret-source-url">>, Req, undefined, Opts),
        hb_opts:get(<<"credential-source-url">>, undefined, Opts)
    ]) of
        B when is_binary(B), byte_size(B) > 0 -> strip_trailing_slash(B);
        _ -> undefined
    end.

ensure_secret_activation(Activation, Credential, Expected, Subject, Opts) ->
    Device = measurement_device(Credential, Opts),
    {ok, Module} = hb_device_load:reference(Device, Opts),
    case Device of
        <<"tpm@2.0a">> ->
            Module:ensure_activation_secret(
                Activation, Credential, Expected, Subject, Opts);
        <<"snp@1.0">> ->
            Module:ensure_secret_activation(
                Activation, Credential, Expected, Subject, Opts);
        <<"handee@1.0">> ->
            Module:ensure_secret_activation(
                Activation, Credential, Expected, Subject, Opts);
        _ ->
            ExpectedHash = hb_util:encode(crypto:hash(sha256, Expected)),
            case hb_maps:get(
                    <<"credential-secret-sha256">>,
                    Activation,
                    undefined,
                    Opts) of
                ExpectedHash -> ok;
                _ ->
                    throw({measurement_error,
                           #{<<"secret-activation">> =>
                                <<"activation proof did not match">>}})
            end
    end.

ensure_measurement_shape(Measurement) when is_map(Measurement) ->
    case {
        hb_maps:get(<<"type">>, Measurement, undefined, #{}),
        hb_maps:get(<<"body">>, Measurement, undefined, #{}),
        hb_maps:get(<<"evidence">>, Measurement, undefined, #{}),
        hb_maps:get(<<"secret-recipient">>, Measurement, undefined, #{})
    } of
        {?TYPE, Body, Evidence, Recipient}
                when is_map(Body), is_map(Evidence), is_map(Recipient) ->
            ok;
        _ ->
            throw({measurement_error,
                   #{<<"measurement">> => <<"invalid measurement shape">>}})
    end.

secret_recipient(Measurement, Opts) ->
    case hb_maps:get(<<"secret-recipient">>, Measurement, undefined, Opts) of
        Recipient when is_map(Recipient) -> Recipient;
        _ ->
            throw({measurement_error,
                   #{<<"secret-recipient">> => <<"missing">>}})
    end.

ensure_same_subject(A, B, Opts) ->
    case {measurement_body_id(hb_maps:get(<<"body">>, A, #{}, Opts), Opts),
          measurement_body_id(hb_maps:get(<<"body">>, B, #{}, Opts), Opts)} of
        {ID, ID} when is_binary(ID), byte_size(ID) > 0 -> ok;
        _ ->
            throw({measurement_error,
                   #{<<"measurement">> =>
                        <<"boot and fresh subjects differ">>}})
    end.

ensure_subject_matches_measurement(Subject, Measurement, Opts) ->
    Recipient = hb_maps:get(<<"secret-recipient">>, Measurement, #{}, Opts),
    SubjectDevice = measurement_device(Subject, Opts),
    MeasurementDevice = measurement_device(Measurement, Opts),
    SubjectID = secret_recipient_id(Subject, Opts),
    RecipientID = secret_recipient_id(Recipient, Opts),
    case {SubjectDevice, MeasurementDevice, SubjectID, RecipientID} of
        {Device, Device, ID, ID} -> ok;
        _ ->
            throw({measurement_error,
                   #{
                       <<"secret-recipient">> =>
                           <<"subject does not match measurement recipient">>,
                       <<"subject-device">> => SubjectDevice,
                       <<"measurement-device">> => MeasurementDevice,
                       <<"subject-id">> => SubjectID,
                       <<"recipient-id">> => RecipientID,
                       <<"subject-identity">> =>
                           secret_recipient_identity(Subject, Opts),
                       <<"recipient-identity">> =>
                           secret_recipient_identity(Recipient, Opts)
                   }})
    end.

store_peer_attestation(Signed, Opts) ->
    ID =
        case committed_message_id(Signed, Opts) of
            undefined -> hb_message:id(Signed, signed, Opts);
            SignedID -> SignedID
        end,
    {ok, _} = hb_cache:write(Signed, Opts),
    Path = <<?PEER_ATTESTATION_PREFIX/binary, "/", ID/binary>>,
    ok = hb_cache:link(ID, Path, Opts),
    ok.

selected_device(Opts) ->
    case selected_device_or_reason(Opts) of
        {D, _} when is_binary(D), D =/= <<"unavailable">> -> D;
        {_, Reason} -> throw({measurement_error, Reason})
    end.

selected_device_or_reason(Opts) ->
    case configured_device(Opts) of
        auto -> auto_device(Opts);
        Device when is_binary(Device) ->
            case device_supported(Device, Opts) of
                true -> {Device, <<"configured">>};
                false -> {<<"unavailable">>, #{Device => <<"not-supported">>}}
            end
    end.

configured_device(Opts) ->
    case hb_opts:get(<<"measurement-device">>, undefined, Opts) of
        undefined -> auto;
        <<"auto">> -> auto;
        auto -> auto;
        Device when is_binary(Device) -> Device;
        Device when is_atom(Device) -> atom_to_binary(Device, utf8);
        Other -> hb_util:bin(Other)
    end.

auto_device(Opts) ->
    case [D || D <- candidate_device_names(Opts), device_supported(D, Opts)] of
        [D | _] -> {D, <<"auto">>};
        [] -> {<<"unavailable">>, <<"no measurement device supported">>}
    end.

candidate_devices(Opts) ->
    [#{<<"device">> => D, <<"supported">> => device_supported(D, Opts)}
     || D <- candidate_device_names(Opts)].

candidate_device_names(Opts) ->
    normalize_device_names(
        hb_opts:get(<<"measurement-devices">>, ?DEFAULT_DEVICES, Opts)).

normalize_device_names(Devices) when is_list(Devices) ->
    [normalize_device_name(Device) || Device <- Devices];
normalize_device_names(Device) ->
    [normalize_device_name(Device)].

normalize_device_name(Device) when is_binary(Device) -> Device;
normalize_device_name(Device) when is_atom(Device) -> atom_to_binary(Device, utf8);
normalize_device_name(Device) -> hb_util:bin(Device).

device_supported(Device, Opts) ->
    try resolve_device_body(Device, <<"supported">>, #{}, Opts) of
        true -> true;
        #{<<"supported">> := true} -> true;
        _ -> false
    catch _:_ ->
        false
    end.

measurement_device(Msg, Opts) when is_map(Msg) ->
    case hb_maps:get(<<"measurement-device">>, Msg, undefined, Opts) of
        D when is_binary(D), byte_size(D) > 0 -> D;
        _ ->
            case hb_maps:get(<<"secret-recipient">>, Msg, undefined, Opts) of
                R when is_map(R) -> measurement_device(R, Opts);
                _ -> selected_device(Opts)
            end
    end.

resolve_device_body(Device, Path, Req, Opts) ->
    response_body(resolve_device_response(Device, Path, Req, Opts), Opts).

resolve_device_response(Device, Path, Req, Opts) ->
    case measurement_export(Path) of
        Fun when Fun =/= undefined ->
            case hb_device_load:reference(Device, Opts) of
                {ok, Module} -> apply(Module, Fun, [#{}, Req, Opts]);
                {error, _} ->
                    hb_ao:resolve(
                        #{<<"device">> => Device},
                        Req#{<<"path">> => Path},
                        Opts)
            end;
        _ ->
            hb_ao:resolve(
                #{<<"device">> => Device},
                Req#{<<"path">> => Path},
                Opts)
    end.

measurement_export(<<"supported">>) -> supported;
measurement_export(<<"subject">>) -> subject;
measurement_export(<<"measure">>) -> measure;
measurement_export(<<"verify">>) -> verify;
measurement_export(<<"wrap-secret">>) -> wrap_secret;
measurement_export(<<"unwrap-secret">>) -> unwrap_secret;
measurement_export(_Path) -> undefined.

resolve_envelope(Base, Req, Opts) when is_map(Base) ->
    case hb_maps:get(<<"envelope">>, Req, undefined, Opts) of
        E when is_map(E) -> E;
        _ ->
            case hb_maps:get(<<"type">>, Base, undefined, Opts) of
                ?TYPE ->
                    Base;
                _ ->
                    case hb_maps:get(<<"body">>, Base, undefined, Opts) of
                        Inner when is_map(Inner) -> Inner;
                        _ -> Base
                    end
            end
    end;
resolve_envelope(_Base, Req, Opts) ->
    hb_maps:get(<<"envelope">>, Req, #{}, Opts).

resolve_body({ok, #{<<"body">> := Body}}) -> Body;
resolve_body({ok, Msg}) -> Msg;
resolve_body({error, Reason}) -> throw({measurement_error, Reason});
resolve_body(Other) -> throw({measurement_error, Other}).

timed(Name, Fun, Opts) ->
    Timeout = hb_opts:get(
        <<"measurement-timeout-ms">>,
        ?DEFAULT_TIMEOUT_MS,
        Opts),
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Parent ! {Ref,
            try {ok, Fun()}
            catch
                throw:Reason ->
                    {throw, Reason};
                Class:Reason:Stack ->
                    {error, #{
                        <<"class">> => hb_util:bin(Class),
                        <<"reason">> => reason_to_text(Reason),
                        <<"stack">> => reason_to_text(Stack)
                    }}
            end}
    end),
    receive
        {Ref, {ok, Value}} ->
            Value;
        {Ref, {throw, Reason}} ->
            throw(Reason);
        {Ref, {error, Reason}} ->
            throw({measurement_error, #{Name => Reason}})
    after Timeout ->
        exit(Pid, kill),
        throw({measurement_error,
               #{Name => <<"measurement step timed out">>}})
    end.

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body({ok, Msg}, Opts) ->
    response_body(Msg, Opts);
response_body({error, Reason}, _Opts) ->
    throw({measurement_error, Reason});
response_body(Msg, Opts) when is_map(Msg) ->
    Normalized = materialize_peer_value(normalize_top_keys(Msg), Opts),
    Status = maps:get(<<"status">>, Normalized, undefined),
    Body = maps:get(<<"body">>, Normalized, undefined),
    Type = maps:get(<<"type">>, Normalized, undefined),
    case {Status, Body, Type} of
        {_, Body, ?TYPE} when Body =/= undefined ->
            Normalized;
        {Status, Body, _} when is_integer(Status), Status >= 400 ->
            throw({measurement_error, Body});
        {Status, Body, _} when is_integer(Status), Body =/= undefined ->
            response_body(Body, Opts);
        {_, Body, _} when Body =/= undefined ->
            response_body(Body, Opts);
        _ ->
            Normalized
    end;
response_body(Body, _Opts) ->
    Body.

materialize_measurement(Msg, Opts) when is_map(Msg) ->
    materialize_peer_measurement(Msg, Opts);
materialize_measurement(Link, Opts) when ?IS_LINK(Link) ->
    materialize_measurement(hb_cache:ensure_loaded(Link, Opts), Opts);
materialize_measurement({ok, Msg}, Opts) ->
    materialize_measurement(Msg, Opts).

nonce_for(boot, _Req, _Opts) ->
    crypto:strong_rand_bytes(32);
nonce_for(fresh, Req, _Opts) ->
    case decoded_nonce(Req) of
        undefined -> crypto:strong_rand_bytes(32);
        Nonce -> Nonce
    end.

decoded_nonce(Req) ->
    case maps:get(<<"nonce">>, Req, undefined) of
        undefined -> undefined;
        B when is_binary(B) ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ -> undefined
    end.

purpose_name(boot) -> <<"boot">>;
purpose_name(fresh) -> <<"fresh">>.

peer_url(Req, Opts) ->
    first_defined([
        hb_maps:get(<<"url">>, Req, undefined, Opts),
        hb_maps:get(<<"peer">>, Req, undefined, Opts)
    ]).

strip_trailing_slash(B) when is_binary(B), byte_size(B) > 0 ->
    case binary:last(B) of
        $/ -> binary:part(B, 0, byte_size(B) - 1);
        _  -> B
    end;
strip_trailing_slash(B) ->
    B.

peer_attestation_validity(Now, Req, Opts) ->
    Base = #{<<"not-before-unix">> => Now},
    case peer_attestation_ttl(Req, Opts) of
        undefined -> Base;
        TTL -> Base#{<<"expires-at-unix">> => Now + TTL}
    end.

peer_attestation_ttl(Req, Opts) ->
    parse_positive_integer(first_defined([
        hb_maps:get(
            <<"peer-attestation-ttl-seconds">>, Req, undefined, Opts),
        hb_opts:get(
            <<"peer-attestation-ttl-seconds">>, undefined, Opts)
    ])).

parse_positive_integer(undefined) ->
    undefined;
parse_positive_integer(N) when is_integer(N), N > 0 ->
    N;
parse_positive_integer(B) when is_binary(B) ->
    try binary_to_integer(B) of
        N when N > 0 -> N;
        _ -> undefined
    catch _:_ -> undefined
    end;
parse_positive_integer(_) ->
    undefined.

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

secret_recipient_id(Subject, Opts) ->
    case secret_recipient_identity(Subject, Opts) of
        Identity when map_size(Identity) > 0 -> stable_id(Identity, Opts);
        _ -> stable_id(Subject, Opts)
    end.

secret_recipient_identity(Subject, Opts) when is_map(Subject) ->
    maps:from_list(
        [
            {Key, canonical_payload(Value, Opts)}
         || Key <- secret_recipient_identity_keys(),
            Value <- [hb_maps:get(Key, Subject, undefined, Opts)],
            Value =/= undefined
        ]);
secret_recipient_identity(_Subject, _Opts) ->
    #{}.

secret_recipient_identity_keys() ->
    [
        <<"type">>,
        <<"version">>,
        <<"measurement-device">>,
        <<"method">>,
        <<"key-id">>,
        <<"public-material">>,
        <<"binding">>
    ].

canonical_payload(Link, Opts) when ?IS_LINK(Link) ->
    canonical_payload(response_body(Link, Opts), Opts);
canonical_payload(Msg, Opts) when is_map(Msg) ->
    Body = maps:from_list(
        [
            {Key, Value}
         || {Key, Value} <- hb_maps:to_list(Msg, Opts),
            not detached_transport_key(Key)
        ]),
    Loaded = hb_cache:ensure_all_loaded(Body, Opts),
    maps:from_list(
        [
            {Key, canonical_payload(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Loaded, Opts),
            not detached_transport_key(Key)
        ]);
canonical_payload(List, Opts) when is_list(List) ->
    [canonical_payload(Value, Opts) || Value <- List];
canonical_payload(Value, _Opts) when is_atom(Value) ->
    hb_util:bin(Value);
canonical_payload(Value, _Opts) ->
    Value.

measurement_id(Measurement, Opts) ->
    case measurement_envelope(Measurement, Opts) of
        Msg when is_map(Msg) ->
            case committed_message_id(Msg, Opts) of
                undefined -> stable_id(Msg, Opts);
                ID -> ID
            end;
        Bin when is_binary(Bin), byte_size(Bin) =:= 32 ->
            hb_util:human_id(Bin);
        Bin when is_binary(Bin), byte_size(Bin) =:= 43 ->
            Bin;
        Bin when is_binary(Bin) ->
            hb_util:encode(hb_crypto:sha256(Bin));
        Other ->
            hb_util:encode(crypto:hash(sha256, term_to_binary(Other)))
    end.

measurement_envelope(Msg, Opts) when is_map(Msg) ->
    case hb_maps:get(<<"type">>, Msg, undefined, Opts) of
        ?TYPE -> Msg;
        _ -> response_body(Msg, Opts)
    end;
measurement_envelope(Other, _Opts) ->
    Other.

committed_message_id(Msg, Opts) ->
    Commitments = hb_maps:get(<<"commitments">>, Msg, #{}, Opts),
    IDs = hb_maps:to_list(Commitments, Opts),
    first_valid_id(
        [ID || {ID, Commitment} <- IDs,
               hb_maps:get(<<"committer">>, Commitment, undefined, Opts)
                   =/= undefined]
        ++ [ID || {ID, _Commitment} <- IDs]).

first_valid_id([]) ->
    undefined;
first_valid_id([ID0 | Rest]) ->
    ID = hb_util:bin(ID0),
    try hb_util:native_id(ID) of
        Native when byte_size(Native) =:= 32 -> ID;
        _ -> first_valid_id(Rest)
    catch _:_ ->
        first_valid_id(Rest)
    end.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

decode_links_deep(Msg) when is_map(Msg) ->
    hb_link:decode_all_links(maps:from_list(
        [
            {normalize_key(Key), decode_links_deep(Value)}
         || {Key, Value} <- maps:to_list(Msg)
        ]));
decode_links_deep(List) when is_list(List) ->
    [decode_links_deep(Value) || Value <- List];
decode_links_deep(Value) ->
    Value.

detached_transport_key(<<"commitments">>) -> true;
detached_transport_key(commitments) -> true;
detached_transport_key(<<"ao-types">>) -> true;
detached_transport_key('ao-types') -> true;
detached_transport_key(ao_types) -> true;
detached_transport_key(_) -> false.

with_ok(Fun, Error) ->
    try
        {ok, #{<<"status">> => 200, <<"body">> => Fun()}}
    catch
        throw:{measurement_error, Reason} -> error_resp(500, Error, Reason);
        Class:Reason:Stack ->
            error_resp(500, Error, #{
                <<"class">> => reason_to_text(Class),
                <<"reason">> => reason_to_text(Reason),
                <<"stack">> => reason_to_text(Stack)
            })
    end.

with_raw_ok(Fun) ->
    try Fun()
    catch
        throw:{measurement_error, Reason} -> {error, Reason};
        Class:Reason:Stack ->
            {error, #{
                <<"class">> => reason_to_text(Class),
                <<"reason">> => reason_to_text(Reason),
                <<"stack">> => reason_to_text(Stack)
            }}
    end.

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
