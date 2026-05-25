%%% @doc TPM 2.0 measurement engine for LapEE.
%%% The engine extends PCR 15 with the measured boot subject, creates a
%%% PCR-bound AK, verifies TPM evidence, and maps TPM
%%% MakeCredential/ActivateCredential into `~measurement@1.0'.
-module(dev_tpm2).
-implements(<<"tpm@2.0a">>).
-device_libraries([lib_hb_db_tpm, lib_lapee_aia, lib_lapee_tpm_tcg]).
-export([info/1, info/3, supported/3, subject/3, measure/3,
         unwrap_secret/3, activate_credential_secret/2]).
-export([verify/3]).
-export([make_credential_for_subject/2]).
-export([ensure_activation_secret/5]).
-include_lib("hb/include/hb.hrl").
-include_lib("public_key/include/public_key.hrl").

%% Default PCR that HyperBEAM extends with the node-message identity.
-define(NODE_IDENTITY_PCR, 15).
%% PCRs that gate the AK. PCR 15 carries the LapEE boot subject, so the
-define(AK_POLICY_PCRS, [0, 1, 7, 10, 11, 14, 15]).
%% Default PCR selection the quote covers.
-define(DEFAULT_QUOTE_PCRS, [0, 1, 7, 10, 11, 14, 15]).
-define(TPM_CC_ACTIVATE_CREDENTIAL, 16#00000147).
-define(TPM_CC_POLICY_COMMAND_CODE, 16#0000016C).
-define(TPM_CC_POLICY_OR, 16#00000171).
-define(TPM_CC_POLICY_PCR, 16#0000017F).
-define(TCG_EK_CERT_OID, {2, 23, 133, 8, 1}).


info(_) ->
    #{
        exports =>
            [
                <<"info">>,
                <<"supported">>,
                <<"subject">>,
                <<"measure">>,
                <<"unwrap-secret">>,
                <<"verify">>
            ]
    }.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"version">> => <<"2.0a">>,
            <<"exports">> => maps:get(exports, info(#{}), [])
        }
    }}.


extend_with_tcg_event_log_tip() ->
    case read_tcg_event_log() of
        Bin when is_binary(Bin), byte_size(Bin) > 0 ->
            Digest = crypto:hash(sha256, Bin),
            case nif_pcr_extend(?NODE_IDENTITY_PCR, Digest) of
                ok ->
                    _ = append_event(?NODE_IDENTITY_PCR,
                        #{
                            <<"event-type">> =>
                                <<"EV_HYPERBEAM_TCG_LOG_TIP_COMMITMENT">>,
                            <<"digest">> => hb_util:encode(Digest),
                            <<"subject">> =>
                                hb_util:encode(
                                    <<"sha256(tcg-event-log)">>),
                            <<"subject-is-message">> => false,
                            <<"tcg-event-log-length-bytes">> =>
                                byte_size(Bin)
                        }),
                    ok;
                {error, _} = E -> E
            end;
        _ ->
            ok
    end.


verify(Base, Req, Opts) ->
    Envelope = normalise_attestation(measurement_envelope(Base, Req, Opts), Opts),
    {TrustedCaPem, CaSource} = resolve_trusted_ca_with_source(Req, Opts),
    Checks = [
        safely_run(fun() -> chk_ek_chain(Envelope, TrustedCaPem, Opts) end,
                   <<"EK certificate chains to trusted TPM vendor root CA">>,
                   <<"core">>),
        safely_run(fun() -> chk_tpm_public_identity(Envelope, Opts) end,
                   <<"EK certificate matches EK public material; AK and "
                     "recipient material are self-consistent">>,
                   <<"core">>),
        safely_run(fun() -> chk_quote(Envelope, expected_nonce(Req)) end,
                   <<"TPM2_Quote signature + pcrDigest + nonce all valid">>,
                   <<"core">>),
        safely_run(fun() -> chk_ak_policy_bound(Envelope) end,
                   <<"AK authPolicy is PCR-bound to the quoted boot state">>,
                   <<"core">>),
        safely_run(fun() -> chk_event_log_replay(Envelope) end,
                   <<"Runtime event log replay of PCR 15 matches quoted value">>,
                   <<"core">>),
        safely_run(fun() -> chk_binding(Envelope) end,
                   <<"PCR 15 extension commits to node_message_id">>,
                   <<"core">>),
        safely_run(fun() -> chk_measurement_body_binding(Envelope, Opts) end,
                   <<"PCR 15 extension commits to measurement body">>,
                   <<"core">>),
        safely_run(fun() -> chk_node_msg_shape(Envelope) end,
                   <<"Embedded node_message + id present and correct shape">>,
                   <<"core">>)
    ],
    AllOk = lists:all(
        fun(#{<<"ok">> := Ok, <<"severity">> := Sev}) ->
                Ok orelse Sev =:= <<"informational">>
        end, Checks),
    Verdict = case AllOk of
        true  -> <<"accepted">>;
        false -> <<"rejected">>
    end,
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"verified">> => AllOk,
            <<"verdict">> => Verdict,
            <<"checks">> => Checks,
            <<"trust-anchor-source">> => CaSource
        }
    }}.

measurement_envelope(Base, Req, Opts) when is_map(Base) ->
    case hb_maps:get(<<"envelope">>, Req, undefined, Opts) of
        E when is_map(E) -> E;
        _ -> Base
    end;
measurement_envelope(_Base, Req, Opts) ->
    hb_maps:get(<<"envelope">>, Req, #{}, Opts).

normalise_attestation(Envelope, Opts) when is_map(Envelope) ->
    case {
        hb_maps:get(<<"type">>, Envelope, undefined, Opts),
        hb_maps:get(<<"measurement-device">>, Envelope, undefined, Opts),
        hb_maps:get(<<"body">>, Envelope, undefined, Opts),
        hb_maps:get(<<"evidence">>, Envelope, undefined, Opts)
    } of
        {<<"lapee-measurement">>, <<"tpm@2.0a">>, Body, Evidence}
                when is_map(Body), is_map(Evidence) ->
            Node = hb_maps:get(<<"node">>, Envelope, undefined, #{}),
            Node1 = hb_maps:get(<<"node">>, Body, Node, #{}),
            ExtendedSubject =
                hb_maps:get(<<"extended-subject">>, Evidence, undefined, #{}),
            NodeID =
                case ExtendedSubject of
                    B when is_binary(B), byte_size(B) > 0 -> B;
                    _ ->
                        case Node1 of
                            M1 when is_map(M1) ->
                                hb_util:human_id(
                                    hb_util:native_id(
                                        hb_message:id(M1, all, Opts)));
                            _ -> undefined
                        end
                end,
            Quote = hb_maps:get(<<"quote">>, Evidence, #{}, #{}),
            Recipient =
                hb_maps:get(<<"secret-recipient">>, Envelope, undefined, #{}),
            Evidence#{
                <<"lapee-attestation-version">> =>
                    hb_maps:get(<<"lapee-attestation-version">>,
                                Envelope, <<"1.0">>, #{}),
                <<"tpm-quote">> => Quote,
                <<"node-message">> => Node1,
                <<"node-message-id">> => NodeID,
                <<"measurement-body">> => Body,
                <<"wallet-address">> =>
                    case Node1 of
                        M2 when is_map(M2) ->
                            hb_maps:get(<<"address">>, M2, null, #{});
                        _ -> null
                    end,
                <<"secret-recipient">> => Recipient
            };
        _ -> Envelope
    end;
normalise_attestation(Other, _Opts) ->
    Other.

safely_run(F, Name, Severity) ->
    try F() of
        {ok, Detail}    -> #{ <<"name">> => Name,
                              <<"ok">> => true,
                              <<"detail">> => Detail,
                              <<"severity">> => Severity };
        {error, Detail} -> #{ <<"name">> => Name,
                              <<"ok">> => false,
                              <<"detail">> => Detail,
                              <<"severity">> => Severity }
    catch
        _:_ ->
            #{ <<"name">> => Name,
               <<"ok">> => false,
               <<"detail">> => <<"exception">>,
               <<"severity">> => Severity }
    end.

resolve_trusted_ca_with_source(Req, Opts) ->
    case {allow_request_trusted_ca(Opts),
          hb_maps:get(<<"trusted-ca">>, Req, undefined, Opts)} of
        {false, B} when is_binary(B), byte_size(B) > 0 ->
            resolve_trusted_ca_from_config(Opts);
        {true, B} when is_binary(B), byte_size(B) > 0 ->
            try hb_util:decode(B) of
                Decoded when is_binary(Decoded), byte_size(Decoded) > 0 ->
                    {Decoded, <<"request">>};
                _ -> {<<>>, <<"request-bad">>}
            catch _:_ -> {<<>>, <<"request-bad">>}
            end;
        _ -> resolve_trusted_ca_from_config(Opts)
    end.

allow_request_trusted_ca(Opts) ->
    hb_opts:get(<<"lapee-allow-request-trusted-ca">>, false, Opts) =:= true.

resolve_trusted_ca_from_config(Opts) ->
    case hb_opts:get(<<"lapee-tpm-ca-pem">>, undefined, Opts) of
        Pem when is_binary(Pem), byte_size(Pem) > 0 ->
            {Pem, <<"node-config-pem">>};
        Pem when is_list(Pem), length(Pem) > 0 ->
            {iolist_to_binary(Pem), <<"node-config-pem">>};
        _ ->
            case configured_trusted_ca_path(Opts) of
                undefined ->
                    resolve_trusted_ca_from_internal_bundle(Opts);
                Path ->
                    case file:read_file(path_to_list(Path)) of
                        {ok, Pem}  -> {Pem, <<"node-config">>};
                        {error, _} -> {<<>>, <<"node-config-missing">>}
                    end
            end
    end.

configured_trusted_ca_path(Opts) ->
    hb_opts:get(<<"lapee-tpm-ca-cert">>, undefined, Opts).

resolve_trusted_ca_from_internal_bundle(Opts) ->
    Roots = hb_maps:get(<<"cert-roots">>, lib_hb_db_tpm:load(?MODULE, Opts), [], #{}),
    Pem = iolist_to_binary(
        [pem_with_trailing_newline(RootPem)
         || Root <- Roots,
            RootPem <- [hb_maps:get(<<"pem">>, Root, <<>>, #{})],
            is_binary(RootPem),
            byte_size(RootPem) > 0]),
    case Pem of
        <<>> -> {<<>>, <<"none">>};
        _ -> {Pem, <<"internal-bundle">>}
    end.

path_to_list(Path) when is_binary(Path) -> binary_to_list(Path);
path_to_list(Path) when is_list(Path) -> Path.

pem_with_trailing_newline(Pem) ->
    case binary:last(Pem) of
        $\n -> Pem;
        _ -> <<Pem/binary, "\n">>
    end.

chk_ek_chain(Envelope, TrustedCaPem, Opts) ->
    EkPem = hb_maps:get(<<"ek-cert-pem">>, Envelope, <<>>, Opts),
    ChainPem = hb_maps:get(<<"ek-cert-chain-pem">>, Envelope, <<>>, Opts),
    case {decode_pem_cert(EkPem), decode_pem_certs(TrustedCaPem)} of
        {{ok, EkDer}, {ok, TrustedDers}} ->
            PeerChainDers =
                case decode_pem_certs(ChainPem) of
                    {ok, D} -> D;
                    {error, empty} -> [];
                    {error, _} -> []
                end,
            validate_ek_chain(EkDer, PeerChainDers, TrustedDers, Opts);
        {_, {error, _}} ->
            {error, <<"trusted CA missing or unparseable; ship "
                      "`priv/tpm-interpret/root-cas/' in the measured image, "
                      "set `lapee-tpm-ca-cert' in node config, or pass "
                      "`trusted-ca' with "
                      "`lapee-allow-request-trusted-ca' enabled">>};
        {{error, Why}, _} ->
            {error, iolist_to_binary(io_lib:format("ek_cert_pem invalid: ~p",
                                                    [Why]))}
    end.

validate_ek_chain(_EkDer, _PeerChainDers, [], _Opts) ->
    {error, <<"trusted CA missing or unparseable">>};
