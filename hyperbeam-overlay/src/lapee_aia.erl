%%% @doc Authority Information Access (RFC 5280 §4.2.2.1) helper:
%%% extract the `id-ad-caIssuers' URL from a certificate's AIA
%%% extension and HTTP-fetch the referenced issuer certificate.
%%%
%%% Driver: TPM EK certificates issued by per-SoC manufacturer chains
%%% (notably Intel's OnDie CA tree -- one issuing CA per Alder Lake /
%%% Meteor Lake / Raptor Lake / ... family) cannot be enumerated up
%%% front. Each EK leaf points -- via AIA -- at the public URL where
%%% the missing intermediate is published. Following AIA at chain-
%%% validation time is the difference between the verifier silently
%%% rejecting every Intel laptop with a SoC family we haven't pre-
%%% loaded and accepting the chain.
%%%
%%% The fetched bytes are still anchored against the operator-supplied
%%% trust roots: AIA only supplies *intermediates*, never new trust
%%% anchors. A rogue AIA URL serving a self-signed cert can never
%%% complete a chain to a legitimate root.
%%%
%%% Caching: successful fetches persist in `persistent_term', keyed by
%%% URL. The cache survives until the BEAM exits; on a fresh node boot
%%% the first peer admission re-fetches whatever isn't already in
%%% `priv/tpm-interpret/root-cas/'. Failed fetches are NOT negatively
%%% cached -- a transient network blip should not poison admission for
%%% the rest of the boot.
%%%
%%% Network policy: HTTPS only; HTTP is rejected because we have no
%%% out-of-band integrity signal during the fetch (the chain verify
%%% will catch tampering, but TLS gives us a free integrity layer
%%% before that). Connect/read timeouts are bounded by the caller via
%%% `Opts#{<<"aia-timeout-ms">>}'; the default is 5s.
%%%
%%% Disable end-to-end via `Opts#{<<"lapee-aia-fetch-enabled">> => false}'
%%% for offline / locked-down deployments. The chain validator then
%%% falls back to local-corpus-only behaviour.
-module(lapee_aia).
-export([caissuers_urls/1, fetch_issuer/1, fetch_issuer/2,
         enabled/1]).
-include_lib("public_key/include/public_key.hrl").

-define(AIA_OID,        ?'id-pe-authorityInfoAccess').
-define(CAISSUERS_OID,  ?'id-ad-caIssuers').
-define(DEFAULT_TIMEOUT_MS, 5000).
-define(MAX_FETCH_BYTES, 64 * 1024).
-define(CACHE_KEY(Url), {?MODULE, fetched, Url}).

%% @doc Extract every `id-ad-caIssuers' URL from the cert's AIA
%% extension. Returns the empty list when the cert has no AIA
%% extension (legitimate -- many self-signed roots omit it) or when
%% the extension carries only OCSP responder URLs.
-spec caissuers_urls(binary() | #'OTPCertificate'{}) -> [binary()].
caissuers_urls(Der) when is_binary(Der) ->
    try public_key:pkix_decode_cert(Der, otp) of
        Otp -> caissuers_urls(Otp)
    catch _:_ -> []
    end;
caissuers_urls(#'OTPCertificate'{tbsCertificate = Tbs}) ->
    Extensions = case Tbs#'OTPTBSCertificate'.extensions of
        asn1_NOVALUE -> [];
        L when is_list(L) -> L
    end,
    case [Value || #'Extension'{extnID = ?AIA_OID, extnValue = Value}
                       <- Extensions] of
        [] -> [];
        [AccessDescriptions | _] ->
            [Url
             ||
                #'AccessDescription'{
                    accessMethod = ?CAISSUERS_OID,
                    accessLocation =
                        {uniformResourceIdentifier, UrlStr}
                } <- AccessDescriptions,
                Url <- [iolist_to_binary(UrlStr)],
                byte_size(Url) > 0]
    end;
caissuers_urls(_) -> [].

%% @doc Should AIA fetching run at all? Operators can disable the
%% network egress entirely by setting `lapee-aia-fetch-enabled' to
%% `false' in the node config. Defaults to enabled.
-spec enabled(map()) -> boolean().
enabled(Opts) ->
    case hb_opts:get(<<"lapee-aia-fetch-enabled">>, true, Opts) of
        false -> false;
        <<"false">> -> false;
        _ -> true
    end.

%% @doc Fetch an AIA-referenced issuer cert. Returns the DER bytes on
%% success, or `{error, Reason}'. Successful results are cached in
%% `persistent_term' for the lifetime of the BEAM so repeated
%% admissions of peers that share the same SoC family hit the URL
%% exactly once.
-spec fetch_issuer(binary()) -> {ok, binary()} | {error, term()}.
fetch_issuer(Url) -> fetch_issuer(Url, #{}).

-spec fetch_issuer(binary(), map()) -> {ok, binary()} | {error, term()}.
fetch_issuer(Url, Opts) when is_binary(Url) ->
    case enabled(Opts) of
        false -> {error, aia_disabled};
        true ->
            case persistent_term:get(?CACHE_KEY(Url), undefined) of
                undefined ->
                    case do_fetch(Url, Opts) of
                        {ok, Der} = Ok ->
                            persistent_term:put(?CACHE_KEY(Url), Der),
                            Ok;
                        Err -> Err
                    end;
                Der -> {ok, Der}
            end
    end.

do_fetch(Url, Opts) ->
    case binary:match(Url, <<"https://">>) of
        {0, _} -> http_get(Url, Opts);
        _ -> {error, {non_https_aia, Url}}
    end.

http_get(Url, Opts) ->
    Timeout = parse_positive_integer(
        hb_opts:get(<<"aia-timeout-ms">>, ?DEFAULT_TIMEOUT_MS, Opts),
        ?DEFAULT_TIMEOUT_MS),
    application:ensure_all_started(inets),
    application:ensure_all_started(ssl),
    HttpOpts = [
        {timeout, Timeout},
        {connect_timeout, Timeout},
        {ssl, [{verify, verify_peer},
               {cacerts, public_key:cacerts_get()},
               {customize_hostname_check,
                [{match_fun,
                    public_key:pkix_verify_hostname_match_fun(https)}]}
              ]}
    ],
    Request = {binary_to_list(Url), [{"User-Agent", "lapee-aia/1"}]},
    case httpc:request(get, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Headers, Body}} when byte_size(Body) > 0,
                                                  byte_size(Body) =< ?MAX_FETCH_BYTES ->
            decode_cert_body(Body);
        {ok, {{_, 200, _}, _Headers, Body}}
                when byte_size(Body) > ?MAX_FETCH_BYTES ->
            {error, {body_too_large, byte_size(Body)}};
        {ok, {{_, Code, _}, _Headers, _Body}} ->
            {error, {http_status, Code}};
        {error, Reason} ->
            {error, Reason}
    end.

%% AIA endpoints typically serve DER bytes (Content-Type:
%% application/pkix-cert). Some servers return PEM. Detect by the
%% first bytes: PEM begins with `-----BEGIN'.
decode_cert_body(<<"-----BEGIN", _/binary>> = Pem) ->
    case public_key:pem_decode(Pem) of
        [{'Certificate', Der, not_encrypted} | _] -> {ok, Der};
        _ -> {error, pem_no_certificate}
    end;
decode_cert_body(Bytes) ->
    %% Validate by trying to decode as DER. Reject anything that
    %% doesn't parse as an X.509 cert -- prevents writing arbitrary
    %% bytes from a misconfigured AIA endpoint into the cache.
    try public_key:pkix_decode_cert(Bytes, otp) of
        #'OTPCertificate'{} -> {ok, Bytes}
    catch _:_ -> {error, der_decode_failed}
    end.

parse_positive_integer(N, _Default) when is_integer(N), N > 0 -> N;
parse_positive_integer(B, Default) when is_binary(B) ->
    try binary_to_integer(B) of
        N when N > 0 -> N;
        _ -> Default
    catch _:_ -> Default
    end;
parse_positive_integer(_, Default) -> Default.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

caissuers_urls_extracts_intel_adl_aia_test() ->
    Pem = read_aia_fixture("intel-adl-ek-chain.pem"),
    %% The chain is leaf -> PTT CA -> Kernel CA -> ROM CA. Only the
    %% ROM CA carries the AIA caIssuers pointer to its public Intel
    %% issuing CA -- which is the whole reason AIA fetching exists.
    Ders = [Der || {'Certificate', Der, not_encrypted}
                       <- public_key:pem_decode(Pem)],
    AllUrls = lists:flatten([caissuers_urls(D) || D <- Ders]),
    ?assertEqual(
        [<<"https://tsci.intel.com/content/OnDieCA/certs/"
           "ADL_00002820_ODCA_CA2.cer">>],
        AllUrls).

caissuers_urls_returns_empty_for_root_test() ->
    %% Self-signed roots in the keylime corpus typically omit AIA.
    Pem = read_root_fixture("INTEL_ODCA_ROOT_CA.pem"),
    [{_, Der, _} | _] = public_key:pem_decode(Pem),
    ?assertEqual([], caissuers_urls(Der)).

enabled_default_is_true_test() ->
    ?assert(enabled(#{})).

enabled_respects_false_atom_test() ->
    ?assertNot(enabled(#{<<"lapee-aia-fetch-enabled">> => false})).

enabled_respects_false_binary_test() ->
    ?assertNot(enabled(#{<<"lapee-aia-fetch-enabled">> => <<"false">>})).

fetch_issuer_when_disabled_returns_aia_disabled_test() ->
    ?assertEqual(
        {error, aia_disabled},
        fetch_issuer(<<"https://tsci.intel.com/anything">>,
                     #{<<"lapee-aia-fetch-enabled">> => false})).

fetch_issuer_rejects_non_https_test() ->
    %% No cache hit and no offline gate -- should refuse plain HTTP.
    Url = <<"http://insecure.example/intermediate.cer">>,
    ?assertEqual(undefined,
                 persistent_term:get(?CACHE_KEY(Url), undefined)),
    ?assertMatch({error, {non_https_aia, _}},
                 fetch_issuer(Url, #{})).

fetch_issuer_uses_cache_test() ->
    Url = <<"https://example/no-network/cached.cer">>,
    Synth = <<"synth-der">>,
    persistent_term:put(?CACHE_KEY(Url), Synth),
    try
        ?assertEqual({ok, Synth}, fetch_issuer(Url, #{}))
    after
        persistent_term:erase(?CACHE_KEY(Url))
    end.

read_aia_fixture(Name) ->
    Paths = [
        filename:join(["priv", "tpm-interpret", "aia-fixtures", Name]),
        filename:join(["hyperbeam-overlay", "priv", "tpm-interpret",
                       "aia-fixtures", Name])
    ],
    [Bin | _] = [B || P <- Paths, {ok, B} <- [file:read_file(P)]],
    Bin.

read_root_fixture(Name) ->
    Paths = [
        filename:join(["priv", "tpm-interpret", "root-cas", Name]),
        filename:join(["hyperbeam-overlay", "priv", "tpm-interpret",
                       "root-cas", Name])
    ],
    [Bin | _] = [B || P <- Paths, {ok, B} <- [file:read_file(P)]],
    Bin.

-endif.
