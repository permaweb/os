%%% @doc Common LapEE hardware-measurement protocol.
%%%
%%% `~measurement@1.0' is the normalized attestation surface consumed by
%%% green-zone and external callers. It owns the public LapEE subject:
%%%
%%%     #{ <<"system">> => ~system@1.0/all,
%%%        <<"node">>   => signed ~meta@1.0/info }
%%%
%%% Measurement-capable devices (`~tpm@2.0a', `~snp@1.0', later `~tdx@1.0')
%%% provide only engine-native evidence and secret-recipient handling. This
%%% keeps policy outside the device: callers receive signed AO-Core messages
%%% containing provenance and facts, then decide what they trust.
%%%
%%% Public measurement messages have this shape:
%%%
%%%     #{ <<"type">>               => <<"lapee-measurement">>,
%%%        <<"version">>            => <<"1.0">>,
%%%        <<"issued-at-unix">>     => UnixSeconds,
%%%        <<"measurement-device">> => Device,
%%%        <<"body">>               => Subject,
%%%        <<"evidence">>           => DeviceEvidence,
%%%        <<"secret-recipient">>   => DeviceRecipient }
%%%
%%% The included `body' is an AO-Core message in its own right; no duplicate
%%% `body-id' is exposed because consumers can compute the ID locally.
-module(dev_measurement).
-export([info/1, info/3, boot/3, fresh/3, verify/3, verify_peer/3,
         subject/3, wrap_secret/3, unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         measurement_body/1, measurement_body_id/2]).

-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).
-define(TYPE, <<"lapee-measurement">>).
-define(BOOT_PATH, <<"~measurement@1.0/boot">>).
-define(PEER_ATTESTATION_PREFIX,
        <<"~measurement@1.0/peer-attestations">>).
-define(DEFAULT_DEVICES, [<<"snp@1.0">>, <<"tpm@2.0a">>]).
-define(DEFAULT_TIMEOUT_MS, 30000).

info(_) ->
    #{
        exports => [
            <<"info">>,
            <<"boot">>,
            <<"fresh">>,
            <<"verify">>,
            <<"verify-peer">>,
            <<"subject">>,
            <<"wrap-secret">>,
            <<"unwrap-secret">>
        ]
    }.

info(_Base, _Req, Opts) ->
    {Selected, Reason} = selected_device_or_reason(Opts),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"description">> =>
                <<"Common LapEE measurement protocol over TPM, SNP, and "
                  "future hardware-measurement devices.">>,
            <<"version">> => ?VERSION,
            <<"selected-measurement-device">> => Selected,
            <<"selection-reason">> => Reason,
            <<"available-candidates">> => candidate_devices(Opts)
        }
    }}.

boot(_Base, _Req, Opts) ->
    case hb_cache:read(?BOOT_PATH, Opts) of
        {ok, Msg} ->
            {ok, #{<<"status">> => 200,
                   <<"body">> => materialized_response_body(Msg, Opts)}};
        _ ->
            global:trans(
                {dev_measurement, boot},
                fun() -> boot_locked(Opts) end,
                [node()])
    end.

boot_locked(Opts) ->
    case hb_cache:read(?BOOT_PATH, Opts) of
        {ok, Msg} ->
            {ok, #{<<"status">> => 200,
                   <<"body">> => materialized_response_body(Msg, Opts)}};
        _ ->
            case generate_measurement(boot, #{}, Opts) of
                {ok, Signed} ->
                    SignedID = hb_message:id(Signed, signed, Opts),
                    {ok, _UnsignedID} = hb_cache:write(Signed, Opts),
                    ok = hb_cache:link(SignedID, ?BOOT_PATH, Opts),
                    {ok, #{<<"status">> => 200,
                           <<"body">> =>
                               materialized_response_body(Signed, Opts)}};
                {error, Reason} ->
                    error_resp(500, <<"measurement-boot-failed">>, Reason)
            end
    end.

fresh(_Base, Req, Opts) ->
    case generate_measurement(fresh, Req, Opts) of
        {ok, Signed} ->
            {ok, #{<<"status">> => 200,
                   <<"body">> => materialized_response_body(Signed, Opts)}};
        {error, Reason} ->
            error_resp(500, <<"measurement-fresh-failed">>, Reason)
    end.

subject(_Base, Req, Opts) ->
    with_ok(
        fun() ->
            Device = selected_device(Opts),
            Body = measurement_body(Opts),
            materialized_response_body(
                resolve_device_body(
                    Device,
                    <<"subject">>,
                    Req#{<<"body">> => Body},
                    Opts),
                Opts)
        end,
        <<"measurement-subject-failed">>).

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
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

wrap_secret(_Base, Req, Opts) ->
    with_ok(
        fun() ->
            Subject = hb_maps:get(<<"subject">>, Req, undefined, Opts),
            Secret = decode_secret(hb_maps:get(<<"secret">>, Req, <<>>, Opts)),
            wrap_secret_for_subject(Subject, Secret, Opts)
        end,
        <<"wrap-secret-failed">>).

unwrap_secret(_Base, Req, Opts) ->
    with_ok(
        fun() ->
            Credential = first_defined([
                hb_maps:get(<<"credential">>, Req, undefined, Opts),
                hb_maps:get(<<"wrapped-secret">>, Req, undefined, Opts),
                Req
            ]),
            Device = measurement_device(Credential, Opts),
            resolve_device_body(Device, <<"unwrap-secret">>, Credential, Opts)
        end,
        <<"unwrap-secret-failed">>).

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
            Node = ensure_committed(Node0, Opts),
            Body = #{<<"system">> => System, <<"node">> => Node},
            persistent_term:put({dev_measurement, body}, Body),
            persistent_term:put(
                {dev_measurement, body_id},
                hb_message:id(Body, all, Opts)),
            Body
    end.

measurement_body_id(Body, Opts) when is_map(Body) ->
    stable_id(Body, Opts).

verify_peer_url(Url, Req, Opts) ->
    with_raw_ok(fun() ->
        Boot = detached_peer_payload(response_body(
            lapee_peer_http:get(Url, <<"/~measurement@1.0/boot">>, Opts),
            Opts), Opts),
        Subject = detached_peer_payload(response_body(
            lapee_peer_http:get(Url, <<"/~measurement@1.0/subject">>, Opts),
            Opts), Opts),
        FreshNonce = crypto:strong_rand_bytes(32),
        Fresh = detached_peer_payload(response_body(
            lapee_peer_http:get(
                Url,
                <<"/~measurement@1.0/fresh?nonce=",
                  (hb_util:encode(FreshNonce))/binary>>,
                Opts),
            Opts), Opts),
        ok = ensure_measurement_shape(Boot),
        ok = ensure_measurement_shape(Fresh),
        ok = ensure_same_subject(Boot, Fresh, Opts),
        ok = ensure_subject_matches_measurement(Subject, Boot, Opts),
        ok = ensure_subject_matches_measurement(Subject, Fresh, Opts),
        BootVerify = verify_measurement_body(Boot, Req, Opts),
        FreshVerify = verify_measurement_body(
            Fresh,
            Req#{<<"nonce">> => hb_util:encode(FreshNonce)},
            Opts),
        Challenge = crypto:strong_rand_bytes(32),
        Credential = wrap_secret_for_subject(Subject, Challenge, Opts),
        Activation = activate_peer_secret(Url, Credential, Opts),
        ok = ensure_secret_activation(
            Activation, Credential, Challenge, Subject, Opts),
        Now = erlang:system_time(second),
        Signed = hb_message:commit(
            #{
                <<"type">> => <<"green-zone-peer-attestation">>,
                <<"version">> => <<"1.0">>,
                <<"issued-at-unix">> => Now,
                <<"measurement-device">> => measurement_device(Boot, Opts),
                <<"secret-method">> =>
                    hb_maps:get(<<"method">>, Subject, null, Opts),
                <<"validity">> =>
                    peer_attestation_validity(Now, Req, Opts),
                <<"peer-url">> => Url,
                <<"peer-scope">> =>
                    peer_attestation_scope(
                        Url, Boot, Fresh, Subject, Req, Opts),
                <<"peer-boot-attestation">> => Boot,
                <<"peer-fresh-attestation">> => Fresh,
                <<"peer-credential-subject">> => Subject,
                <<"peer-secret-subject">> => Subject,
                <<"boot-verification">> => BootVerify,
                <<"verification">> => FreshVerify,
                <<"freshness">> => #{
                    <<"verified">> => true,
                    <<"nonce-sha256">> =>
                        hb_util:encode(crypto:hash(sha256, FreshNonce)),
                    <<"fresh-attestation-id">> =>
                        measurement_id(Fresh, Opts)
                },
                <<"credential-activation">> => #{
                    <<"verified">> => true,
                    <<"challenge-sha256">> =>
                        hb_util:encode(crypto:hash(sha256, Challenge)),
                    <<"credential">> => Credential,
                    <<"response">> => Activation
                }
            },
            Opts),
        ok = store_peer_attestation(Signed, Opts),
        {ok, Signed}
    end).

verify_measurement_body(Measurement, Req, Opts) ->
    {ok, #{<<"status">> := 200, <<"body">> := Body}} =
        verify(Measurement, Req#{<<"envelope">> => Measurement}, Opts),
    case hb_maps:get(<<"verified">>, Body, false, Opts) of
        true -> Body;
        false ->
            throw({measurement_error,
                   #{<<"verification">> => Body}})
    end.

wrap_secret_for_subject(Subject, Secret, Opts) when is_map(Subject) ->
    Device = measurement_device(Subject, Opts),
    case Device of
        <<"tpm@2.0a">> ->
            (dev_tpm2:make_credential_for_subject(Subject, Secret))#{
                <<"type">> => <<"lapee-wrapped-secret">>,
                <<"measurement-device">> => Device,
                <<"method">> => <<"tpm2-activate-credential">>,
                <<"subject-id">> => stable_id(Subject, Opts)
            };
        <<"snp@1.0">> ->
            dev_snp:wrap_secret_for_subject(Subject, Secret, Opts);
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
    case measurement_device(Credential, Opts) of
        <<"tpm@2.0a">> -> dev_tpm2:activate_credential_secret(Credential, Opts);
        <<"snp@1.0">> -> dev_snp:unwrap_secret_value(Credential, Opts);
        <<"snp-mock@1.0">> -> dev_snp_mock:unwrap_secret_value(Credential, Opts);
        Device ->
            throw({measurement_error,
                   #{<<"unwrap-secret">> =>
                        <<"No local raw-secret helper for ", Device/binary>>}})
    end.

activate_peer_secret(Url, Credential, Opts) ->
    detached_peer_payload(response_body(
        lapee_peer_http:post(
            Url,
            <<"/~measurement@1.0/unwrap-secret">>,
            Credential,
            Opts),
        Opts), Opts).

ensure_secret_activation(Activation, Credential, Expected, Subject, Opts) ->
    Device = measurement_device(Credential, Opts),
    case Device of
        <<"tpm@2.0a">> ->
            dev_tpm2:ensure_activation_secret(
                Activation, Credential, Expected, Subject, Opts);
        <<"snp@1.0">> ->
            dev_snp:ensure_secret_activation(
                Activation, Credential, Expected, Subject, Opts);
        <<"snp-mock@1.0">> ->
            dev_snp_mock:ensure_secret_activation(
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
    case {measurement_device(Subject, Opts), measurement_device(Measurement, Opts),
          stable_id(Subject, Opts), stable_id(Recipient, Opts)} of
        {Device, Device, ID, ID} -> ok;
        _ ->
            throw({measurement_error,
                   #{<<"secret-recipient">> =>
                        <<"subject does not match measurement recipient">>}})
    end.

peer_attestation_scope(Url, Boot, Fresh, Subject, Req, Opts) ->
    #{
        <<"peer-url">> => Url,
        <<"measurement-device">> => measurement_device(Boot, Opts),
        <<"boot-attestation-id">> => measurement_id(Boot, Opts),
        <<"fresh-attestation-id">> => measurement_id(Fresh, Opts),
        <<"secret-recipient-id">> => stable_id(Subject, Opts),
        <<"consumer-scope">> =>
            hb_maps:get(<<"peer-attestation-scope">>, Req, null, Opts)
    }.

store_peer_attestation(Signed, Opts) ->
    ID = hb_message:id(Signed, signed, Opts),
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
    case first_defined([
        hb_opts:get(<<"measurement-device">>, undefined, Opts),
        hb_opts:get(<<"measurement_device">>, undefined, Opts),
        hb_opts:get(measurement_device, undefined, Opts)
    ]) of
        undefined -> auto;
        <<"auto">> -> auto;
        auto -> auto;
        Device when is_binary(Device) -> Device;
        Device when is_atom(Device) -> atom_to_binary(Device, utf8);
        Other -> hb_util:bin(Other)
    end.

auto_device(Opts) ->
    case [D || D <- ?DEFAULT_DEVICES, device_supported(D, Opts)] of
        [D | _] -> {D, <<"auto">>};
        [] -> {<<"unavailable">>, <<"no measurement device supported">>}
    end.

candidate_devices(Opts) ->
    [#{<<"device">> => D, <<"supported">> => device_supported(D, Opts)}
     || D <- ?DEFAULT_DEVICES].

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
    case {known_device_module(Device), measurement_export(Path)} of
        {Module, Fun} when Module =/= undefined, Fun =/= undefined ->
            apply(Module, Fun, [#{}, Req, Opts]);
        _ ->
            hb_ao:resolve(
                #{<<"device">> => Device},
                Req#{<<"path">> => Path},
                Opts)
    end.

known_device_module(<<"tpm@2.0a">>) -> dev_tpm2;
known_device_module(<<"snp@1.0">>) -> dev_snp;
known_device_module(<<"snp-mock@1.0">>) -> dev_snp_mock;
known_device_module(_Device) -> undefined.

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
            case hb_maps:get(<<"body">>, Base, undefined, Opts) of
                Inner when is_map(Inner) -> Inner;
                _ -> Base
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
response_body(#{<<"status">> := _Status, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
response_body(#{<<"body">> := Body} = Msg, Opts) ->
    case hb_maps:get(<<"type">>, Msg, undefined, Opts) of
        ?TYPE -> Msg;
        _ -> response_body(Body, Opts)
    end;
response_body(Body, _Opts) ->
    Body.

materialized_response_body(Msg, Opts) ->
    hb_cache:ensure_all_loaded(response_body(Msg, Opts), Opts).

ensure_committed(Msg, Opts) when is_map(Msg) ->
    case hb_message:signers(Msg, Opts) of
        [] -> hb_message:commit(Msg, Opts);
        _ -> Msg
    end;
ensure_committed(Msg, _Opts) ->
    Msg.

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
stable_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

canonical_payload(Link, Opts) when ?IS_LINK(Link) ->
    canonical_payload(response_body(Link, Opts), Opts);
canonical_payload(Msg, Opts) when is_map(Msg) ->
    Body = maps:from_list(
        [
            {Key, Value}
         || {Key, Value} <- hb_maps:to_list(Msg, Opts),
            Key =/= <<"commitments">>,
            Key =/= <<"ao-types">>
        ]),
    Loaded = hb_cache:ensure_all_loaded(Body, Opts),
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

measurement_id(Measurement, Opts) ->
    stable_id(response_body(Measurement, Opts), Opts).

decode_secret(B) when is_binary(B) ->
    try hb_util:decode(B)
    catch _:_ -> B
    end;
decode_secret(Other) ->
    throw({measurement_error,
           #{<<"secret">> => <<"secret must be binary/base64url">>,
             <<"value">> => hb_util:bin(Other)}}).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

detached_peer_payload(Link, Opts) when ?IS_LINK(Link) ->
    detached_peer_payload(response_body(Link, Opts), Opts);
detached_peer_payload(Msg, Opts) when is_map(Msg) ->
    maps:from_list(
        [
            {Key, detached_peer_payload(Value, Opts)}
         || {Key, Value} <- maps:to_list(Msg),
            not detached_transport_key(Key)
        ]);
detached_peer_payload(List, Opts) when is_list(List) ->
    [detached_peer_payload(Value, Opts) || Value <- List];
detached_peer_payload(Value, _Opts) ->
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
        Class:Reason ->
            error_resp(500, Error, #{
                <<"class">> => reason_to_text(Class),
                <<"reason">> => reason_to_text(Reason)
            })
    end.

with_raw_ok(Fun) ->
    try Fun()
    catch
        throw:{measurement_error, Reason} -> {error, Reason};
        Class:Reason ->
            {error, #{
                <<"class">> => reason_to_text(Class),
                <<"reason">> => reason_to_text(Reason)
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

measurement_body_is_cached_test() ->
    Body = #{<<"system">> => #{}, <<"node">> => #{}},
    ?assertEqual(
        stable_id(Body, #{}),
        measurement_body_id(Body, #{})).

measurement_body_id_ignores_transport_commitments_test() ->
    Body = #{<<"system">> => #{<<"kernel">> => <<"same">>}},
    WithCommitment = Body#{
        <<"commitments">> => #{
            <<"foreign-id">> => #{
                <<"type">> => <<"hmac-sha256">>,
                <<"signature">> => <<"foreign-id">>
            }
        }
    },
    ?assertEqual(
        measurement_body_id(Body, #{}),
        measurement_body_id(WithCommitment, #{})).