validate_ek_chain(EkDer, PeerChainDers, TrustedDers, Opts) ->
    case attempt_chain(EkDer, PeerChainDers, TrustedDers) of
        {ok, _} = Ok -> Ok;
        {error, Reasons} ->
            case lib_lapee_aia:enabled(Opts) of
                false ->
                    {error, render_chain_failure(Reasons, TrustedDers,
                                                 <<"AIA disabled">>)};
                true ->
                    case extend_chain_via_aia(EkDer, PeerChainDers,
                                              TrustedDers, Opts) of
                        {extended, ExtendedChainDers, FetchSummary} ->
                            case attempt_chain(EkDer, ExtendedChainDers,
                                               TrustedDers) of
                                {ok, Detail} ->
                                    {ok, iolist_to_binary([
                                        Detail, <<" [via AIA: ">>,
                                        FetchSummary, <<"]">>])};
                                {error, Reasons2} ->
                                    {error,
                                        render_chain_failure(
                                            Reasons2, TrustedDers,
                                            iolist_to_binary([
                                                <<"AIA fetched ">>,
                                                FetchSummary,
                                                <<", chain still invalid">>
                                            ]))}
                            end;
                        {no_extension, Why} ->
                            {error, render_chain_failure(
                                Reasons, TrustedDers, Why)}
                    end
            end
    end.

attempt_chain(EkDer, PeerChainDers, TrustedDers) ->
    Attempts =
        [
            validate_ek_chain_attempt(EkDer, PeerChainDers, TrustedDers, Anchor)
        ||
            Anchor <- TrustedDers
        ],
    case [Detail || {ok, Detail} <- Attempts] of
        [Detail | _] -> {ok, Detail};
        [] -> {error, [Reason || {error, Reason} <- Attempts]}
    end.

render_chain_failure(Reasons, TrustedDers, AiaNote) ->
    iolist_to_binary(io_lib:format(
        "chain invalid for all ~B trusted anchor candidate(s) (~s): ~p",
        [length(TrustedDers), AiaNote, Reasons])).

-define(AIA_MAX_DEPTH, 5).

extend_chain_via_aia(EkDer, PeerChainDers, TrustedDers, Opts) ->
    aia_walk([EkDer | PeerChainDers], PeerChainDers, TrustedDers,
             Opts, ?AIA_MAX_DEPTH, []).

aia_walk(_Trail, AccChain, _Trusted, _Opts, 0, Fetches) ->
    summarise_aia_walk(AccChain, Fetches, <<"max-depth reached">>);
aia_walk(Trail, AccChain, Trusted, Opts, Budget, Fetches) ->
    Tip = hd(lists:reverse(Trail)),
    case aia_fetch_for(Tip, AccChain, Trusted, Opts) of
        skip ->
            summarise_aia_walk(AccChain, Fetches, <<"chain already reaches a root">>);
        {fetched, NewIssuerDer, Url} ->
            aia_walk(
                Trail ++ [NewIssuerDer],
                AccChain ++ [NewIssuerDer],
                Trusted, Opts,
                Budget - 1,
                [Url | Fetches]
            );
        {error, Why} ->
            summarise_aia_walk(AccChain, Fetches,
                iolist_to_binary(io_lib:format("AIA hop failed: ~p", [Why])))
    end.

summarise_aia_walk(_AccChain, [], Why) ->
    {no_extension, Why};
summarise_aia_walk(AccChain, Fetches, _Why) ->
    Summary = iolist_to_binary(io_lib:format(
        "fetched ~B intermediate(s)", [length(Fetches)])),
    {extended, AccChain, Summary}.

