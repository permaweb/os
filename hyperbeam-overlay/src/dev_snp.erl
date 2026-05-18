%%% @doc LapEE AMD SEV-SNP measurement engine.
%%%
%%% This device implements the `~measurement@1.0' engine protocol for
%%% SEV-SNP guests. The native boundary is intentionally small: the NIF only
%%% asks `/dev/sev-guest' for raw report material. Message construction,
%%% report-data binding, policy-neutral checks, endorsement handling, and
%%% secret wrapping live in Erlang.
%%%
%%% SNP has no TPM-style ActivateCredential primitive. The equivalent LapEE
%%% construction is to generate a boot-local X25519 recipient key inside the
%%% measured guest, bind that public key into SNP `report_data', and let peers
%%% encrypt admission material to it.
-module(dev_snp).
-export([info/1, info/3, supported/3, subject/3, measure/3, verify/3,
         wrap_secret/3, unwrap_secret/3]).
-export([wrap_secret_for_subject/3, unwrap_secret_value/2,
         ensure_secret_activation/5]).

-include("include/hb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(VERSION, <<"1.0">>).
-define(REPORT_CONTEXT, <<"lapee-measurement-v1">>).
-define(METHOD, <<"snp-report-data-x25519-hkdf-sha256-aes-256-gcm">>).

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
            <<"description">> =>
                <<"AMD SEV-SNP measurement engine for ~measurement@1.0">>,
            <<"version">> => ?VERSION,
            <<"supported">> => snp_supported(Opts)
        }
    }}.

supported(_Base, _Req, Opts) ->
    {ok, snp_supported(Opts)}.

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
        ReportData = report_data(Body, Nonce, Recipient, Opts),
        case dev_snp_nif:report(ReportData, vmpl(Opts)) of
            {ok, ReportRaw, Certs} ->
                Report = decode_report(ReportRaw),
                {ok, #{
                    <<"status">> => 200,
                    <<"body">> => evidence(ReportRaw, Certs, Report, Nonce,
                                             ReportData, Recipient, Opts)
                }};
            {error, Reason} ->
                error_resp(500, <<"snp-report-failed">>, Reason)
        end
    catch
        Class:CatchReason ->
            error_resp(500, <<"snp-measure-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(CatchReason)})
    end.

verify(Base, Req, Opts) ->
    Measurement = response_body(resolve_envelope(Base, Req, Opts), Opts),
    Evidence = hb_maps:get(<<"evidence">>, Measurement, #{}, Opts),
    Body = hb_maps:get(<<"body">>, Measurement, #{}, Opts),
    Recipient = hb_maps:get(<<"secret-recipient">>, Measurement, #{}, Opts),
    Checks = [
        check_report_data(Body, Recipient, Evidence, Req, Opts),
        check_report_signature(Body, Evidence, Opts)
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
            <<"checks">> => Checks
        }
    }}.

wrap_secret(_Base, Req, Opts) ->
    Subject = hb_maps:get(<<"subject">>, Req, undefined, Opts),
    Secret = decode_secret(hb_maps:get(<<"secret">>, Req, <<>>, Opts)),
    {ok, #{
        <<"status">> => 200,
        <<"body">> => wrap_secret_for_subject(Subject, Secret, Opts)
    }}.

unwrap_secret(_Base, Req, Opts) ->
    try
        Credential = activation_credential(Req, Opts),
        {ok, Secret} = unwrap_secret_value(Credential, Opts),
        Msg = hb_message:commit(
            secret_activation_public_body(Secret, Credential),
            Opts),
        {ok, #{<<"status">> => 200, <<"body">> => Msg}}
    catch
        Class:CatchReason ->
            error_resp(500, <<"snp-unwrap-secret-failed">>,
                       #{<<"class">> => hb_util:bin(Class),
                         <<"reason">> => reason_to_text(CatchReason)})
    end.

snp_supported(_Opts) ->
    try dev_snp_nif:supported() of
        {ok, true} -> true;
        _ -> false
    catch _:_ ->
        false
    end.

secret_recipient(Body, Opts) ->
    {Public, _Private} = recipient_keypair(),
    BodyID = body_id(Body, Opts),
    Context = device_context(Opts),
    #{
        <<"type">> => <<"lapee-secret-recipient">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
        <<"method">> => ?METHOD,
        <<"key-id">> => hb_util:encode(crypto:hash(sha256, Public)),
        <<"public-material">> => #{
            <<"x25519-public-key">> => hb_util:encode(Public)
        },
        <<"binding">> => #{
            <<"report-data-context">> => ?REPORT_CONTEXT,
            <<"body-id">> => BodyID,
            <<"device-context">> => Context,
            <<"device-context-digest">> => device_context_digest(Context)
        }
    }.

recipient_keypair() ->
    case persistent_term:get({dev_snp, x25519_keypair}, undefined) of
        {Public, Private} ->
            {Public, Private};
        undefined ->
            {Public, Private} = crypto:generate_key(ecdh, x25519),
            persistent_term:put({dev_snp, x25519_keypair}, {Public, Private}),
            {Public, Private}
    end.

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
    Info = <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>,
    Key = hkdf_sha256(Shared, Salt, Info, 32),
    AAD = secret_aad(SubjectID),
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(
            aes_256_gcm, Key, IV, Secret, AAD, 16, true),
    #{
        <<"type">> => <<"lapee-wrapped-secret">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
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
    Info = <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>,
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
            secret_activation_context(Credential, IssuedAt))),
    case {GotHash, Proof} of
        {ExpectedHash, ExpectedProof} -> ok;
        _ ->
            throw({snp_error,
                   #{<<"secret-activation">> =>
                        <<"activation proof did not match challenge">>}})
    end.

evidence(ReportRaw, Certs, Report, Nonce, ReportData, Recipient, Opts) ->
    #{
        <<"type">> => <<"lapee-snp-evidence">>,
        <<"version">> => ?VERSION,
        <<"nonce">> => hb_util:encode(Nonce),
        <<"report-data">> => hb_util:encode(ReportData),
        <<"report-raw">> => hb_util:encode(ReportRaw),
        <<"report">> => parsed_report_summary(Report),
        <<"certificates">> => certificates(Certs),
        <<"secret-recipient-id">> => stable_id(Recipient, Opts),
        <<"device-context">> => device_context(Opts)
    }.

certificates(Certs) when is_list(Certs) ->
    [certificate_entry(Guid, Data) || {Guid, Data} <- Certs];
certificates(_) ->
    [].

certificate_entry(Guid, Data) ->
    #{
        <<"type">> => certificate_type(Guid),
        <<"guid">> => Guid,
        <<"data">> => hb_util:encode(Data)
    }.

certificate_type(<<"c0b406a4-a803-4952-9743-3fb6014cd0ae">>) -> <<"ark">>;
certificate_type(<<"4ab7b379-bbac-4fe4-a02f-05aef327c782">>) -> <<"ask">>;
certificate_type(<<"63da758d-e664-4564-adc5-f4b93be8accd">>) -> <<"vcek">>;
certificate_type(<<"a8074bc2-a25a-483e-aae6-39c045a0b8a1">>) -> <<"vlek">>;
certificate_type(<<"92f81bc3-5811-4d3d-97ff-d19f88dc67ea">>) -> <<"crl">>;
certificate_type(_) -> <<"other">>.

parsed_report_summary(Report) ->
    #{
        <<"version">> => report_get(<<"version">>, Report, null),
        <<"guest-svn">> => report_get(<<"guest-svn">>, Report, null),
        <<"policy">> => report_get(<<"policy">>, Report, null),
        <<"family-id">> => encode_array_field(<<"family-id">>, Report),
        <<"image-id">> => encode_array_field(<<"image-id">>, Report),
        <<"vmpl">> => report_get(<<"vmpl">>, Report, null),
        <<"signature-algorithm">> =>
            report_get(<<"signature-algorithm">>, Report, null),
        <<"platform-info">> => report_get(<<"platform-info">>, Report, null),
        <<"measurement">> => encode_array_field(<<"measurement">>, Report),
        <<"reported-tcb">> =>
            report_get(<<"reported-tcb">>, Report, null),
        <<"committed-tcb">> =>
            report_get(<<"committed-tcb">>, Report, null),
        <<"launch-tcb">> =>
            report_get(<<"launch-tcb">>, Report, null),
        <<"chip-id">> => encode_array_field(<<"chip-id">>, Report),
        <<"report-id">> => encode_array_field(<<"report-id">>, Report),
        <<"report-id-ma">> => encode_array_field(<<"report-id-ma">>, Report)
    }.

check_report_data(Body, Recipient, Evidence, Req, Opts) ->
    safely_check(
        <<"SNP report_data binds body, nonce, and secret recipient">>,
        <<"core">>,
        fun() ->
            Nonce = decode_required(<<"nonce">>, Evidence, Opts),
            case expected_nonce(Req) of
                undefined -> ok;
                Nonce -> ok;
                _ -> throw(<<"fresh nonce does not match verifier challenge">>)
            end,
            Expected = report_data(Body, Nonce, Recipient, Opts),
            Got = decode_required(<<"report-data">>, Evidence, Opts),
            Report = evidence_report(Evidence, Opts),
            ReportData = array_binary(
                report_get(<<"report-data">>, Report, <<>>)),
            case {Got, ReportData} of
                {Expected, Expected} -> ok;
                _ -> throw(<<"report_data mismatch">>)
            end
        end).

check_report_signature(Body, Evidence, Opts) ->
    safely_check(
        <<"SNP report signature and endorsement chain verify">>,
        <<"core">>,
        fun() ->
            assert_report_signature(Body, Evidence, Opts)
        end).

assert_report_signature(_Body, Evidence, Opts) ->
    case allow_test_signature(Evidence, Opts) of
        true ->
            ok;
        false ->
            Raw = decode_required(<<"report-raw">>, Evidence, Opts),
            Report = decode_report(Raw),
            assert_signature_algorithm(Report),
            Certs = resolved_certificates(Report, _Body, Evidence, Opts),
            assert_certificate_chain(Certs),
            Signed = binary:part(Raw, 0, 672),
            Signature = ecdsa_signature_der(report_get(<<"signature">>, Report, #{})),
            case public_key:verify(
                Signed, sha384, Signature, cert_public_key(maps:get(vcek, Certs))) of
                true -> ok;
                false -> throw(<<"SNP report signature rejected">>)
            end
    end.

allow_test_signature(Evidence, Opts) ->
    hb_opts:get(<<"allow-test-snp-signature">>, false, Opts) =:= true
        andalso
        hb_maps:get(<<"signature-check">>, Evidence, #{}, Opts)
            =:= #{<<"verified">> => true, <<"source">> => <<"test">>}.

assert_signature_algorithm(Report) ->
    case report_get(<<"signature-algorithm">>, Report, undefined) of
        1 -> ok;
        Other ->
            throw(#{<<"unsupported-signature-algorithm">> => Other})
    end.

resolved_certificates(Report, Body, Evidence, Opts) ->
    Embedded = evidence_certificates(Evidence, Opts),
    Product = snp_product(Body, Opts),
    {Ask, Ark, ChainSource} =
        case {maps:get(ask, Embedded, undefined),
              maps:get(ark, Embedded, undefined)} of
            {Ask0, Ark0} when is_binary(Ask0), is_binary(Ark0) ->
                {Ask0, Ark0, <<"platform-certificate-table">>};
            _ ->
                {Ask1, Ark1} = fetch_amd_cert_chain(Product),
                {Ask1, Ark1, <<"amd-kds">>}
        end,
    VCEK =
        case maps:get(vcek, Embedded, undefined) of
            VCEK0 when is_binary(VCEK0) -> VCEK0;
            _ -> fetch_vcek(Product, Report)
        end,
    #{ask => Ask, ark => Ark, vcek => VCEK, source => ChainSource}.

evidence_certificates(Evidence, Opts) ->
    Certs = hb_maps:get(<<"certificates">>, Evidence, [], Opts),
    maps:from_list(
        [
            {binary_to_atom(Type, utf8), decode_required(<<"data">>, Cert, Opts)}
         || Cert <- Certs,
            is_map(Cert),
            Type <- [hb_maps:get(<<"type">>, Cert, undefined, Opts)],
            lists:member(Type, [<<"ark">>, <<"ask">>, <<"vcek">>])
        ]).

fetch_amd_cert_chain(Product) ->
    URL = <<"https://kdsintf.amd.com/vcek/v1/", Product/binary,
            "/cert_chain">>,
    PEM = http_get(URL),
    Certs = [Der || {'Certificate', Der, _} <- public_key:pem_decode(PEM)],
    case Certs of
        [Ask, Ark] -> {Ask, Ark};
        _ -> throw(#{<<"amd-kds-cert-chain">> => <<"unexpected certificate chain">>})
    end.

fetch_vcek(Product, Report) ->
    TCB = report_get(<<"reported-tcb">>, Report, #{}),
    URL = iolist_to_binary([
        <<"https://kdsintf.amd.com/vcek/v1/">>,
        Product,
        <<"/">>,
        hex_lower(report_get(<<"chip-id">>, Report, <<>>)),
        <<"?blSPL=">>, decimal_param(hb_maps:get(<<"bootloader">>, TCB, 0, #{})),
        <<"&teeSPL=">>, decimal_param(hb_maps:get(<<"tee">>, TCB, 0, #{})),
        <<"&snpSPL=">>, decimal_param(hb_maps:get(<<"snp">>, TCB, 0, #{})),
        <<"&ucodeSPL=">>, decimal_param(hb_maps:get(<<"microcode">>, TCB, 0, #{}))
    ]),
    http_get(URL).

http_get(URL) ->
    case persistent_term:get({dev_snp, http_get, URL}, undefined) of
        Body when is_binary(Body) ->
            Body;
        undefined ->
            Body = http_get_uncached(URL),
            persistent_term:put({dev_snp, http_get, URL}, Body),
            Body
    end.

http_get_uncached(URL) ->
    application:ensure_all_started(ssl),
    application:ensure_all_started(inets),
    case httpc:request(
        get,
        {binary_to_list(URL), []},
        [{timeout, 15000}],
        [{body_format, binary}]) of
        {ok, {{_, Code, _}, _Headers, Body}} when Code >= 200, Code < 300 ->
            Body;
        {ok, {{_, Code, _}, _Headers, Body}} ->
            throw(#{<<"http-status">> => Code, <<"url">> => URL,
                    <<"body">> => Body});
        {error, Reason} ->
            throw(#{<<"http-error">> => reason_to_text(Reason),
                    <<"url">> => URL})
    end.

assert_certificate_chain(#{ark := Ark, ask := Ask, vcek := VCEK}) ->
    assert_amd_ark(Ark),
    case public_key:pkix_path_validation(Ark, [Ask, VCEK], []) of
        {ok, _} -> ok;
        {error, Reason} ->
            throw(#{<<"snp-certificate-chain">> => reason_to_text(Reason)})
    end.

assert_amd_ark(Ark) ->
    Hash = hb_util:encode(crypto:hash(sha256, Ark)),
    case lists:member(Hash, amd_ark_fingerprints()) of
        true -> ok;
        false ->
            throw(#{<<"unknown-amd-ark">> => Hash})
    end.

amd_ark_fingerprints() ->
    [
        <<"adBjtFNE0moulOH0IQ3knvVVMIKH1MF0RFyVY5pUC80">>,
        <<"TGWY0ZwYcZxd_Up9M19nTlv-HY-ADOos8nDBDRA9svE">>,
        <<"HwhBYaRLttk3eKkEh31IGcr6XQXvQZOy3tndnHPdP2o">>
    ].

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

ecdsa_signature_der(#{<<"r">> := R, <<"s">> := S}) ->
    public_key:der_encode(
        'ECDSA-Sig-Value',
        #'ECDSA-Sig-Value'{r = snp_signature_integer(R),
                           s = snp_signature_integer(S)}).

snp_signature_integer(Padded) when is_binary(Padded), byte_size(Padded) >= 48 ->
    binary:decode_unsigned(reverse_binary(binary:part(Padded, 0, 48)));
snp_signature_integer(_) ->
    throw(<<"invalid SNP ECDSA signature component">>).

reverse_binary(Bin) ->
    list_to_binary(lists:reverse(binary_to_list(Bin))).

snp_product(Body, Opts) ->
    case hb_opts:get(<<"snp-product">>, undefined, Opts) of
        Product when is_binary(Product), byte_size(Product) > 0 ->
            Product;
        _ ->
            System = hb_maps:get(<<"system">>, Body, #{}, Opts),
            CPU = hb_maps:get(<<"cpu">>, System, #{}, Opts),
            CPUInfo = hb_maps:get(<<"cpuinfo">>, CPU, #{}, Opts),
            Family = parse_integer(
                hb_maps:get(<<"cpu-family">>, CPUInfo, undefined, Opts),
                undefined),
            Model = parse_integer(
                hb_maps:get(<<"model">>, CPUInfo, undefined, Opts),
                undefined),
            snp_product_from_fms(Family, Model)
    end.

snp_product_from_fms(25, Model) when is_integer(Model), Model < 16 ->
    <<"Milan">>;
snp_product_from_fms(25, _Model) ->
    <<"Genoa">>;
snp_product_from_fms(26, _Model) ->
    <<"Turin">>;
snp_product_from_fms(_, _) ->
    <<"Genoa">>.

hex_lower(Bin) ->
    << <<(hex_digit(N bsr 4)), (hex_digit(N band 15))>> || <<N:8>> <= Bin >>.

hex_digit(N) when N < 10 -> $0 + N;
hex_digit(N) -> $a + (N - 10).

decimal_param(N) when is_integer(N) ->
    integer_to_binary(N);
decimal_param(B) when is_binary(B) ->
    B;
decimal_param(_) ->
    <<"0">>.

report_data(Body, Nonce, Recipient, Opts) ->
    BodyID = body_id(Body, Opts),
    RecipientID = stable_id(Recipient, Opts),
    ContextDigest = device_context_digest(device_context(Opts)),
    crypto:hash(
        sha512,
        <<?REPORT_CONTEXT/binary,
          (hb_util:native_id(BodyID))/binary,
          Nonce/binary,
          (hb_util:native_id(RecipientID))/binary,
          (hb_util:decode(ContextDigest))/binary>>).

body_id(Body, Opts) when is_map(Body) ->
    stable_id(Body, Opts);
body_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

device_context(Opts) ->
    #{
        <<"vmpl">> => vmpl(Opts),
        <<"report-data-context">> => ?REPORT_CONTEXT,
        <<"secret-method">> => ?METHOD
    }.

device_context_digest(Context) ->
    stable_id(Context, #{}).

vmpl(Opts) ->
    parse_integer(
        first_defined([
            hb_opts:get(<<"snp-vmpl">>, undefined, Opts),
            hb_opts:get(snp_vmpl, undefined, Opts)
        ]),
        0).

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

secret_activation_public_body(Secret, Credential) ->
    Now = erlang:system_time(second),
    #{
        <<"type">> => <<"lapee-secret-activation">>,
        <<"version">> => ?VERSION,
        <<"measurement-device">> => <<"snp@1.0">>,
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
                    secret_activation_context(Credential, Now)))
    }.

secret_activation_context(Credential, IssuedAt) ->
    <<"lapee-secret-activation-v1\n",
      "measurement-device:snp@1.0\n",
      "method:", ?METHOD/binary, "\n",
      "issued-at-unix:", (integer_to_binary(IssuedAt))/binary, "\n",
      "credential-id:", (stable_id(Credential, #{}))/binary>>.

activation_credential(Req, Opts) when is_map(Req) ->
    first_defined([
        hb_maps:get(<<"credential">>, Req, undefined, Opts),
        hb_maps:get(<<"wrapped-secret">>, Req, undefined, Opts),
        Req
    ]);
activation_credential(Req, _Opts) ->
    Req.

secret_aad(SubjectID) ->
    <<"lapee-snp-wrap-secret-v1:", SubjectID/binary>>.

hkdf_sha256(IKM, Salt, Info, Length) ->
    PRK = crypto:mac(hmac, sha256, Salt, IKM),
    hkdf_expand(PRK, Info, Length, <<>>, <<>>, 1).

hkdf_expand(_PRK, _Info, Length, Acc, _Prev, _N)
        when byte_size(Acc) >= Length ->
    binary:part(Acc, 0, Length);
hkdf_expand(PRK, Info, Length, Acc, Prev, N) ->
    Block = crypto:mac(hmac, sha256, PRK, <<Prev/binary, Info/binary, N>>),
    hkdf_expand(PRK, Info, Length, <<Acc/binary, Block/binary>>, Block, N + 1).

evidence_report(Evidence, Opts) ->
    case hb_maps:get(<<"report-raw">>, Evidence, undefined, Opts) of
        Raw when is_binary(Raw), byte_size(Raw) > 0 ->
            decode_report(decode_secret(Raw));
        _ ->
            decode_report(hb_maps:get(<<"report-json">>, Evidence, <<>>, Opts))
    end.

decode_report(Raw) when is_binary(Raw), byte_size(Raw) =:= 1184 ->
    parse_raw_report(Raw);
decode_report(ReportJSON) when is_binary(ReportJSON) ->
    hb_json:decode(ReportJSON);
decode_report(Report) when is_map(Report) ->
    Report.

parse_raw_report(
    <<Version:32/little, GuestSVN:32/little, Policy:64/little,
      FamilyID:16/binary, ImageID:16/binary, VMPL:32/little,
      SigAlgo:32/little, CurrentTCB:8/binary, PlatformInfo:64/little,
      AuthorKeyEn:32/little, _Reserved0:32/little,
      ReportData:64/binary, Measurement:48/binary, HostData:32/binary,
      IDKeyDigest:48/binary, AuthorKeyDigest:48/binary,
      ReportID:32/binary, ReportIDMA:32/binary, ReportedTCB:8/binary,
      _Reserved1:24/binary, ChipID:64/binary, CommittedTCB:8/binary,
      CurrentBuild:8, CurrentMinor:8, CurrentMajor:8, _Reserved2:8,
      CommittedBuild:8, CommittedMinor:8, CommittedMajor:8, _Reserved3:8,
      LaunchTCB:8/binary, _Reserved4:168/binary,
      SigR:72/binary, SigS:72/binary, SigReserved:368/binary>>) ->
    #{
        <<"version">> => Version,
        <<"guest-svn">> => GuestSVN,
        <<"policy">> => Policy,
        <<"family-id">> => FamilyID,
        <<"image-id">> => ImageID,
        <<"vmpl">> => VMPL,
        <<"signature-algorithm">> => SigAlgo,
        <<"current-tcb">> => parse_tcb(CurrentTCB),
        <<"platform-info">> => PlatformInfo,
        <<"author-key-enabled">> => AuthorKeyEn =:= 1,
        <<"report-data">> => ReportData,
        <<"measurement">> => Measurement,
        <<"host-data">> => HostData,
        <<"id-key-digest">> => IDKeyDigest,
        <<"author-key-digest">> => AuthorKeyDigest,
        <<"report-id">> => ReportID,
        <<"report-id-ma">> => ReportIDMA,
        <<"reported-tcb">> => parse_tcb(ReportedTCB),
        <<"chip-id">> => ChipID,
        <<"committed-tcb">> => parse_tcb(CommittedTCB),
        <<"current-version">> => #{
            <<"major">> => CurrentMajor,
            <<"minor">> => CurrentMinor,
            <<"build">> => CurrentBuild
        },
        <<"committed-version">> => #{
            <<"major">> => CommittedMajor,
            <<"minor">> => CommittedMinor,
            <<"build">> => CommittedBuild
        },
        <<"launch-tcb">> => parse_tcb(LaunchTCB),
        <<"signature">> => #{
            <<"r">> => SigR,
            <<"s">> => SigS,
            <<"reserved">> => SigReserved
        }
    }.

parse_tcb(
    <<Bootloader:8, Tee:8, _Reserved:4/binary, SNP:8, Microcode:8>>) ->
    #{
        <<"bootloader">> => Bootloader,
        <<"tee">> => Tee,
        <<"snp">> => SNP,
        <<"microcode">> => Microcode
    }.

encode_array_field(Key, Report) ->
    hb_util:encode(array_binary(report_get(Key, Report, <<>>))).

report_get(Key, Report, Default) ->
    case hb_maps:get(Key, Report, undefined, #{}) of
        undefined -> hb_maps:get(underscore_key(Key), Report, Default, #{});
        Value -> Value
    end.

underscore_key(Key) ->
    binary:replace(Key, <<"-">>, <<"_">>, [global]).

array_binary(L) when is_list(L) ->
    iolist_to_binary([<<N:8>> || N <- L, is_integer(N), N >= 0, N =< 255]);
array_binary(B) when is_binary(B) ->
    B;
array_binary(_) ->
    <<>>.

decode_required(Key, Msg, Opts) ->
    case hb_maps:get(Key, Msg, undefined, Opts) of
        B when is_binary(B), byte_size(B) > 0 ->
            try hb_util:decode(B)
            catch _:_ -> B
            end;
        _ ->
            throw(<<Key/binary, " missing">>)
    end.

decode_secret(B) when is_binary(B) ->
    try hb_util:decode(B)
    catch _:_ -> B
    end;
decode_secret(_) ->
    throw(<<"secret must be binary/base64url">>).

stable_id(Msg, Opts) when is_map(Msg) ->
    hb_message:id(
        hb_message:uncommitted_deep(canonical_payload(Msg, Opts), Opts),
        uncommitted,
        Opts);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 32 ->
    hb_util:human_id(Bin);
stable_id(Bin, _Opts) when is_binary(Bin), byte_size(Bin) =:= 43 ->
    Bin;
stable_id(Bin, _Opts) when is_binary(Bin) ->
    hb_util:encode(hb_crypto:sha256(Bin));
stable_id(Value, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Value))).

canonical_payload(Link, Opts) when ?IS_LINK(Link) ->
    canonical_payload(response_body(Link, Opts), Opts);
canonical_payload(Msg, Opts) when is_map(Msg) ->
    Loaded = hb_cache:ensure_all_loaded(hb_link:decode_all_links(Msg), Opts),
    maps:from_list(
        [
            {Key, canonical_payload(Value, Opts)}
         || {Key, Value} <- hb_maps:to_list(Loaded, Opts),
            Key =/= <<"commitments">>,
            Key =/= <<"ao-types">>
        ]);
canonical_payload(List, Opts) when is_list(List) ->
    [canonical_payload(Value, Opts) || Value <- List];
canonical_payload(Value, _Opts) when is_atom(Value) ->
    hb_util:bin(Value);
canonical_payload(Value, _Opts) ->
    Value.

response_body(Link, Opts) when ?IS_LINK(Link) ->
    response_body(hb_cache:ensure_loaded(Link, Opts), Opts);
response_body({ok, Msg}, Opts) ->
    response_body(Msg, Opts);
response_body({error, Reason}, _Opts) ->
    throw(Reason);
response_body(#{<<"status">> := _Status, <<"body">> := Body}, Opts) ->
    response_body(Body, Opts);
response_body(#{<<"body">> := Body} = Msg, Opts) ->
    case hb_maps:get(<<"type">>, Msg, undefined, Opts) of
        <<"lapee-measurement">> -> Msg;
        _ -> response_body(Body, Opts)
    end;
response_body(Body, _Opts) ->
    Body.

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

safely_check(Name, Severity, Fun) ->
    try Fun() of
        ok ->
            #{<<"name">> => Name,
              <<"ok">> => true,
              <<"detail">> => <<"ok">>,
              <<"severity">> => Severity}
    catch
        _:Reason ->
            #{<<"name">> => Name,
              <<"ok">> => false,
              <<"detail">> => reason_to_text(Reason),
              <<"severity">> => Severity}
    end.

parse_integer(N, _Default) when is_integer(N) -> N;
parse_integer(B, Default) when is_binary(B) ->
    try binary_to_integer(B)
    catch _:_ -> Default
    end;
parse_integer(_, Default) ->
    Default.

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
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

hkdf_roundtrip_test() ->
    Subject = secret_recipient(#{}, #{}),
    Secret = crypto:strong_rand_bytes(32),
    Credential = wrap_secret_for_subject(Subject, Secret, #{}),
    {ok, Secret} = unwrap_secret_value(Credential, #{}).

stable_id_uses_ao_core_binary_rules_test() ->
    NativeID = crypto:strong_rand_bytes(32),
    HumanID = hb_util:human_id(NativeID),
    ?assertEqual(HumanID, stable_id(NativeID, #{})),
    ?assertEqual(HumanID, stable_id(HumanID, #{})),
    ?assertEqual(
        hb_util:encode(hb_crypto:sha256(<<"plain challenge">>)),
        stable_id(<<"plain challenge">>, #{})).

snp_body_id_is_atom_transport_stable_test() ->
    Native = #{
        <<"system">> => #{
            <<"drivers">> => [dev_tpm2, dev_snp],
            <<"available">> => true
        },
        <<"node">> => #{<<"initialized">> => permanent}
    },
    Wire = #{
        <<"system">> => #{
            <<"drivers">> => [<<"dev_tpm2">>, <<"dev_snp">>],
            <<"available">> => <<"true">>
        },
        <<"node">> => #{<<"initialized">> => <<"permanent">>}
    },
    ?assertEqual(body_id(Native, #{}), body_id(Wire, #{})).

snp_secret_activation_uses_explicit_credential_request_test() ->
    Subject = secret_recipient(#{}, #{}),
    Secret = crypto:strong_rand_bytes(32),
    Credential = wrap_secret_for_subject(Subject, Secret, #{}),
    Req = #{
        <<"credential">> => Credential,
        <<"accept">> => <<"application/json">>,
        <<"accept-bundle">> => <<"true">>
    },
    Credential = activation_credential(Req, #{}),
    {ok, Secret} = unwrap_secret_value(Credential, #{}),
    Activation = secret_activation_public_body(Secret, Credential),
    ok = ensure_secret_activation(Activation, Credential, Secret, Subject, #{}).

snp_verify_accepts_bound_report_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Measurement = test_measurement(Body, Recipient, Nonce, #{}),
    ?assertMatch(
        {ok, #{<<"status">> := 200,
               <<"body">> := #{<<"verified">> := true}}},
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(Nonce)},
            #{<<"allow-test-snp-signature">> => true})).

snp_verify_rejects_wrong_nonce_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Measurement =
        test_measurement(Body, Recipient, crypto:strong_rand_bytes(32), #{}),
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(crypto:strong_rand_bytes(32))},
            #{<<"allow-test-snp-signature">> => true}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_wrong_body_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Measurement =
        (test_measurement(Body, Recipient, Nonce, #{}))#{
            <<"body">> => #{<<"system">> => #{<<"tampered">> => true}}
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> => Measurement,
              <<"nonce">> => hb_util:encode(Nonce)},
            #{<<"allow-test-snp-signature">> => true}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_bad_signature_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Evidence =
        (test_evidence(Body, Recipient, Nonce, #{}))#{
            <<"signature-check">> => #{<<"verified">> => false}
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> =>
                #{<<"type">> => <<"lapee-measurement">>,
                  <<"body">> => Body,
                  <<"evidence">> => Evidence,
                  <<"secret-recipient">> => Recipient},
              <<"nonce">> => hb_util:encode(Nonce)},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

snp_verify_rejects_malformed_report_test() ->
    Body = test_body(),
    Recipient = secret_recipient(Body, #{}),
    Nonce = crypto:strong_rand_bytes(32),
    Evidence =
        (test_evidence(Body, Recipient, Nonce, #{}))#{
            <<"report-json">> => <<"not-json">>
        },
    {ok, #{<<"body">> := Result}} =
        verify(
            #{},
            #{<<"envelope">> =>
                #{<<"type">> => <<"lapee-measurement">>,
                  <<"body">> => Body,
                  <<"evidence">> => Evidence,
                  <<"secret-recipient">> => Recipient},
              <<"nonce">> => hb_util:encode(Nonce)},
            #{}),
    ?assertEqual(false, hb_maps:get(<<"verified">>, Result, true, #{})).

test_measurement(Body, Recipient, Nonce, Opts) ->
    #{
        <<"type">> => <<"lapee-measurement">>,
        <<"body">> => Body,
        <<"evidence">> => test_evidence(Body, Recipient, Nonce, Opts),
        <<"secret-recipient">> => Recipient
    }.

test_evidence(Body, Recipient, Nonce, Opts) ->
    ReportData = report_data(Body, Nonce, Recipient, Opts),
    #{
        <<"nonce">> => hb_util:encode(Nonce),
        <<"report-data">> => hb_util:encode(ReportData),
        <<"report-json">> => #{<<"report_data">> => binary_to_list(ReportData)},
        <<"signature-check">> =>
            #{<<"verified">> => true, <<"source">> => <<"test">>}
    }.

test_body() ->
    #{
        <<"system">> => #{<<"kernel">> => <<"test">>},
        <<"node">> => #{<<"address">> => <<"test-node">>}
    }.