aia_fetch_for(Der, AccChain, Trusted, Opts) ->
    try public_key:pkix_decode_cert(Der, otp) of
        Otp ->
            Tbs = Otp#'OTPCertificate'.tbsCertificate,
            IssuerDn = public_key:pkix_normalize_name(
                Tbs#'OTPTBSCertificate'.issuer),
            case issuer_known(IssuerDn, AccChain ++ Trusted) of
                true -> skip;
                false ->
                    case lib_lapee_aia:caissuers_urls(Otp) of
                        [] -> {error, no_aia_url};
                        Urls ->
                            try_aia_urls(Urls, IssuerDn, Opts)
                    end
            end
    catch _:Reason -> {error, {decode_failed, Reason}}
    end.

try_aia_urls([], _IssuerDn, _Opts) -> {error, all_aia_urls_failed};
try_aia_urls([Url | Rest], IssuerDn, Opts) ->
    case lib_lapee_aia:fetch_issuer(Url, Opts) of
        {ok, IssuerDer} ->
            try
                Otp = public_key:pkix_decode_cert(IssuerDer, otp),
                Tbs = Otp#'OTPCertificate'.tbsCertificate,
                Subject = public_key:pkix_normalize_name(
                    Tbs#'OTPTBSCertificate'.subject),
                case Subject =:= IssuerDn of
                    true -> {fetched, IssuerDer, Url};
                    false -> try_aia_urls(Rest, IssuerDn, Opts)
                end
            catch _:_ -> try_aia_urls(Rest, IssuerDn, Opts)
            end;
        _ -> try_aia_urls(Rest, IssuerDn, Opts)
    end.

issuer_known(IssuerDn, Ders) ->
    lists:any(
        fun(Der) ->
            try
                Otp = public_key:pkix_decode_cert(Der, otp),
                Tbs = Otp#'OTPCertificate'.tbsCertificate,
                Subject = public_key:pkix_normalize_name(
                    Tbs#'OTPTBSCertificate'.subject),
                Subject =:= IssuerDn
            catch _:_ -> false
            end
        end,
        Ders).

validate_ek_chain_attempt(EkDer, PeerChainDers, TrustedDers, AnchorDer) ->
    try public_key:pkix_decode_cert(AnchorDer, otp) of
        AnchorOtp ->
            validate_ek_chain_paths(
                AnchorOtp,
                EkDer,
                candidate_intermediate_chains(
                    PeerChainDers, TrustedDers, AnchorDer))
    catch
        Class:Reason ->
            {error,
                iolist_to_binary(io_lib:format(
                    "trusted CA bundle contains a structurally PEM-shaped "
                    "entry that is not a valid DER certificate (~p:~p); "
                    "refresh the measured-in root-cas bundle or configured "
                    "`lapee-tpm-ca-cert'.",
                    [Class, Reason]))}
    end.

candidate_intermediate_chains(PeerChainDers, TrustedDers, AnchorDer) ->
    ExtraTrusted = [Der || Der <- TrustedDers, Der =/= AnchorDer],
    unique_chains([
        PeerChainDers,
        PeerChainDers ++ ExtraTrusted
    ]).

unique_chains(Chains) ->
    lists:foldl(
        fun(Chain, Acc) ->
            case lists:member(Chain, Acc) of
                true -> Acc;
                false -> Acc ++ [Chain]
            end
        end,
        [],
        Chains).

validate_ek_chain_paths(AnchorOtp, EkDer, IntermediateChains) ->
    Attempts =
        [
            {Intermediates, Path,
             public_key:pkix_path_validation(
                AnchorOtp,
                Path,
                [{verify_fun, ek_chain_verify_fun()}])}
        ||
            Intermediates <- IntermediateChains,
            Path <- ek_cert_path_orders(EkDer, Intermediates)
        ],
    case [{Intermediates, Result} || {Intermediates, _Path, {ok, _} = Result}
                                <- Attempts] of
        [{Intermediates, {ok, _}} | _] ->
            {ok, iolist_to_binary(io_lib:format(
                "pkix_path_validation ok using ~B intermediate "
                "candidate(s)", [length(Intermediates)]))};
        [] ->
            Reasons = [reason_to_text(Why)
                       || {_Intermediates, _Path, {error, Why}} <- Attempts],
            {error, iolist_to_binary(io_lib:format(
                "chain invalid across ~B path candidate(s): ~p",
                [length(Attempts), Reasons]))}
    end.

ek_cert_path_orders(EkDer, Intermediates) ->
    unique_chains([
        lists:reverse(Intermediates) ++ [EkDer],
        Intermediates ++ [EkDer],
        [EkDer | Intermediates]
    ]).

ek_chain_verify_fun() ->
    {fun ek_chain_verify_fun/3, []}.

ek_chain_verify_fun(_, {bad_cert, {not_supported_extension, Ext}},
                    UserState) ->
    ExtId = case Ext of
        #'Extension'{extnID = Id} -> Id;
        _ -> undefined
    end,
    case is_tcg_oid(ExtId) of
        true -> {valid, UserState};
        false -> {fail, {not_supported_extension, Ext}}
    end;
ek_chain_verify_fun(Cert, {bad_cert, invalid_key_usage}, UserState) ->
    case tpm_ek_leaf_cert(Cert) of
        true -> {valid, UserState};
        false -> {fail, invalid_key_usage}
    end;
ek_chain_verify_fun(_, {bad_cert, Reason}, _UserState) ->
    {fail, Reason};
ek_chain_verify_fun(_, {extension, #'Extension'{extnID = ExtId}},
                    UserState) ->
    case is_tcg_oid(ExtId) of
        true -> {valid, UserState};
        false -> {unknown, UserState}
    end;
ek_chain_verify_fun(_, valid, UserState)      -> {valid, UserState};
ek_chain_verify_fun(_, valid_peer, UserState) -> {valid, UserState}.

tpm_ek_leaf_cert(Cert) ->
    try
        Otp = case Cert of
            #'OTPCertificate'{} -> Cert;
            Der when is_binary(Der) -> public_key:pkix_decode_cert(Der, otp)
        end,
        Tbs = Otp#'OTPCertificate'.tbsCertificate,
        Extensions = cert_extensions(Tbs),
        extension_value(?'id-ce-basicConstraints', Extensions)
            =:= #'BasicConstraints'{cA = false, pathLenConstraint = asn1_NOVALUE}
            andalso lists:member(
                ?TCG_EK_CERT_OID,
                extension_value(?'id-ce-extKeyUsage', Extensions))
    catch _:_ ->
        false
    end.

is_tcg_oid(Oid) when is_tuple(Oid) ->
    lists:prefix([2, 23, 133], tuple_to_list(Oid));
is_tcg_oid(_) ->
    false.

chk_tpm_public_identity(Envelope, Opts) ->
    try
        EkCertDer = required_pem_cert(<<"ek-cert-pem">>, Envelope, Opts),
        {ok, EkCertRsa} = cert_rsa_public_key(EkCertDer),
        ok = assert_tpm_public_bundle(<<"ek">>, Envelope, EkCertRsa, Opts),
        ok = assert_tpm_public_bundle(<<"ak">>, Envelope, undefined, Opts),
        RecipientDetail = assert_secret_recipient_material(Envelope, Opts),
        {ok, <<"EK cert public key matches EK TPMT_PUBLIC; TPM Names and "
               "PEMs agree for EK/AK", RecipientDetail/binary>>}
    catch
        throw:{tpm_identity, Detail} ->
            {error, Detail};
        error:{badmatch, {error, Why}} ->
            {error, reason_to_text(Why)};
        Class:Reason ->
            {error, reason_to_text({Class, Reason})}
    end.

assert_tpm_public_bundle(Prefix, Envelope, CertRsa, Opts) ->
    PublicKey = <<Prefix/binary, "-public">>,
    PemKey = <<Prefix/binary, "-pub-pem">>,
    NameKey = <<Prefix/binary, "-name">>,
    Public = required_decoded_field(PublicKey, Envelope, Opts),
    {ok, TpmRsa} = tpm_public_rsa_key(Public),
    {ok, PemRsa} = decode_pem_rsa_pub(
        required_binary_field(PemKey, Envelope, Opts)),
    ok = assert_rsa_equal(PemKey, PemRsa, PublicKey, TpmRsa),
    case CertRsa of
        undefined -> ok;
        _ -> assert_rsa_equal(<<"ek-cert-pem">>, CertRsa, PublicKey, TpmRsa)
    end,
    {ok, ExpectedName} = tpm_public_name(Public),
    case required_decoded_field(NameKey, Envelope, Opts) of
        ExpectedName -> ok;
        _ -> tpm_identity_error(<<NameKey/binary, " does not match ",
                                  PublicKey/binary>>)
    end.

assert_secret_recipient_material(Envelope, Opts) ->
    case hb_maps:get(<<"secret-recipient">>, Envelope, undefined, Opts) of
        undefined ->
            <<" (no secret-recipient in raw TPM evidence)">>;
        Recipient when is_map(Recipient) ->
            ok = assert_secret_recipient_material(Envelope, Recipient, Opts),
            <<"; secret-recipient material agrees with verified TPM evidence">>;
        _ ->
            tpm_identity_error(<<"secret-recipient invalid">>)
    end.

assert_secret_recipient_material(Envelope, Recipient, Opts) ->
    PublicMaterial =
        required_map_field(<<"public-material">>, Recipient, Opts),
    ok = assert_recipient_field(
        <<"measurement-device">>, Recipient, <<"tpm@2.0a">>, Opts),
    ok = assert_recipient_field(
        <<"method">>, Recipient, <<"tpm2-activate-credential">>, Opts),
    ok = assert_recipient_field(
        <<"key-id">>, Recipient,
        required_binary_field(<<"ak-name">>, Envelope, Opts),
        Opts),
    lists:foreach(
        fun(Key) ->
            ok = assert_recipient_field(
                Key, Recipient,
                required_binary_field(Key, Envelope, Opts),
                Opts),
            ok = assert_recipient_field(
                Key, PublicMaterial,
                required_binary_field(Key, Envelope, Opts),
                Opts)
        end,
        [<<"ek-public">>, <<"ek-pub-pem">>,
         <<"ak-public">>, <<"ak-pub-pem">>, <<"ak-name">>]),
    lists:foreach(
        fun(Key) ->
            ok = assert_recipient_field(
                Key, Recipient,
                required_binary_field(Key, Envelope, Opts),
                Opts)
        end,
        [<<"ek-name">>, <<"ek-qualified-name">>, <<"ak-qualified-name">>]),
    Binding = required_map_field(<<"binding">>, Recipient, Opts),
    ok = assert_recipient_field(
        <<"kind">>, Binding, <<"ak-policy-pcr">>, Opts),
    ok = assert_recipient_field(
        <<"pcr">>, Binding, ?NODE_IDENTITY_PCR, Opts),
    ok = assert_recipient_field(
        <<"policy-pcrs">>, Binding, ?AK_POLICY_PCRS, Opts),
    ok.

assert_recipient_field(Key, Msg, Expected, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        Expected -> ok;
        _ -> tpm_identity_error(<<"secret-recipient.", Key/binary,
                                  " does not match verified TPM material">>)
    end.

required_pem_cert(Key, Msg, Opts) ->
    case decode_pem_cert(required_binary_field(Key, Msg, Opts)) of
        {ok, Der} -> Der;
        {error, Why} ->
            tpm_identity_error(
                iolist_to_binary(io_lib:format("~s invalid: ~p",
                                                [Key, Why])))
    end.

required_binary_field(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> B;
        _ -> tpm_identity_error(<<Key/binary, " missing">>)
    end.

required_decoded_field(Key, Msg, Opts) ->
    B = required_binary_field(Key, Msg, Opts),
    try hb_util:decode(B) of
        Decoded when is_binary(Decoded), byte_size(Decoded) > 0 ->
            Decoded;
        _ ->
            tpm_identity_error(<<Key/binary, " did not decode to bytes">>)
    catch
        _:_ -> tpm_identity_error(<<Key/binary, " is not base64url">>)
    end.

required_map_field(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        M when is_map(M) -> M;
        _ -> tpm_identity_error(<<Key/binary, " missing">>)
    end.

cert_rsa_public_key(Der) ->
    case cert_public_key(Der) of
        {#'RSAPublicKey'{} = Rsa, _Params} -> {ok, Rsa};
        Other -> {error, {unsupported_ek_cert_public_key, Other}}
    end.

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

assert_rsa_equal(LeftKey, Left, RightKey, Right) ->
    case rsa_public_key_tuple(Left) =:= rsa_public_key_tuple(Right) of
        true -> ok;
        false ->
            tpm_identity_error(<<LeftKey/binary, " does not match ",
                                  RightKey/binary>>)
    end.

rsa_public_key_tuple(#'RSAPublicKey'{modulus = N, publicExponent = E}) ->
    {N, E}.

tpm_public_rsa_key(Tpm2BPublic) ->
    try
        {ok, Public} = tpm2b_public_body(Tpm2BPublic),
        <<16#0001:16/unsigned-big, _NameAlg:16/unsigned-big,
          _Attrs:32/unsigned-big, Rest0/binary>> = Public,
        {_AuthPolicy, Rest1} = tpm2b(Rest0),
        Rest2 = skip_tpm2_symmetric_def(Rest1),
        Rest3 = skip_tpm2_rsa_scheme(Rest2),
        <<_KeyBits:16/unsigned-big, Exponent0:32/unsigned-big,
          Rest4/binary>> = Rest3,
        {ModulusBin, _Rest5} = tpm2b(Rest4),
        Exponent =
            case Exponent0 of
                0 -> 65537;
                _ -> Exponent0
            end,
        {ok, #'RSAPublicKey'{
            modulus = binary:decode_unsigned(ModulusBin),
            publicExponent = Exponent
        }}
    catch
        _:_ -> {error, bad_tpm2b_public_rsa}
    end.

tpm_public_name(Tpm2BPublic) ->
    try
        {ok, Public} = tpm2b_public_body(Tpm2BPublic),
        <<_Type:16/unsigned-big, NameAlg:16/unsigned-big, _/binary>> = Public,
        {ok, Hash} = tpm_name_hash_alg(NameAlg),
        {ok, <<NameAlg:16/unsigned-big,
               (crypto:hash(Hash, Public))/binary>>}
    catch
        _:_ -> {error, bad_tpm2b_public_name}
    end.

tpm_identity_error(Detail) when is_binary(Detail) ->
    throw({tpm_identity, Detail}).

chk_quote(Envelope, ExpectedNonce) ->
    Q = hb_maps:get(<<"tpm-quote">>, Envelope, #{}, #{}),
    AkPem = hb_maps:get(<<"ak-pub-pem">>, Envelope, <<>>, #{}),
    AkQualifiedName =
        safe_decode(hb_maps:get(<<"ak-qualified-name">>, Envelope, <<>>, #{})),
    Quoted = hb_util:decode(hb_maps:get(<<"quoted">>, Q, <<>>, #{})),
    Sig    = hb_util:decode(hb_maps:get(<<"signature">>, Q, <<>>, #{})),
    Nonce  = hb_util:decode(hb_maps:get(<<"nonce">>, Q, <<>>, #{})),
    Sel    = hb_maps:get(<<"pcr-selection">>, Q, [], #{}),
    PcrMap = hb_maps:get(<<"pcr-values">>, Q, #{}, #{}),

    case ExpectedNonce =/= undefined andalso Nonce =/= ExpectedNonce of
        true ->
            {error, <<"quote nonce does not match verifier challenge">>};
        false ->
            case decode_pem_rsa_pub(AkPem) of
                {ok, RSAPub} ->
                    case rsa_pss:verify(Quoted, sha256, Sig, RSAPub) of
                        true ->
                            chk_tpms_attest(
                                Quoted, Nonce, Sel, PcrMap,
                                AkQualifiedName);
                        false ->
                            {error, <<"RSA-PSS(SHA256) verify of "
                                      "TPMS_ATTEST failed">>}
                    end;
                {error, Why} ->
                    {error, iolist_to_binary(
                        io_lib:format("ak_pub_pem invalid: ~p", [Why]))}
            end
    end.

chk_tpms_attest(Quoted, ExpectedNonce, SelIndices, PcrMap,
                ExpectedQualifiedSigner) ->
    try
        <<16#ff544347:32/unsigned-big, 16#8018:16/unsigned-big,
          Rest0/binary>> = Quoted,
        {QualifiedSigner, Rest1} = tpm2b(Rest0),
        {ExtraData, Rest2}       = tpm2b(Rest1),
        <<_ClockFwInfo:25/binary, NSel:32/unsigned-big,
          SelAndDigest/binary>> = Rest2,
        {SignedSelections, RestAfterSel} =
            parse_pcr_selections(NSel, SelAndDigest),
        {PcrDigest, _} = tpm2b(RestAfterSel),
        case {QualifiedSigner, ExtraData} of
            {ExpectedQualifiedSigner, ExpectedNonce}
                    when byte_size(ExpectedQualifiedSigner) > 0 ->
                SignedIndices = signed_sha256_pcr_indices(SignedSelections),
                ReportedIndices = normalize_pcr_indices(SelIndices),
                case SignedIndices of
                    ReportedIndices -> ok;
                    _ ->
                        throw({tpms_attest_error,
                               <<"TPMS_ATTEST PCR selection does not match "
                                 "reported pcr-selection">>})
                end,
                Computed = compute_pcr_digest(SignedIndices, PcrMap),
                case Computed of
                    PcrDigest ->
                        {ok,
                            iolist_to_binary(io_lib:format(
                                "sig ok; extraData matches nonce (~B bytes); "
                                "pcrDigest matches ~B reported PCRs",
                                [byte_size(ExtraData),
                                 length(SignedIndices)]))};
                    _ ->
                        {error, <<"quote pcrDigest does not match "
                                  "sha256(pcr_values)">>}
                end;
            {_, ExpectedNonce} ->
                {error, <<"TPMS_ATTEST qualifiedSigner does not match "
                          "attested AK qualified name">>};
            {_, _} ->
                {error,
                    iolist_to_binary(io_lib:format(
                        "extraData != nonce (got ~B bytes, expected ~B)",
                        [byte_size(ExtraData), byte_size(ExpectedNonce)]))}
        end
    catch
        throw:{tpms_attest_error, Reason} ->
            {error, Reason};
        error:{badmatch, _} ->
            {error, <<"TPMS_ATTEST parse error (truncated or wrong shape)">>}
    end.

tpm2b(<<Size:16/unsigned-big, Payload:Size/binary, Rest/binary>>) ->
    {Payload, Rest}.

parse_pcr_selections(Count, Bin) ->
    parse_pcr_selections(Count, Bin, []).

parse_pcr_selections(0, Rest, Acc) ->
    {lists:reverse(Acc), Rest};
parse_pcr_selections(N, <<Hash:16/unsigned-big, SizeSelect:8/unsigned-big,
                          Selection:SizeSelect/binary, Rest/binary>>, Acc)
        when N > 0 ->
    parse_pcr_selections(
        N - 1, Rest, [{Hash, pcr_select_indices(Selection)} | Acc]).

pcr_select_indices(Selection) ->
    pcr_select_indices(Selection, 0, []).

pcr_select_indices(<<>>, _Base, Acc) ->
    lists:reverse(Acc);
pcr_select_indices(<<Byte:8/unsigned, Rest/binary>>, Base, Acc) ->
    Bits = [Base + I || I <- lists:seq(0, 7),
                        (Byte band (1 bsl I)) =/= 0],
    pcr_select_indices(Rest, Base + 8, lists:reverse(Bits) ++ Acc).

signed_sha256_pcr_indices(Selections) ->
    case [Indices || {16#000B, Indices} <- Selections] of
        [] ->
            throw({tpms_attest_error,
                   <<"TPMS_ATTEST has no SHA-256 PCR selection">>});
        Lists ->
            lists:append(Lists)
    end.

normalize_pcr_indices(Indices) when is_list(Indices) ->
    lists:sort([normalize_pcr_index(I) || I <- Indices]);
normalize_pcr_indices(_) ->
    [].

normalize_pcr_index(I) when is_integer(I) -> I;
normalize_pcr_index(B) when is_binary(B) -> binary_to_integer(B).

compute_pcr_digest(Indices, PcrMap) ->
    Concat =
        lists:foldl(
            fun(I, Acc) ->
                Key = integer_to_binary(I),
                B64 = hb_maps:get(Key, PcrMap, undefined, #{}),
                case B64 of
                    undefined -> throw({missing_pcr, I});
                    _ -> <<Acc/binary, (hb_util:decode(B64))/binary>>
                end
            end,
            <<>>, Indices),
    crypto:hash(sha256, Concat).

chk_ak_policy_bound(Envelope) ->
    AkPublic = safe_decode(hb_maps:get(<<"ak-public">>, Envelope, <<>>, #{})),
    Q = hb_maps:get(<<"tpm-quote">>, Envelope, #{}, #{}),
    PcrMap = hb_maps:get(<<"pcr-values">>, Q, #{}, #{}),
    case tpm2b_public_auth_policy(AkPublic) of
        {ok, <<>>} ->
            {error, <<"AK authPolicy is empty">>};
        {ok, Policy} when byte_size(Policy) =:= 32 ->
            ExpectedPolicy = ak_policy_digest_result(?AK_POLICY_PCRS, PcrMap),
            case ExpectedPolicy of
                {ok, Policy} ->
                    {ok, <<"AK authPolicy matches the LapEE PCR policy">>};
                {missing_pcr, I} ->
                    {error, iolist_to_binary(
                        io_lib:format("quote omitted AK policy PCR ~B", [I]))};
                invalid ->
                    {error, <<"could not compute AK policy digest">>};
                _ ->
                    {error, <<"AK authPolicy does not match quoted PCR state">>}
            end;
        {ok, _} ->
            {error, <<"AK authPolicy has unexpected size">>};
        {error, Why} ->
            {error, iolist_to_binary(
                io_lib:format("bad AK TPMT_PUBLIC authPolicy: ~p", [Why]))}
    end.

ak_policy_digest(Pcrs, PcrMap) ->
    PcrPolicy = policy_pcr_digest(Pcrs, PcrMap),
    ActivatePolicy =
        crypto:hash(
            sha256,
            <<PcrPolicy/binary,
              ?TPM_CC_POLICY_COMMAND_CODE:32/unsigned-big,
              ?TPM_CC_ACTIVATE_CREDENTIAL:32/unsigned-big>>),
    crypto:hash(
        sha256,
        <<0:256, ?TPM_CC_POLICY_OR:32/unsigned-big,
          PcrPolicy/binary, ActivatePolicy/binary>>).

policy_pcr_digest(Pcrs, PcrMap) ->
    PcrDigest = compute_pcr_digest(Pcrs, PcrMap),
    Selection = policy_pcr_selection(Pcrs),
    crypto:hash(sha256, <<0:256, ?TPM_CC_POLICY_PCR:32/unsigned-big,
                          Selection/binary, PcrDigest/binary>>).

policy_pcr_selection(Pcrs) ->
    Selected = normalize_pcr_indices(Pcrs),
    SelectBytes =
        << <<(pcr_select_byte(Selected, Byte)):8/unsigned>>
           || Byte <- lists:seq(0, 2) >>,
    <<1:32/unsigned-big, 16#000B:16/unsigned-big, 3:8/unsigned-big,
      SelectBytes/binary>>.

pcr_select_byte(Pcrs, Byte) ->
    lists:foldl(
        fun(I, Acc) when I div 8 =:= Byte -> Acc bor (1 bsl (I rem 8));
           (_, Acc) -> Acc
        end,
        0,
        Pcrs).

ak_policy_digest_result(Pcrs, PcrMap) ->
    try {ok, ak_policy_digest(Pcrs, PcrMap)}
    catch
        throw:{missing_pcr, I} -> {missing_pcr, I};
        _:_ -> invalid
    end.

chk_event_log_replay(Envelope) ->
    Events = [E || E <- hb_maps:get(<<"runtime-event-log">>, Envelope, [],
                                    #{}),
                   int_pcr(hb_maps:get(<<"pcr">>, E, 0, #{})) =:=
                       ?NODE_IDENTITY_PCR],
    Quoted15 =
        hb_maps:get(<<"15">>,
            hb_maps:get(<<"pcr-values">>,
                hb_maps:get(<<"tpm-quote">>, Envelope, #{}, #{}), #{}, #{}),
            undefined, #{}),
    case {Events, Quoted15} of
        {[], _} ->
            {error, <<"no PCR-15 events in runtime_event_log "
                      "(LapEE guest must extend PCR 15 via on.start)">>};
        {_, undefined} ->
            {error, <<"envelope has no tpm_quote.pcr_values[15]">>};
        _ ->
            Replayed =
                lists:foldl(
                    fun(E, Acc) ->
                        Dig = hb_util:decode(
                                hb_maps:get(<<"digest">>, E, <<>>, #{})),
                        crypto:hash(sha256, <<Acc/binary, Dig/binary>>)
                    end,
                    <<0:256>>, Events),
            case hb_util:decode(Quoted15) of
                Replayed ->
                    {ok,
                        iolist_to_binary(io_lib:format(
                            "~B PCR-15 event(s) replay to ~s",
                            [length(Events),
                             binary:part(hb_util:encode(Replayed), 0, 16)]))};
                _ ->
                    {error, <<"replay != quoted pcr_values[15]">>}
            end
    end.

int_pcr(V) when is_integer(V) -> V;
int_pcr(V) when is_binary(V)  -> binary_to_integer(V).

chk_binding(Envelope) ->
    ExpectedId =
        hb_maps:get(<<"node-message-id">>, Envelope, undefined, #{}),
    Events = [E || E <- hb_maps:get(<<"runtime-event-log">>, Envelope, [],
                                    #{}),
                   int_pcr(hb_maps:get(<<"pcr">>, E, 0, #{})) =:=
                       ?NODE_IDENTITY_PCR],
    case {ExpectedId, Events} of
        {undefined, _} -> {error, <<"no node_message_id in envelope">>};
        {_, []}        -> {error, <<"no PCR-15 events">>};
        {Id, _} ->
            IdRaw =
                try hb_util:decode(Id)
                catch _:_ -> <<>>
                end,
            case byte_size(IdRaw) of
                32 ->
                    Match = [E || E <- Events,
                                  hb_util:decode(
                                    hb_maps:get(<<"digest">>, E, <<>>, #{}))
                                      =:= IdRaw],
                    case Match of
                        [] ->
                            {error, iolist_to_binary(io_lib:format(
                                "no PCR-15 event matches node_message_id ~s",
                                [binary:part(Id, 0,
                                             min(16, byte_size(Id)))]))};
                        [E|_] ->
                            Seq = hb_maps:get(<<"seq">>, E, <<>>, #{}),
                            {ok, iolist_to_binary(io_lib:format(
                                "match at seq=~p", [Seq]))}
                    end;
                Size ->
                    {error, iolist_to_binary(io_lib:format(
                        "node_message_id decodes to ~B bytes, expected 32",
                        [Size]))}
            end
    end.

chk_measurement_body_binding(Envelope, Opts) ->
    Body = hb_maps:get(
        <<"measurement-body">>,
        Envelope,
        hb_maps:get(<<"body">>, Envelope, undefined, #{}),
        #{}),
    ExtendedSubject =
        hb_maps:get(<<"extended-subject">>, Envelope, undefined, #{}),
    case {Body, ExtendedSubject} of
        {M, SubjectID} when is_map(M), is_binary(SubjectID) ->
            ExpectedID = measurement_body_id(M, Opts),
            case SubjectID of
                ExpectedID ->
                    chk_measurement_body_digest(Envelope, ExpectedID);
                _ ->
                    {error, iolist_to_binary(io_lib:format(
                        "extended_subject ~s does not match body id ~s",
                        [short_id(SubjectID), short_id(ExpectedID)]))}
            end;
        {undefined, _} ->
            {error, <<"missing measurement body">>};
        {_, undefined} ->
            {error, <<"missing extended_subject">>};
        _ ->
            {error, <<"measurement body or extended_subject has wrong shape">>}
    end.

chk_measurement_body_digest(Envelope, SubjectID) ->
    ExpectedDigest = hb_util:encode(hb_util:native_id(SubjectID)),
    case hb_maps:get(
        <<"extended-subject-digest">>,
        Envelope,
        ExpectedDigest,
        #{}) of
        ExpectedDigest ->
            {ok, iolist_to_binary(io_lib:format(
                "measurement body id ~s", [short_id(SubjectID)]))};
        Other ->
            {error, iolist_to_binary(io_lib:format(
                "extended_subject_digest ~s does not match body id digest ~s",
                [short_id(Other), short_id(ExpectedDigest)]))}
    end.

short_id(Bin) when is_binary(Bin) ->
    binary:part(Bin, 0, min(16, byte_size(Bin)));
short_id(Value) ->
    to_bin(Value).

chk_node_msg_shape(Envelope) ->
    Nm = hb_maps:get(<<"node-message">>, Envelope, undefined, #{}),
    Id = hb_maps:get(<<"node-message-id">>, Envelope, undefined, #{}),
    case {Nm, Id} of
        {undefined, _} -> {error, <<"missing node_message">>};
        {_, undefined} -> {error, <<"missing node_message_id">>};
        {M, B} when is_map(M), is_binary(B), byte_size(B) =:= 43 ->
            {ok, iolist_to_binary(io_lib:format(
                "node_message is ~B-key map; id is 43-char base64url",
                [maps:size(M)]))};
        {_, B} when is_binary(B) ->
            {error, iolist_to_binary(io_lib:format(
                "node_message_id wrong size (~B, expected 43)",
                [byte_size(B)]))};
        _ ->
            {error, <<"node_message/_id have unexpected shape">>}
    end.

decode_pem_cert(<<>>) -> {error, empty};
decode_pem_cert(Pem) when is_binary(Pem) ->
    case public_key:pem_decode(Pem) of
        [{'Certificate', Der, not_encrypted} | _] -> {ok, Der};
        Other -> {error, {unexpected_pem_content, Other}}
    end.

decode_pem_certs(<<>>) -> {error, empty};
decode_pem_certs(Pem) when is_binary(Pem) ->
    Certs =
        [
            Der
        ||
            {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)
        ],
    case Certs of
        [] -> {error, empty};
        _ -> {ok, Certs}
    end.

decode_pem_rsa_pub(<<>>) -> {error, empty};
decode_pem_rsa_pub(Pem) when is_binary(Pem) ->
    case public_key:pem_decode(Pem) of
        [Entry | _] ->
            try
                case public_key:pem_entry_decode(Entry) of
                    #'RSAPublicKey'{} = Rsa -> {ok, Rsa};
                    Other -> {error, {unsupported_pub_key_type, Other}}
                end
            catch
                Cls:R -> {error, {Cls, R}}
            end;
        _ -> {error, no_pem_entries}
    end.


read_tcg_event_log() ->
    {Bin, _Source} = read_tcg_event_log_with_source(),
    Bin.

read_tcg_event_log_with_source() ->
    Paths = [
        <<"/sys/kernel/security/tpm0/binary_bios_measurements">>,
        <<"/sys/kernel/security/tpm1/binary_bios_measurements">>
    ],
    read_first_available_with_source(Paths).

read_first_available_with_source([]) ->
    {<<>>, <<"unavailable">>};
read_first_available_with_source([Path | Rest]) ->
    case file:read_file(binary_to_list(Path)) of
        {ok, Bin} when is_binary(Bin), byte_size(Bin) > 0 ->
            {Bin, Path};
        _ ->
            read_first_available_with_source(Rest)
    end.

infer_log_format(<<>>) -> <<"empty">>;
infer_log_format(Bin) when byte_size(Bin) < 32 ->
    <<"unknown">>;
infer_log_format(Bin) ->
    <<Pcr:32/little, EvType:32/little,
      _Sha1:20/binary, DataSize:32/little, Rest/binary>> = Bin,
    IsSpecId = EvType =:= 3 andalso DataSize >= 15 andalso
        byte_size(Rest) >= DataSize andalso
        binary:longest_common_prefix(
          [binary:part(Rest, 0, 15),
           <<"Spec ID Event03">>]) >= 15,
    if
        Pcr =/= 0 andalso IsSpecId -> <<"tdx-ccel">>;
        IsSpecId                    -> <<"crypto-agile">>;
        true                        -> <<"legacy-sha1">>
    end.


supported(_Base, _Req, _Opts) ->
    case nif_startup() of
        ok -> {ok, true};
        {error, _} -> {ok, false}
    end.

subject(_Base, Req, Opts) ->
    case prepare_measurement_subject(Req, Opts) of
        {ok, _Subject, _SubjectID, _SubjectDigest} ->
            Subject = credential_subject_body(Opts),
            {ok, #{
                <<"status">> => 200,
                <<"body">> => hb_message:commit(Subject, Opts)
            }};
        {error, Reason} ->
            error_resp(500, <<"subject_failed">>, Reason)
    end.

measure(_Base, Req, Opts) ->
    try
        {ok, Subject, SubjectID, SubjectDigest} =
            prepare_measurement_subject(Req, Opts),
        Nonce = resolve_nonce(Req),
        Tpm = boot_tpm_evidence(
            Subject, SubjectID, SubjectDigest, Nonce, Opts),
        {ok, #{<<"status">> => 200, <<"body">> => Tpm}}
    catch
        throw:{boot_attestation_error, Reason} ->
            error_resp(500, <<"measure_failed">>, Reason);
        Class:Reason:Stack ->
            error_resp(500, <<"measure_failed">>,
                       #{<<"class">> => to_bin(Class),
                         <<"reason">> => to_bin(Reason),
                         <<"stack">> => reason_to_text(Stack)})
    end.

credential_subject_body(Opts) ->
    AkName = ak_name(Opts),
    #{
        <<"type">> => <<"lapee-tpm-credential-subject">>,
        <<"version">> => <<"1.0">>,
        <<"measurement-device">> => <<"tpm@2.0a">>,
        <<"method">> => <<"tpm2-activate-credential">>,
        <<"key-id">> => AkName,
        <<"binding">> => #{
            <<"kind">> => <<"ak-policy-pcr">>,
            <<"pcr">> => ?NODE_IDENTITY_PCR,
            <<"policy-pcrs">> => ?AK_POLICY_PCRS
        },
        <<"ek-cert-pem">> => ek_cert_pem(Opts),
        <<"ek-cert-chain-pem">> => ek_cert_chain_pem(),
        <<"ek-cert-source">> => ek_cert_source(),
        <<"ek-pub-pem">> => ek_pub_pem(Opts),
        <<"ek-public">> => ek_public(Opts),
        <<"ek-name">> => ek_name(Opts),
        <<"ek-qualified-name">> => ek_qualified_name(Opts),
        <<"ak-pub-pem">> => ak_pub_pem(Opts),
        <<"ak-public">> => ak_public(Opts),
        <<"ak-name">> => AkName,
        <<"ak-qualified-name">> => ak_qualified_name(Opts),
        <<"public-material">> => #{
            <<"ek-public">> => ek_public(Opts),
            <<"ek-pub-pem">> => ek_pub_pem(Opts),
            <<"ak-public">> => ak_public(Opts),
            <<"ak-pub-pem">> => ak_pub_pem(Opts),
            <<"ak-name">> => AkName
        },
        <<"tpm-properties">> => tpm_properties()
    }.

unwrap_secret(_Base, Req, Opts) ->
    with_ok(
        fun() ->
            {ok, CertInfo} = activate_credential_secret(Req, Opts),
            Msg = hb_message:commit(
                credential_activation_public_body(CertInfo, Req, Opts),
                Opts),
            #{<<"status">> => 200, <<"body">> => Msg}
        end).

activate_credential_secret(Credential, Opts) ->
    CredentialBlob = decode_required(<<"credential-blob">>, Credential, Opts),
    Secret = decode_required(<<"secret">>, Credential, Opts),
    {ok, AkTr} = ensure_ak(Opts),
    EKTr = persistent_term:get({dev_tpm2, ek_tr}),
    case nif_activate_credential(AkTr, EKTr, CredentialBlob, Secret) of
        {ok, CertInfo} -> {ok, CertInfo};
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"activate-credential">> => reason_to_text(Reason)}})
    end.

credential_activation_public_body(CertInfo, Credential, Opts) ->
    Now = erlang:system_time(second),
    AkName = ak_name(Opts),
    #{
        <<"type">> => <<"lapee-tpm-credential-activation">>,
        <<"version">> => <<"1.0">>,
        <<"issued-at-unix">> => Now,
        <<"ak-name">> => AkName,
        <<"credential-secret-sha256">> =>
            hb_util:encode(crypto:hash(sha256, CertInfo)),
        <<"proof-alg">> => <<"HMAC-SHA256">>,
        <<"credential-secret-proof">> =>
            hb_util:encode(
                credential_activation_proof(
                    CertInfo, Credential, AkName, Now))
    }.

make_credential_for_subject(Subject, Secret) ->
    EkPublic = hb_util:decode(
        tpm_subject_field(<<"ek-public">>, Subject)),
    AkName = hb_util:decode(
        tpm_subject_field(<<"ak-name">>, Subject)),
    software_make_credential(EkPublic, AkName, Secret).

software_make_credential(EkPublic, AkName, Secret) ->
    try
        Params = credential_public_params(EkPublic),
        #{hash := Hash, rsa := Rsa, sym_bits := SymBits} = Params,
        HashBytes = hash_size(Hash),
        Seed = crypto:strong_rand_bytes(HashBytes),
        EncryptedSeed = public_key:encrypt_public(
            Seed,
            Rsa,
            [
                {rsa_padding, rsa_pkcs1_oaep_padding},
                {rsa_oaep_md, Hash},
                {rsa_mgf1_md, Hash},
                {rsa_oaep_label, <<"IDENTITY", 0>>}
            ]),
        SymKey = kdfa(Hash, Seed, <<"STORAGE">>, AkName, <<>>, SymBits),
        IV = <<0:128>>,
        PlainIdentity = <<
            (byte_size(Secret)):16/unsigned-big,
            Secret/binary
        >>,
        EncIdentity =
            crypto:crypto_one_time(
                aes_cfb_cipher(SymBits), SymKey, IV, PlainIdentity, true),
        HmacKey =
            kdfa(Hash, Seed, <<"INTEGRITY">>, <<>>, <<>>, HashBytes * 8),
        Integrity =
            crypto:mac(
                hmac, Hash, HmacKey,
                <<EncIdentity/binary, AkName/binary>>),
        IDObject = <<
            (byte_size(Integrity)):16/unsigned-big,
            Integrity/binary,
            EncIdentity/binary
        >>,
        #{
            <<"credential-blob">> =>
                hb_util:encode(<<
                    (byte_size(IDObject)):16/unsigned-big,
                    IDObject/binary
                >>),
            <<"secret">> =>
                hb_util:encode(<<
                    (byte_size(EncryptedSeed)):16/unsigned-big,
                    EncryptedSeed/binary
                >>)
        }
    catch
        Class:Reason ->
            throw({boot_attestation_error, #{
                <<"make-credential">> =>
                    reason_to_text({software, Class, Reason})
            }})
    end.

credential_public_params(EkPublic) ->
    {ok, Public} = tpm2b_public_body(EkPublic),
    <<16#0001:16/unsigned-big, NameAlg:16/unsigned-big,
      _Attrs:32/unsigned-big, Rest0/binary>> = Public,
    {ok, Hash} = tpm_name_hash_alg(NameAlg),
    {_AuthPolicy, Rest1} = tpm2b(Rest0),
    {SymBits, Rest2} = rsa_symmetric_params(Rest1),
    Rest3 = skip_tpm2_rsa_scheme(Rest2),
    <<_KeyBits:16/unsigned-big, Exponent0:32/unsigned-big, Rest4/binary>> =
        Rest3,
    {ModulusBin, _Rest5} = tpm2b(Rest4),
    Exponent =
        case Exponent0 of
            0 -> 65537;
            _ -> Exponent0
        end,
    #{
        hash => Hash,
        sym_bits => SymBits,
        rsa => #'RSAPublicKey'{
            modulus = binary:decode_unsigned(ModulusBin),
            publicExponent = Exponent
        }
    }.

rsa_symmetric_params(<<16#0006:16/unsigned-big,
                       KeyBits:16/unsigned-big,
                       16#0043:16/unsigned-big,
                       Rest/binary>>) ->
    {KeyBits, Rest};
rsa_symmetric_params(<<16#0010:16/unsigned-big, _Rest/binary>>) ->
    throw(unsupported_null_symmetric);
rsa_symmetric_params(_) ->
    throw(bad_tpm2b_public_symmetric).

skip_tpm2_symmetric_def(<<16#0010:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_symmetric_def(<<16#0006:16/unsigned-big,
                          _KeyBits:16/unsigned-big,
                          _Mode:16/unsigned-big,
                          Rest/binary>>) ->
    Rest;
skip_tpm2_symmetric_def(_) ->
    throw(bad_tpm2b_public_symmetric).

hash_size(sha) -> 20;
hash_size(sha256) -> 32;
hash_size(sha384) -> 48;
hash_size(sha512) -> 64.

aes_cfb_cipher(128) -> aes_128_cfb128;
aes_cfb_cipher(256) -> aes_256_cfb128;
aes_cfb_cipher(Other) -> throw({unsupported_symmetric_key_bits, Other}).

kdfa(Hash, Key, Label, ContextU, ContextV, Bits) ->
    Bytes = (Bits + 7) div 8,
    Derived = kdfa_blocks(Hash, Key, Label, ContextU, ContextV, Bits, 1, <<>>),
    binary:part(Derived, 0, Bytes).

kdfa_blocks(_Hash, _Key, _Label, _ContextU, _ContextV, Bits, _Counter, Acc)
        when bit_size(Acc) >= Bits ->
    Acc;
kdfa_blocks(Hash, Key, Label, ContextU, ContextV, Bits, Counter, Acc) ->
    Block = crypto:mac(
        hmac,
        Hash,
        Key,
        <<Counter:32/unsigned-big, Label/binary, 0,
          ContextU/binary, ContextV/binary, Bits:32/unsigned-big>>),
    kdfa_blocks(
        Hash, Key, Label, ContextU, ContextV, Bits, Counter + 1,
        <<Acc/binary, Block/binary>>).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

ensure_activation_secret(Activation, Credential, Expected, Subject, Opts) ->
    ok = ensure_activation_envelope(Activation, Subject, Opts),
    ExpectedHash = hb_util:encode(crypto:hash(sha256, Expected)),
    AkName = hb_maps:get(<<"ak-name">>, Activation, <<>>, Opts),
    IssuedAt = hb_maps:get(<<"issued-at-unix">>, Activation, 0, Opts),
    ExpectedProof =
        credential_activation_proof(Expected, Credential, AkName, IssuedAt),
    GotHash = hb_maps:get(
        <<"credential-secret-sha256">>, Activation, <<>>, Opts),
    GotProof = safe_decode(
        hb_maps:get(<<"credential-secret-proof">>, Activation, <<>>, Opts)),
    case {GotHash, GotProof} of
        {ExpectedHash, ExpectedProof} -> ok;
        _ -> throw({boot_attestation_error,
                    #{<<"credential-activation">> =>
                        <<"activation proof did not match challenge">>}})
    end.

ensure_activation_envelope(Activation, Subject, Opts) ->
    ok = ensure_no_activation_error(Activation, Opts),
    Checks = [
        {eq, <<"type">>, <<"lapee-tpm-credential-activation">>},
        {eq, <<"version">>, <<"1.0">>},
        {eq, <<"proof-alg">>, <<"HMAC-SHA256">>},
        {binary, <<"ak-name">>},
        {integer, <<"issued-at-unix">>},
        {binary, <<"credential-secret-sha256">>},
        {binary, <<"credential-secret-proof">>}
    ],
    lists:foreach(
        fun
            ({eq, Key, Expected}) ->
                case hb_maps:get(Key, Activation, undefined, Opts) of
                    Expected -> ok;
                    _ -> bad_activation(Key)
                end;
            ({binary, Key}) ->
                case hb_maps:get(Key, Activation, undefined, Opts) of
                    B when is_binary(B), byte_size(B) > 0 -> ok;
                    _ -> bad_activation(Key)
                end;
            ({integer, Key}) ->
                case hb_maps:get(Key, Activation, undefined, Opts) of
                    I when is_integer(I), I > 0 -> ok;
                    _ -> bad_activation(Key)
                end
        end,
        Checks),
    case Subject of
        undefined -> ok;
        _ ->
            ExpectedAk = tpm_subject_field(<<"ak-name">>, Subject),
            case hb_maps:get(<<"ak-name">>, Activation, <<>>, Opts) of
                ExpectedAk when byte_size(ExpectedAk) > 0 -> ok;
                _ -> bad_activation(<<"ak-name">>)
            end
    end.

tpm_subject_field(Key, Subject) when is_map(Subject) ->
    Material = hb_maps:get(<<"public-material">>, Subject, #{}, #{}),
    hb_maps:get(Key, Material, hb_maps:get(Key, Subject, <<>>, #{}), #{});
tpm_subject_field(_Key, _Subject) ->
    <<>>.

ensure_no_activation_error(Activation, Opts) when is_map(Activation) ->
    case first_defined([
        hb_maps:get(<<"activate-credential">>, Activation, undefined, Opts),
        hb_maps:get(<<"error">>, Activation, undefined, Opts),
        hb_maps:get(<<"reason">>, Activation, undefined, Opts)
    ]) of
        undefined -> ok;
        Reason ->
            throw({boot_attestation_error,
                   #{<<"credential-activation">> =>
                        reason_to_text(Reason)}})
    end;
ensure_no_activation_error(_, _Opts) ->
    ok.

bad_activation(Key) ->
    throw({boot_attestation_error,
           #{<<"credential-activation">> =>
                <<Key/binary, " invalid">>}}).

credential_activation_proof(Secret, Credential, AkName, IssuedAt) ->
    crypto:mac(
        hmac,
        sha256,
        Secret,
        credential_activation_proof_context(Credential, AkName, IssuedAt)).

credential_activation_proof_context(Credential, AkName, IssuedAt) ->
    Blob = hb_maps:get(<<"credential-blob">>, Credential, <<>>, #{}),
    EncSecret = hb_maps:get(<<"secret">>, Credential, <<>>, #{}),
    <<"lapee-tpm-credential-activation-v1\n",
      "type:lapee-tpm-credential-activation\n",
      "version:1.0\n",
      "proof-alg:HMAC-SHA256\n",
      "ak-name:", AkName/binary, "\n",
      "issued-at-unix:", (integer_to_binary(IssuedAt))/binary, "\n",
      "credential-blob:", Blob/binary, "\n",
      "secret:", EncSecret/binary>>.

tpm2b_public_body(<<Size:16/unsigned-big, Public:Size/binary, _/binary>>) ->
    {ok, Public};
tpm2b_public_body(_) ->
    {error, bad_tpm2b_public}.

tpm2b_public_auth_policy(Tpm2BPublic) ->
    try
        {ok, Public} = tpm2b_public_body(Tpm2BPublic),
        <<16#0001:16/unsigned-big, _NameAlg:16/unsigned-big,
          _Attrs:32/unsigned-big, Rest/binary>> = Public,
        {AuthPolicy, _} = tpm2b(Rest),
        {ok, AuthPolicy}
    catch
        _:_ -> {error, bad_tpm2b_public}
    end.

tpm_name_hash_alg(16#0004) -> {ok, sha};
tpm_name_hash_alg(16#000B) -> {ok, sha256};
tpm_name_hash_alg(16#000C) -> {ok, sha384};
tpm_name_hash_alg(16#000D) -> {ok, sha512};
tpm_name_hash_alg(Other) -> {error, {unsupported_name_alg, Other}}.

skip_tpm2_rsa_scheme(<<16#0010:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_rsa_scheme(<<_Scheme:16/unsigned-big,
                       _HashAlg:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_rsa_scheme(_) ->
    throw(bad_tpm2b_public_scheme).

decode_required(Key, Req, Opts) ->
    case hb_maps:get(Key, Req, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 ->
            hb_util:decode(B);
        _ ->
            throw({boot_attestation_error,
                   #{Key => <<"missing required base64url field">>}})
    end.

safe_decode(B) when is_binary(B) ->
    try hb_util:decode(B) catch _:_ -> <<>> end;
safe_decode(_) ->
    <<>>.

with_ok(Fun) ->
    try
        {ok, Fun()}
    catch
        throw:{boot_attestation_error, Reason} ->
            {error, Reason};
        Class:Reason:Stack ->
            {error, #{
                <<"class">> => to_bin(Class),
                <<"reason">> => to_bin(Reason),
                <<"stack">> => reason_to_text(Stack)
            }}
    end.

boot_subject(Opts) ->
    case persistent_term:get({dev_tpm2, attested_boot_subject}, undefined) of
        Subject when is_map(Subject) ->
            SubjectID = persistent_term:get(
                {dev_tpm2, attested_boot_subject_id},
                subject_id(Subject, Opts)),
            SubjectDigest = persistent_term:get(
                {dev_tpm2, attested_boot_subject_digest},
                hb_util:native_id(SubjectID)),
            {Subject, SubjectID, SubjectDigest};
        undefined ->
            Subject = measurement_body(Opts),
            SubjectID = subject_id(Subject, Opts),
            {Subject, SubjectID, hb_util:native_id(SubjectID)}
    end.

prepare_measurement_subject(Req, Opts) ->
    {Subject, SubjectID, SubjectDigest} =
        case hb_maps:get(<<"body">>, Req, undefined, Opts) of
            Body when is_map(Body) ->
                subject_identity_from_req(Body, Req, Opts);
            _ ->
                boot_subject(Opts)
        end,
    case ensure_ak(Subject, SubjectID, SubjectDigest, Opts) of
        {ok, _AkTr} -> {ok, Subject, SubjectID, SubjectDigest};
        {error, _} = E -> E
    end.

subject_identity_from_req(Body, Req, Opts) ->
    case internal_measurement_request(Req) of
        true ->
            case trusted_subject_id(Req, Opts) of
                {ok, ID, Digest} -> {Body, ID, Digest};
                error -> recompute_subject_identity(Body, Opts)
            end;
        false ->
            recompute_subject_identity(Body, Opts)
    end.

internal_measurement_request(Req) ->
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
                    #{}) =:= Token
    end.

trusted_subject_id(Req, Opts) ->
    case hb_maps:get(<<"body-id">>, Req, undefined, Opts) of
        ID when is_binary(ID), byte_size(ID) =:= 43 ->
            try hb_util:native_id(ID) of
                Digest when byte_size(Digest) =:= 32 ->
                    {ok, ID, Digest};
                _ ->
                    error
            catch
                _:_ -> error
            end;
        _ ->
            error
    end.

recompute_subject_identity(Body, Opts) ->
    ID = subject_id(Body, Opts),
    {Body, ID, hb_util:native_id(ID)}.

boot_tpm_evidence(Subject, SubjectID, SubjectDigest, Nonce, Opts) ->
    Pcrs = ?DEFAULT_QUOTE_PCRS,
    case ensure_ak(Subject, SubjectID, SubjectDigest, Opts) of
        {ok, AkTr} ->
            case nif_quote(AkTr, Pcrs, Nonce) of
                {ok, #{quoted := Q, signature := Sig, pcr_values := PcrMap}} ->
                    {TcgLogBin, TcgLogSource} =
                        read_tcg_event_log_with_source(),
                    #{
                        <<"extended-subject">> => SubjectID,
                        <<"extended-subject-digest">> =>
                            hb_util:encode(SubjectDigest),
                        <<"extended-pcr">> => ?NODE_IDENTITY_PCR,
                        <<"ek-cert-pem">> => ek_cert_pem(Opts),
                        <<"ek-cert-chain-pem">> => ek_cert_chain_pem(),
                        <<"ek-cert-source">> => ek_cert_source(),
                        <<"tpm-properties">> => tpm_properties(),
                        <<"ek-pub-pem">> => ek_pub_pem(Opts),
                        <<"ek-public">> => ek_public(Opts),
                        <<"ek-name">> => ek_name(Opts),
                        <<"ek-qualified-name">> => ek_qualified_name(Opts),
                        <<"ak-pub-pem">> => ak_pub_pem(Opts),
                        <<"ak-public">> => ak_public(Opts),
                        <<"ak-name">> => ak_name(Opts),
                        <<"ak-qualified-name">> => ak_qualified_name(Opts),
                        <<"ak-hierarchy">> => <<"endorsement">>,
                        <<"tpm-session-mode">> =>
                            <<"hmac-aes128cfb">>,
                        <<"quote">> => quote_body(Pcrs, Nonce, Q, Sig, PcrMap),
                        <<"runtime-event-log">> => event_log(Opts),
                        <<"tcg-event-log">> => hb_util:encode(TcgLogBin),
                        <<"tcg-event-log-source-path">> => TcgLogSource,
                        <<"tcg-event-log-length-bytes">> =>
                            byte_size(TcgLogBin),
                        <<"tcg-event-log-format">> =>
                            infer_log_format(TcgLogBin),
                        <<"signals">> => lib_lapee_tpm_tcg:boot_signals(TcgLogBin)
                    };
                {error, Reason} ->
                    throw({boot_attestation_error,
                           #{<<"quote">> => reason_to_text(Reason)}})
            end;
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"ak">> => reason_to_text(Reason)}})
    end.

extend_boot_subject(SubjectID, SubjectDigest) ->
    case nif_pcr_extend(?NODE_IDENTITY_PCR, SubjectDigest) of
        ok ->
            _ = append_event(?NODE_IDENTITY_PCR,
                #{
                    <<"event-type">> =>
                        <<"EV_HYPERBEAM_BOOT_ATTESTATION_SUBJECT">>,
                    <<"digest">> => hb_util:encode(SubjectDigest),
                    <<"subject-id">> => SubjectID,
                    <<"subject-is-message">> => true
                }),
            ok;
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"pcr-extend">> => reason_to_text(Reason)}})
    end.


quote_body(Pcrs, Nonce, Quoted, Signature, PcrMap) ->
    #{
        <<"pcr-selection">> => Pcrs,
        <<"nonce">> => hb_util:encode(Nonce),
        <<"quoted">> => hb_util:encode(Quoted),
        <<"signature">> => hb_util:encode(Signature),
        <<"pcr-values">> =>
            maps:from_list(
                [{integer_to_binary(I), hb_util:encode(V)}
                 || {I, V} <- maps:to_list(PcrMap)])
    }.


event_log(_Opts) ->
    case persistent_term:get({dev_tpm2, event_log}, undefined) of
        undefined -> [];
        L -> L
    end.

append_event(Pcr, Payload) ->
    Seq = persistent_term:get({dev_tpm2, event_seq}, 0),
    NewSeq = Seq + 1,
    Entry = Payload#{
        <<"seq">> => Seq,
        <<"pcr">> => Pcr,
        <<"emitted-at-unix">> => erlang:system_time(second)
    },
    Old = persistent_term:get({dev_tpm2, event_log}, []),
    persistent_term:put({dev_tpm2, event_log}, Old ++ [Entry]),
    persistent_term:put({dev_tpm2, event_seq}, NewSeq),
    ok.


resolve_nonce(Req) when is_map(Req) ->
    case decoded_nonce(Req) of
        undefined -> crypto:strong_rand_bytes(32);
        Decoded when byte_size(Decoded) > 64 -> crypto:strong_rand_bytes(32);
        Decoded -> Decoded
    end;
resolve_nonce(_) -> crypto:strong_rand_bytes(32).

expected_nonce(Req) ->
    decoded_nonce(Req).

decoded_nonce(Req) when is_map(Req) ->
    case maps:get(<<"nonce">>, Req, undefined) of
        undefined -> undefined;
        B when is_binary(B) ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ -> undefined
    end;
decoded_nonce(_) ->
    undefined.

subject_id(Subject, Opts) when is_map(Subject) ->
    measurement_body_id(Subject, Opts);
subject_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
subject_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    try hb_util:native_id(Bin) of
        Native when byte_size(Native) =:= 32 -> Bin;
        _ -> hb_util:encode(hb_crypto:sha256(Bin))
    catch
        _:_ -> hb_util:encode(hb_crypto:sha256(Bin))
    end;
subject_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
subject_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

measurement_body(Opts) ->
    case hb_device_load:reference(<<"measurement@1.0">>, Opts) of
        {ok, Module} -> Module:measurement_body(Opts);
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"measurement-body">> => reason_to_text(Reason)}})
    end.

measurement_body_id(Subject, Opts) ->
    case hb_device_load:reference(<<"measurement@1.0">>, Opts) of
        {ok, Module} -> Module:measurement_body_id(Subject, Opts);
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"measurement-body-id">> => reason_to_text(Reason)}})
    end.

error_resp(Status, Err, Reason) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => #{
            <<"error">> => Err,
            <<"reason">> => reason_to_text(Reason)
        }
    }}.


ensure_ak(Opts) ->
    ensure_ak(undefined, undefined, undefined, Opts).

ensure_ak(Subject, SubjectID, SubjectDigest, Opts) ->
    case persistent_term:get({dev_tpm2, ak_tr}, undefined) of
        undefined ->
            global:trans(
                {{dev_tpm2, init_chain}, self()},
                fun() ->
                    case persistent_term:get({dev_tpm2, ak_tr},
                                              undefined) of
                        undefined ->
                            case init_chain(
                                   Subject, SubjectID, SubjectDigest, Opts) of
                                ok ->
                                    {ok, persistent_term:get(
                                           {dev_tpm2, ak_tr})};
                                {error, _} = E -> E
                            end;
                        Tr -> {ok, Tr}
                    end
                end,
                [node()]);
        Tr ->
            case same_boot_subject(SubjectID, SubjectDigest) of
                ok -> {ok, Tr};
                {error, _} = E -> E
            end
    end.

init_chain(undefined, undefined, undefined, Opts) ->
    {Subject, SubjectID, SubjectDigest} = boot_subject(Opts),
    init_chain(Subject, SubjectID, SubjectDigest, Opts);
init_chain(Subject, SubjectID, SubjectDigest, Opts) ->
    case nif_startup() of
        ok ->
            capture_tpm_properties(),
            case nif_create_ek() of
                {ok, #{esys_tr := EKTr, public_pem := EKPem} = EKInfo} ->
                    persistent_term:put({dev_tpm2, ek_tr}, EKTr),
                    persistent_term:put({dev_tpm2, ek_pub_pem}, EKPem),
                    cache_tpm_public_terms(ek, EKInfo),
                    fetch_ek_cert_from_nv(Opts),
                    case extend_initial_pcr15(
                            Subject, SubjectID, SubjectDigest) of
                        ok ->
                            case nif_create_signing_key() of
                                {ok, #{esys_tr := AKTr,
                                       public_pem := AKPem} = AKInfo} ->
                                    persistent_term:put({dev_tpm2, ak_tr},
                                                        AKTr),
                                    persistent_term:put(
                                        {dev_tpm2, ak_pub_pem}, AKPem),
                                    cache_tpm_public_terms(ak, AKInfo),
                                    ok;
                                {error, _} = E -> E
                            end;
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

extend_initial_pcr15(Subject, SubjectID, SubjectDigest) ->
    case same_boot_subject(SubjectID, SubjectDigest) of
        ok ->
            record_boot_subject(Subject, SubjectID, SubjectDigest),
            case maybe_extend_boot_subject(SubjectID, SubjectDigest) of
                ok ->
                    case maybe_extend_tcg_event_log_tip() of
                        ok ->
                            persistent_term:put(
                                {dev_tpm2, initial_pcr15_extended}, true),
                            ok;
                        {error, _} = E -> E
                    end;
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

maybe_extend_boot_subject(SubjectID, SubjectDigest) ->
    case persistent_term:get({dev_tpm2, boot_subject_pcr_extended}, false) of
        true ->
            ok;
        false ->
            case extend_boot_subject(SubjectID, SubjectDigest) of
                ok ->
                    persistent_term:put(
                        {dev_tpm2, boot_subject_pcr_extended}, true),
                    ok;
                {error, _} = E -> E
            end
    end.

maybe_extend_tcg_event_log_tip() ->
    case persistent_term:get({dev_tpm2, tcg_tip_pcr_extended}, false) of
        true ->
            ok;
        false ->
            case extend_with_tcg_event_log_tip() of
                ok ->
                    persistent_term:put(
                        {dev_tpm2, tcg_tip_pcr_extended}, true),
                    ok;
                {error, _} = E -> E
            end
    end.

record_boot_subject(Subject, SubjectID, SubjectDigest) ->
    persistent_term:put({dev_tpm2, attested_boot_subject}, Subject),
    persistent_term:put({dev_tpm2, attested_boot_subject_id}, SubjectID),
    persistent_term:put({dev_tpm2, attested_boot_subject_digest},
                        SubjectDigest),
    case Subject of
        #{<<"node">> := Node} when is_map(Node) ->
            persistent_term:put({dev_tpm2, attested_node_msg}, Node);
        _ -> ok
    end.

same_boot_subject(undefined, undefined) ->
    ok;
same_boot_subject(SubjectID, SubjectDigest) ->
    case persistent_term:get({dev_tpm2, attested_boot_subject_id}, undefined) of
        undefined ->
            ok;
        SubjectID ->
            case persistent_term:get(
                   {dev_tpm2, attested_boot_subject_digest}, undefined) of
                SubjectDigest -> ok;
                _ -> {error, <<"AK already bound to different PCR15 digest">>}
            end;
        _ ->
            {error, <<"AK already bound to different boot subject">>}
    end.

cache_tpm_public_terms(Prefix, Info) ->
    lists:foreach(
        fun({Key, Slot}) ->
            case maps:get(Key, Info, undefined) of
                undefined -> ok;
                V -> persistent_term:put({dev_tpm2, Prefix, Slot}, V)
            end
        end,
        [{tpm2b_public, public},
         {name, name},
         {qualified_name, qualified_name}]).

ek_cert_pem(Opts) ->
    case persistent_term:get({dev_tpm2, ek_cert_pem}, undefined) of
        undefined ->
            _ = ensure_ak(Opts),
            persistent_term:get({dev_tpm2, ek_cert_pem}, <<>>);
        P -> P
    end.

ak_pub_pem(Opts) ->
    case persistent_term:get({dev_tpm2, ak_pub_pem}, undefined) of
        undefined ->
            _ = ensure_ak(Opts),
            persistent_term:get({dev_tpm2, ak_pub_pem}, <<>>);
        P -> P
    end.

ek_pub_pem(Opts) ->
    case persistent_term:get({dev_tpm2, ek_pub_pem}, undefined) of
        undefined ->
            _ = ensure_ak(Opts),
            persistent_term:get({dev_tpm2, ek_pub_pem}, <<>>);
        P -> P
    end.

ek_public(Opts) -> encoded_cached(ek, public, Opts).
ek_name(Opts) -> encoded_cached(ek, name, Opts).
ek_qualified_name(Opts) -> encoded_cached(ek, qualified_name, Opts).
ak_public(Opts) -> encoded_cached(ak, public, Opts).
ak_name(Opts) -> encoded_cached(ak, name, Opts).
ak_qualified_name(Opts) -> encoded_cached(ak, qualified_name, Opts).

encoded_cached(Prefix, Slot, Opts) ->
    case raw_cached(Prefix, Slot, Opts) of
        B when is_binary(B), byte_size(B) > 0 -> hb_util:encode(B);
        _ -> <<>>
    end.

raw_cached(Prefix, Slot, Opts) ->
    case persistent_term:get({dev_tpm2, Prefix, Slot}, undefined) of
        undefined ->
            _ = ensure_ak(Opts),
            persistent_term:get({dev_tpm2, Prefix, Slot}, <<>>);
        V -> V
    end.

capture_tpm_properties() ->
    try
        case nif_module() of
            not_loaded -> {error, nif_not_loaded};
            M -> M:tpm_properties()
        end
    of
        {ok, Props} ->
            persistent_term:put({dev_tpm2, tpm_properties}, Props),
            ok;
        {error, Reason} ->
            persistent_term:put(
                {dev_tpm2, tpm_properties},
                #{error => to_bin(Reason)}),
            ok
    catch C:E ->
        persistent_term:put(
            {dev_tpm2, tpm_properties},
            #{error => iolist_to_binary(
                io_lib:format("~p:~p", [C, E]))}),
        ok
    end.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> iolist_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

tpm_properties() ->
    case persistent_term:get({dev_tpm2, tpm_properties}, undefined) of
        undefined ->
            #{<<"available">> => false,
              <<"reason">>    => <<"init_chain has not executed yet">>};
        #{error := Why} ->
            #{<<"available">> => false,
              <<"reason">>    => Why};
        #{} = P ->
            FW1 = maps:get(firmware_version_1, P, 0),
            FW2 = maps:get(firmware_version_2, P, 0),
            #{
              <<"available">>            => true,
              <<"manufacturer">>         =>
                  maps:get(manufacturer, P, <<>>),
              <<"manufacturer-u32">>     =>
                  maps:get(manufacturer_u32, P, 0),
              <<"vendor-string">>        =>
                  maps:get(vendor_string, P, <<>>),
              <<"spec-family">>          =>
                  maps:get(spec_family, P, <<>>),
              <<"spec-level">>           =>
                  maps:get(spec_level, P, 0),
              <<"spec-revision">>        =>
                  maps:get(spec_revision, P, 0),
              <<"firmware-version-1">>   => FW1,
              <<"firmware-version-2">>   => FW2,
              <<"firmware-version-u64">> =>
                  (FW1 bsl 32) bor (FW2 band 16#FFFFFFFF),
              <<"day-of-year">>          =>
                  maps:get(day_of_year, P, 0),
              <<"year">>                 =>
                  maps:get(year, P, 0)
             }
    end.

ek_cert_chain_pem() ->
    persistent_term:get({dev_tpm2, ek_cert_chain_pem}, <<>>).

ek_cert_source() ->
    case persistent_term:get({dev_tpm2, ek_cert_source}, undefined) of
        undefined ->
            #{<<"kind">> => <<"unknown">>,
              <<"reason">> =>
                  <<"ensure_ak/1 has not executed yet">>};
        #{} = M ->
            maps:fold(
                fun(K, V, Acc) when is_atom(K) ->
                       Acc#{atom_to_binary(K) => V};
                   (K, V, Acc) -> Acc#{K => V}
                end, #{}, M)
    end.

-define(EK_NV_RSA_2048, 16#01C00002).  %% low-range RSA-2048 EK cert
-define(EK_NV_RSA_3072, 16#01C0000A).  %% low-range RSA-3072 EK cert
-define(EK_NV_ECC_P256, 16#01C00004).  %% low-range ECC NIST P-256
-define(EK_NV_ECC_P384, 16#01C00006).  %% low-range ECC NIST P-384
-define(EK_NV_HIGH_RSA_2048, 16#01C00012).
-define(EK_NV_HIGH_RSA_3072, 16#01C0001A).
-define(EK_NV_CHAIN_FIRST, 16#01C00100).
-define(EK_NV_CHAIN_PREFIX_LIMIT, 16).

fetch_ek_cert_from_nv(Opts) ->
    Handles = hb_opts:get(
        lapee_tpm_ek_nv_handles,
        [?EK_NV_RSA_2048,
         ?EK_NV_RSA_3072,
         ?EK_NV_ECC_P256,
         ?EK_NV_ECC_P384,
         ?EK_NV_HIGH_RSA_2048,
         ?EK_NV_HIGH_RSA_3072],
        Opts),
    case try_nv_handles(Handles, []) of
        {ok, Handle, Der} ->
            Pem = der_to_pem(Der),
            persistent_term:put({dev_tpm2, ek_cert_pem}, Pem),
            ChainHandle = Handle + 1,
            {ChainDers, ChainSource, ChainHits} =
                fetch_ek_cert_chain(ChainHandle, Opts),
            persistent_term:put({dev_tpm2, ek_cert_chain_ders},
                                ChainDers),
            persistent_term:put({dev_tpm2, ek_cert_chain_pem},
                                ders_to_pem(ChainDers)),
            persistent_term:put(
                {dev_tpm2, ek_cert_source},
                #{kind => <<"tpm-nv">>,
                  handle => iolist_to_binary(
                      io_lib:format("0x~8.16.0B", [Handle])),
                  bytes => byte_size(Der),
                  chain_handle => iolist_to_binary(
                      io_lib:format("0x~8.16.0B", [ChainHandle])),
                  chain_handles => format_nv_handles(ChainHits),
                  chain_cert_count => length(ChainDers),
                  chain_source => ChainSource}),
            ok;
        {error, Attempts} ->
            persistent_term:put({dev_tpm2, ek_cert_pem}, <<>>),
            persistent_term:put({dev_tpm2, ek_cert_chain_ders}, []),
            persistent_term:put({dev_tpm2, ek_cert_chain_pem}, <<>>),
            persistent_term:put(
                {dev_tpm2, ek_cert_source},
                #{kind => <<"absent">>,
                  reason => <<
                    "no EK certificate provisioned in TPM NV storage; "
                    "attestation proceeds without one so the verifier "
                    "can see the gap">>,
                  probed => format_probe_attempts(Attempts)}),
            ok
    end.

fetch_ek_cert_chain(ChainHandle, Opts) when is_integer(ChainHandle) ->
    Handles =
        case configured_chain_handles(Opts) of
            Hs when is_list(Hs) ->
                Hs;
            undefined ->
                [ChainHandle |
                 lists:seq(
                    ?EK_NV_CHAIN_FIRST,
                    ?EK_NV_CHAIN_FIRST + ?EK_NV_CHAIN_PREFIX_LIMIT - 1)]
        end,
    fetch_ek_cert_chain_handles(Handles);
fetch_ek_cert_chain(ChainHandles, _Opts) when is_list(ChainHandles) ->
    fetch_ek_cert_chain_handles(ChainHandles).

configured_chain_handles(Opts) ->
    case hb_opts:get(<<"lapee-tpm-ek-chain-nv-handles">>, undefined, Opts) of
        undefined -> undefined;
        Handles when is_list(Handles) -> [parse_nv_handle(H) || H <- Handles];
        Other -> [parse_nv_handle(Other)]
    end.

parse_nv_handle(H) when is_integer(H) ->
    H;
parse_nv_handle(<<"0x", Hex/binary>>) ->
    binary_to_integer(Hex, 16);
parse_nv_handle(<<"0X", Hex/binary>>) ->
    binary_to_integer(Hex, 16);
parse_nv_handle(Bin) when is_binary(Bin) ->
    binary_to_integer(Bin);
parse_nv_handle(Other) ->
    parse_nv_handle(hb_util:bin(Other)).

fetch_ek_cert_chain_handles(Handles) ->
    Groups = chain_groups([read_chain_entry(H) || H <- Handles]),
    {Ders, Hits, Attempts} =
        lists:foldl(
            fun collect_chain_group/2,
            {[], [], []},
            Groups),
    Source =
        case Hits of
            [] -> <<"probe-failed: ", (chain_attempts_text(Attempts))/binary>>;
            _ -> chain_hit_source(Hits)
        end,
    {Ders, Source, Hits}.

read_chain_entry(Handle) ->
    case nif_nv_read(Handle) of
        {ok, Bin} when is_binary(Bin), byte_size(Bin) > 0 ->
            {ok, Handle, Bin};
        {ok, _} ->
            {error, Handle, <<"nv-content-empty">>};
        {error, Reason} ->
            {error, Handle, Reason}
    end.

chain_groups(Entries) ->
    chain_groups(Entries, [], []).

chain_groups([], [], Acc) ->
    lists:reverse(Acc);
chain_groups([], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
chain_groups([{ok, _, _} = Entry | Rest], Current, Acc) ->
    chain_groups(Rest, [Entry | Current], Acc);
chain_groups([{error, _, _} = Entry | Rest], [], Acc) ->
    chain_groups(Rest, [], [[Entry] | Acc]);
chain_groups([{error, _, _} = Entry | Rest], Current, Acc) ->
    chain_groups(Rest, [], [[Entry], lists:reverse(Current) | Acc]).

collect_chain_group([{error, Handle, Reason}], {Ders, Hits, Attempts}) ->
    {Ders, Hits, [{Handle, Reason} | Attempts]};
collect_chain_group(Entries, {Ders, Hits, Attempts}) ->
    Bin = iolist_to_binary([Chunk || {ok, _Handle, Chunk} <- Entries]),
    ChainDers = split_concatenated_ders(Bin),
    Handles = [Handle || {ok, Handle, _Chunk} <- Entries],
    case ChainDers of
        [] ->
            {Ders, Hits,
             [{hd(Handles), <<"nv-content-empty-or-non-der">>} | Attempts]};
        _ ->
            {Ders ++ ChainDers, Hits ++ Handles, Attempts}
    end.

chain_hit_source(Hits) ->
    iolist_to_binary(
        [<<"tpm-nv:">>,
         string:join([binary_to_list(format_nv_handle(H)) || H <- Hits],
                     ",")]).

chain_attempts_text([]) ->
    <<"not-probed">>;
chain_attempts_text(Attempts) ->
    iolist_to_binary(
        string:join(
            [binary_to_list(format_nv_handle(H)) ++ "="
             ++ binary_to_list(reason_to_text(Reason))
             || {H, Reason} <- lists:reverse(Attempts)],
            ",")).

format_nv_handles(Handles) ->
    [format_nv_handle(H) || H <- Handles].

format_nv_handle(Handle) ->
    iolist_to_binary(io_lib:format("0x~8.16.0B", [Handle])).

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

split_concatenated_ders(Bin) ->
    split_concatenated_ders(Bin, []).

split_concatenated_ders(<<>>, Acc) ->
    lists:reverse(Acc);
split_concatenated_ders(<<16#30, Rest/binary>> = Full, Acc) ->
    case der_seq_total_len(Rest) of
        {ok, TotalInner, HeaderLen} ->
            CertLen = 1 + HeaderLen + TotalInner,
            case Full of
                <<Cert:CertLen/binary, Tail/binary>> ->
                    case is_x509_der(Cert) of
                        true ->
                            split_concatenated_ders(Tail, [Cert | Acc]);
                        false ->
                            <<_Skip, Tail2/binary>> = Full,
                            split_concatenated_ders(Tail2, Acc)
                    end;
                _ ->
                    lists:reverse(Acc)
            end;
        error ->
            <<_Skip, Tail/binary>> = Full,
            split_concatenated_ders(Tail, Acc)
    end;
split_concatenated_ders(<<_Skip, Tail/binary>>, Acc) ->
    split_concatenated_ders(Tail, Acc).

is_x509_der(Der) ->
    try
        public_key:pkix_decode_cert(Der, otp),
        true
    catch _:_ ->
        false
    end.

der_seq_total_len(<<L:8, _/binary>>) when L =< 16#7F ->
    {ok, L, 1};
der_seq_total_len(<<16#81, L:8, _/binary>>) ->
    {ok, L, 2};
der_seq_total_len(<<16#82, L:16/big, _/binary>>) ->
    {ok, L, 3};
der_seq_total_len(<<16#83, L:24/big, _/binary>>) ->
    {ok, L, 4};
der_seq_total_len(<<16#84, L:32/big, _/binary>>) ->
    {ok, L, 5};
der_seq_total_len(_) ->
    error.

ders_to_pem([]) -> <<>>;
ders_to_pem(Ders) ->
    iolist_to_binary([der_to_pem(D) || D <- Ders]).

try_nv_handles([], Acc) -> {error, lists:reverse(Acc)};
try_nv_handles([H | Rest], Acc) ->
    case nif_nv_read(H) of
        {ok, Der} when is_binary(Der), byte_size(Der) > 0 ->
            case Der of
                <<16#30, _/binary>> ->
                    {ok, H, Der};
                _ ->
                    try_nv_handles(
                        Rest,
                        [{H, <<"nv-content-not-der">>, byte_size(Der)} | Acc])
            end;
        {error, Reason} ->
            try_nv_handles(Rest, [{H, Reason, 0} | Acc])
    end.

nif_nv_read(Handle) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> M:nv_read(Handle)
    end.

format_probe_attempts(Attempts) ->
    [iolist_to_binary(
        io_lib:format("0x~8.16.0B: ~s (~p bytes read)",
                      [H, reason_to_text(R), Sz]))
     || {H, R, Sz} <- Attempts].

reason_to_text(R) when is_atom(R) -> atom_to_binary(R, utf8);
reason_to_text(R) when is_binary(R) -> R;
reason_to_text({tss2_rc, Bin}) when is_binary(Bin) -> Bin;
reason_to_text(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

der_to_pem(Der) when is_binary(Der) ->
    B64 = base64:encode(Der),
    Wrapped = wrap_64(B64),
    iolist_to_binary([
        <<"-----BEGIN CERTIFICATE-----\n">>,
        Wrapped,
        <<"-----END CERTIFICATE-----\n">>]).

wrap_64(<<>>) -> <<>>;
wrap_64(Bin) when byte_size(Bin) =< 64 ->
    <<Bin/binary, "\n">>;
wrap_64(<<Line:64/binary, Rest/binary>>) ->
    <<Line/binary, "\n", (wrap_64(Rest))/binary>>.


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

tpm_identity_accepts_consistent_public_material_test() ->
    ?assertMatch({ok, _}, chk_tpm_public_identity(test_tpm_identity(), #{})).

tpm_identity_rejects_swapped_ek_cert_test() ->
    Env0 = test_tpm_identity(),
    {OtherCertDer, _OtherRsa} = test_cert_and_rsa(),
    Env = Env0#{<<"ek-cert-pem">> => der_to_pem(OtherCertDer)},
    ?assertMatch({error, _}, chk_tpm_public_identity(Env, #{})).

tpm_identity_rejects_recipient_public_material_substitution_test() ->
    Env0 = test_tpm_identity(),
    Recipient0 = maps:get(<<"secret-recipient">>, Env0),
    Material0 = maps:get(<<"public-material">>, Recipient0),
    Env = Env0#{
        <<"secret-recipient">> => Recipient0#{
            <<"public-material">> => Material0#{
                <<"ek-public">> => maps:get(<<"ak-public">>, Env0)
            }
        }
    },
    ?assertMatch({error, _}, chk_tpm_public_identity(Env, #{})).

tpm_identity_rejects_recipient_top_level_substitution_test() ->
    Env0 = test_tpm_identity(),
    Recipient0 = maps:get(<<"secret-recipient">>, Env0),
    Env = Env0#{
        <<"secret-recipient">> => Recipient0#{
            <<"ek-public">> => maps:get(<<"ak-public">>, Env0)
        }
    },
    ?assertMatch({error, _}, chk_tpm_public_identity(Env, #{})).

tpm_identity_rejects_recipient_top_level_ak_name_substitution_test() ->
    Env0 = test_tpm_identity(),
    Recipient0 = maps:get(<<"secret-recipient">>, Env0),
    Env = Env0#{
        <<"secret-recipient">> => Recipient0#{
            <<"ak-name">> => maps:get(<<"ek-name">>, Env0)
        }
    },
    ?assertMatch({error, _}, chk_tpm_public_identity(Env, #{})).

tpm_identity_accepts_raw_evidence_without_recipient_test() ->
    Env0 = test_tpm_identity(),
    ?assertMatch(
        {ok, _},
        chk_tpm_public_identity(maps:remove(<<"secret-recipient">>, Env0), #{})).

tpm_public_name_recomputes_from_public_area_test() ->
    {_CertDer, Rsa} = test_cert_and_rsa(),
    Public = test_tpm2b_public(Rsa),
    {ok, <<16#000B:16/unsigned-big, Digest/binary>>} = tpm_public_name(Public),
    {ok, PublicBody} = tpm2b_public_body(Public),
    ?assertEqual(crypto:hash(sha256, PublicBody), Digest).

test_tpm_identity() ->
    {EkCertDer, EkRsa} = test_cert_and_rsa(),
    {_AkCertDer, AkRsa} = test_cert_and_rsa(),
    EkPublic = test_tpm2b_public(EkRsa),
    AkPublic = test_tpm2b_public(AkRsa),
    {ok, EkName} = tpm_public_name(EkPublic),
    {ok, AkName} = tpm_public_name(AkPublic),
    Env0 = #{
        <<"ek-cert-pem">> => der_to_pem(EkCertDer),
        <<"ek-pub-pem">> => test_rsa_pem(EkRsa),
        <<"ek-public">> => hb_util:encode(EkPublic),
        <<"ek-name">> => hb_util:encode(EkName),
        <<"ek-qualified-name">> => hb_util:encode(EkName),
        <<"ak-pub-pem">> => test_rsa_pem(AkRsa),
        <<"ak-public">> => hb_util:encode(AkPublic),
        <<"ak-name">> => hb_util:encode(AkName),
        <<"ak-qualified-name">> => hb_util:encode(AkName)
    },
    Env0#{<<"secret-recipient">> => test_tpm_recipient(Env0)}.

test_tpm_recipient(Env) ->
    maps:merge(
        #{
            <<"type">> => <<"lapee-tpm-credential-subject">>,
            <<"version">> => <<"1.0">>,
            <<"measurement-device">> => <<"tpm@2.0a">>,
            <<"method">> => <<"tpm2-activate-credential">>,
            <<"key-id">> => maps:get(<<"ak-name">>, Env),
            <<"binding">> => #{
                <<"kind">> => <<"ak-policy-pcr">>,
                <<"pcr">> => ?NODE_IDENTITY_PCR,
                <<"policy-pcrs">> => ?AK_POLICY_PCRS
            },
            <<"public-material">> => maps:with(
                [<<"ek-public">>, <<"ek-pub-pem">>,
                 <<"ak-public">>, <<"ak-pub-pem">>, <<"ak-name">>],
                Env)
        },
        maps:with(
            [<<"ek-pub-pem">>, <<"ek-public">>, <<"ek-name">>,
             <<"ek-qualified-name">>, <<"ak-pub-pem">>, <<"ak-public">>,
             <<"ak-name">>, <<"ak-qualified-name">>],
            Env)).

test_cert_and_rsa() ->
    [{cert, Der} | _] =
        public_key:pkix_test_data(#{
            root => [{key, {rsa, 512, 65537}}],
            peer => [{key, {rsa, 512, 65537}}]
        }),
    {ok, Rsa} = cert_rsa_public_key(Der),
    {Der, Rsa}.

test_rsa_pem(Rsa) ->
    public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', Rsa)]).

test_tpm2b_public(#'RSAPublicKey'{modulus = N, publicExponent = E}) ->
    Modulus = binary:encode_unsigned(N),
    Exponent =
        case E of
            65537 -> 0;
            _ -> E
        end,
    Public = <<
        16#0001:16/unsigned-big,
        16#000B:16/unsigned-big,
        0:32/unsigned-big,
        0:16/unsigned-big,
        16#0010:16/unsigned-big,
        16#0010:16/unsigned-big,
        (byte_size(Modulus) * 8):16/unsigned-big,
        Exponent:32/unsigned-big,
        (byte_size(Modulus)):16/unsigned-big,
        Modulus/binary
    >>,
    <<(byte_size(Public)):16/unsigned-big, Public/binary>>.

-endif.


nif_module() ->
    case code:is_loaded(lapee_tpm_nif) of
        {file, _} -> lapee_tpm_nif;
        false ->
            case load_priv_module(lapee_tpm_nif) of
                lapee_tpm_nif ->
                    lapee_tpm_nif;
                _ ->
                    case code:ensure_loaded(lapee_tpm_nif) of
                        {module, _} -> lapee_tpm_nif;
                        _ -> not_loaded
                    end
            end
    end.

load_priv_module(Module) ->
    try
        PrivDir = hb_device_archive:implementation_dir(?MODULE),
        os:putenv("LAPEE_TPM_NIF_DIR", PrivDir),
        Path = filename:join(PrivDir, atom_to_list(Module)),
        case code:load_abs(Path) of
            {module, Module} -> Module;
            _ -> not_loaded
        end
    catch _:_ ->
        not_loaded
    end.

nif_startup() ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:startup()
    end.

nif_pcr_extend(Pcr, Digest) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:pcr_extend(Pcr, Digest)
    end.

nif_create_ek() ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:create_primary_ek()
    end.

nif_create_signing_key() ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:create_signing_key()
    end.

nif_activate_credential(AKTr, EKTr, CredentialBlob, Secret) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:activate_credential(AKTr, EKTr, CredentialBlob, Secret)
    end.

nif_quote(AKTr, Pcrs, Nonce) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:quote(AKTr, Pcrs, Nonce)
    end.
