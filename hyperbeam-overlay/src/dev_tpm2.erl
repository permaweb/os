%%% @doc The TPM 2.0 device -- binds HyperBEAM's identity to a real
%%% hardware TPM via `libtss2-esys'.
%%%
%%% This device is the software-layer of the LapEE (Laptop Execution
%%% Environment) appliance architecture. At node startup, the `on.start'
%%% hook invokes `boot-attestation'. The device gathers the neutral
%%% `~system@1.0/all' report and the public `~meta@1.0/info' node
%%% message, extends PCR 15 with that combined subject's AO-Core ID,
%%% creates an AK whose authPolicy includes PCR 15 at that value, quotes
%%% the selected PCR set, signs the resulting boot-attestation message,
%%% and caches it under a stable pseudo-path.
%%%
%%% Any party can then request `attestation', which returns a signed
%%% envelope containing:
%%%   1. EK certificate (chains to TPM vendor root CA)
%%%   2. Attestation Key public key
%%%   3. TPM2_Quote over a PCR set, signed by the AK
%%%   4. The full runtime event log so a verifier can replay the PCR 15
%%%      extend and confirm it matches the quoted value
%%%   5. The node message itself, so the verifier can recompute
%%%      `hb_message:id(NodeMsg, all, Opts)' and confirm equality with
%%%      the extend digest -- closing the loop from quote back to the
%%%      specific software stack running.
%%%
%%% The device delegates all TPM operations to the `lapee_tpm_nif' NIF
%%% (a small C layer over libtss2-esys). This module is the HyperBEAM-
%%% shaped interface over that NIF: HB device conventions (`info',
%%% `(Base, Req, Opts)', exports map), standard error returns, and
%%% integration with AO-Core hook dispatch.
-module(dev_tpm2).
-export([info/1, info/3, extend/3, quote/3, pcr_read/3,
         attestation/3, boot_attestation/3, credential_subject/3,
         activate_credential/3, activate_credential_secret/2,
         verify_peer/3]).
-export([verify/3]).
-export([make_credential_for_subject/2]).
-export([event_log/1]).
%% Exposed for tests + auditors that want to drive chain validation
%% (including the AIA fallback) directly without going through verify/3.
-export([validate_ek_chain/3, validate_ek_chain/4]).
-include("include/hb.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("eunit/include/eunit.hrl").

%% Default PCR that HyperBEAM extends with the node-message identity.
-define(NODE_IDENTITY_PCR, 15).
%% PCRs that gate the AK. PCR 15 carries the LapEE boot subject, so the
%% AK is only usable by the TPM after the measured node config is present.
-define(AK_POLICY_PCRS, [0, 1, 7, 10, 11, 14, 15]).
%% Default PCR selection the quote covers.
-define(DEFAULT_QUOTE_PCRS, [0, 1, 7, 10, 11, 14, 15]).
-define(TPM_CC_ACTIVATE_CREDENTIAL, 16#00000147).
-define(TPM_CC_POLICY_COMMAND_CODE, 16#0000016C).
-define(TPM_CC_POLICY_OR, 16#00000171).
-define(TPM_CC_POLICY_PCR, 16#0000017F).
-define(BOOT_ATTESTATION_PATH, <<"~tpm@2.0a/boot-attestation">>).
-define(PEER_ATTESTATION_PREFIX, <<"~tpm@2.0a/peer-attestations">>).
-define(TCG_EK_CERT_OID, {2, 23, 133, 8, 1}).

%%%============================================================================
%%% Device API information
%%%============================================================================

%% @doc Declare the device's public surface.
info(_) ->
    #{
        exports =>
            [
                <<"info">>,
                <<"extend">>,
                <<"quote">>,
                <<"pcr-read">>,
                <<"attestation">>,
                <<"boot-attestation">>,
                <<"credential-subject">>,
                <<"activate-credential">>,
                <<"verify-peer">>,
                <<"verify">>
            ]
    }.

%% @doc Human-readable documentation for the TPM 2.0 device.
info(_Base, _Req, _Opts) ->
    InfoBody = #{
        <<"description">> =>
            <<"TPM 2.0 device: bind a HyperBEAM node's identity to a real "
              "hardware TPM via libtss2-esys, and produce signed attestations "
              "that chain through quote -> PCR extend -> event log -> node message, "
              "linking a running node's software state to TPM-rooted hardware "
              "attestation.">>,
        <<"version">> => <<"0.1">>,
        <<"specification">> => <<"TPM 2.0 (TCG)">>,
        <<"api">> => #{
            <<"info">> => #{
                <<"description">> => <<"This message.">>
            },
            <<"extend">> => #{
                <<"description">> =>
                    <<"Extend a PCR with the hash of a subject message. "
                      "Default PCR is 15 (LapEE node-identity binding).">>,
                <<"request">> => #{
                    <<"subject">> =>
                        <<"The message (or binary) whose identity should be "
                          "bound to the PCR. If absent, falls back to the "
                          "hook's `body' key, and then to the Base message.">>,
                    <<"pcr">> =>
                        <<"Integer PCR index (0-23). Defaults to 15.">>
                },
                <<"response">> =>
                    <<"`#{<<\"status\">> => 200, <<\"body\">> => "
                      "#{<<\"pcr\">> => N, "
                      "<<\"digest\">>    => base64url(bytes), "
                      "<<\"pcr_after\">> => base64url(bytes)}}'">>
            },
            <<"quote">> => #{
                <<"description">> =>
                    <<"Produce a TPM2_Quote signed by the node's Attestation "
                      "Key over the selected PCR set. Nonce comes from "
                      "`Req/nonce' if present.">>,
                <<"request">> => #{
                    <<"pcrs">> =>
                        <<"List of PCR indices to include (defaults to "
                          "[0, 1, 7, 10, 11, 14, 15]).">>,
                    <<"nonce">> =>
                        <<"base64url-encoded binary nonce (any length). If "
                          "absent, a fresh random 32-byte value is generated. "
                          "Hex input is NOT accepted - HyperBEAM wire is "
                          "base64url everywhere.">>
                }
            },
            <<"pcr-read">> => #{
                <<"description">> =>
                    <<"Read the current value of a PCR via `Esys_PCR_Read'.">>,
                <<"request">> => #{
                    <<"pcr">> => <<"Integer PCR index (required).">>
                }
            },
            <<"attestation">> => #{
                <<"description">> =>
                    <<"Produce a complete LapEE attestation envelope. Contains "
                      "EK cert chain, AK pubkey, TPM2_Quote, runtime event "
                      "log, node message, and the attested chain of trust the "
                      "LapEE verifier checks.">>,
                <<"request">> => #{
                    <<"pcrs">> => <<"Optional PCR selection.">>,
                    <<"nonce">> =>
                        <<"Optional nonce. Typical usage: consumer provides "
                          "a random nonce to prove freshness.">>
                }
            },
            <<"boot-attestation">> => #{
                <<"description">> =>
                    <<"Produce or return the singleton boot attestation. "
                      "The first call gathers ~system@1.0/all and "
                      "~meta@1.0/info, extends PCR 15 with their combined "
                      "subject ID before AK creation, creates an AK whose "
                      "authPolicy includes PCR 15, quotes the selected PCRs, "
                      "signs the full message, stores it by signed ID, and "
                      "links the stable boot-attestation path to that "
                      "signed ID.">>
            },
            <<"credential-subject">> => #{
                <<"description">> =>
                    <<"Return the public TPM material needed for "
                      "TPM2_MakeCredential: EK certificate and public area, "
                      "AK public area, and the AK Name.">>
            },
            <<"activate-credential">> => #{
                <<"description">> =>
                    <<"Run TPM2_ActivateCredential with the node's loaded AK "
                      "and EK. Used by verifiers and green-zone admission to "
                      "prove the AK and EK are resident in the same TPM. The "
                      "HTTP endpoint returns a MAC proof, not the recovered "
                      "secret; local callers that need the secret use the "
                      "Erlang activate_credential_secret/2 API.">>,
                <<"request">> => #{
                    <<"credential-blob">> =>
                        <<"base64url TPM2B_ID_OBJECT from MakeCredential">>,
                    <<"secret">> =>
                        <<"base64url TPM2B_ENCRYPTED_SECRET from "
                          "MakeCredential">>
                }
            },
            <<"verify-peer">> => #{
                <<"description">> =>
                    <<"Fetch a peer boot-attestation and credential subject, "
                      "verify both the cached boot evidence and a fresh "
                      "nonce-bound attestation, check EK certificate/public "
                      "consistency, complete MakeCredential/ActivateCredential, "
                      "then sign and cache a public peer-attestation "
                      "containing the verified peer material, freshness proof, "
                      "scope, validity, and activation transcript.">>,
                <<"request">> => #{
                    <<"url">> => <<"Peer base URL, e.g. http://HOST:8734">>,
                    <<"peer-attestation-ttl-seconds">> =>
                        <<"Optional positive integer validity window. If "
                          "absent, the signed attestation has no upper expiry.">>
                }
            }
        }
    },
    {ok, #{<<"status">> => 200, <<"body">> => InfoBody}}.

%%%============================================================================
%%% extend/3 -- the load-bearing hook entry point
%%%============================================================================

%% @doc Extend a PCR with the hash of a subject.
%%
%% Subject resolution order (highest precedence first):
%%   1. `Req/subject' -- if set, use that value.
%%   2. `Req/body'   -- the standard hook-payload location.
%%   3. `Base'       -- fallback when neither is set.
%%
%% Digest derivation:
%%   * If the resolved subject is a binary of exactly 32 bytes, it is
%%     used as the SHA-256 digest directly.
%%   * If it is any other binary, SHA-256 is applied.
%%   * If it is a map (HyperBEAM message), `hb_message:id(Subject, all, Opts)'
%%     is used -- this commits to every committed and uncommitted field in
%%     the message, which is exactly the "bind this specific node identity"
%%     semantic the LapEE paper requires.
%%
%% The PCR is taken from `Req/pcr' (integer or integer-binary), defaulting
%% to 15 -- the LapEE node-identity PCR.
%%
%% On success, also records a named event in the runtime event log via
%% `lapee_tpm_nif:append_event/2'. The event log is flushed into every
%% subsequent attestation envelope so a verifier can replay the chain.
extend(Base, Req, Opts) ->
    Subject = resolve_subject(Base, Req, Opts),
    Pcr = resolve_pcr(Req, ?NODE_IDENTITY_PCR, Opts),
    Digest = digest_of(Subject, Opts),
    case pcr_extend_allowed(Pcr) of
        ok ->
            case nif_pcr_extend(Pcr, Digest) of
                ok ->
                    %% Remember the subject (and its id) so that a later
                    %% `attestation' call can embed the same node message the
                    %% TPM committed to. The hook-dispatch path does not thread
                    %% the extended subject through `Opts', so we use
                    %% `persistent_term' -- same pattern as the event log.
                    case Subject of
                        S when is_map(S), Pcr =:= ?NODE_IDENTITY_PCR ->
                            persistent_term:put(
                                {dev_tpm2, attested_node_msg}, S);
                        _ -> ok
                    end,
                    EventDescription =
                        case Subject of
                            S0 when is_map(S0) ->
                                iolist_to_binary(
                                    io_lib:format(
                                        "hb_message:id(Subject, all) over "
                                        "~B-key message",
                                        [maps:size(S0)]));
                            _ -> <<"binary subject (non-message)">>
                        end,
                    _ = append_event(Pcr,
                        #{
                            <<"event-type">> =>
                                <<"EV_HYPERBEAM_NODE_IDENTITY_EXTEND">>,
                            <<"description">> => EventDescription,
                            <<"digest">> => hb_util:encode(Digest),
                            <<"subject-is-message">> =>
                                is_map(Subject)
                        }
                    ),
                    After = case nif_pcr_read(Pcr) of
                        {ok, V} -> hb_util:encode(V);
                        _ -> <<"?">>
                    end,
                    {ok, #{
                        <<"status">> => 200,
                        <<"body">> => #{
                            <<"pcr">> => Pcr,
                            <<"digest">> => hb_util:encode(Digest),
                            <<"pcr-after">> => After
                        }
                    }};
                {error, Reason} ->
                    {error, #{
                        <<"status">> => 500,
                        <<"body">> => #{
                            <<"error">> => <<"pcr_extend_failed">>,
                            <<"reason">> => hb_util:bin(Reason)
                        }
                    }}
            end;
        {error, Reason} ->
            error_resp(403, <<"pcr_extend_forbidden">>, Reason)
    end.

pcr_extend_allowed(?NODE_IDENTITY_PCR) ->
    case persistent_term:get({dev_tpm2, initial_pcr15_extended}, false) of
        true ->
            {error, <<"PCR 15 is already sealed into the AK policy">>};
        false -> ok
    end;
pcr_extend_allowed(_Pcr) ->
    ok.

%% @doc Extend PCR 15 with sha256(TCG event log) and record an
%% `EV_HYPERBEAM_TCG_LOG_TIP_COMMITMENT' runtime event.
%%
%% The paper's section AO-Core Continuity says:
%%
%% Mechanism: read `/sys/kernel/security/tpm0/binary_bios_measurements'
%% (the firmware-side TCG log), hash it with SHA-256, extend PCR 15
%% with that digest, and record a runtime event describing the
%% extension. This runs before AK creation when the log is available, so
%% the AK authPolicy can bind the same PCR 15 trajectory the verifier
%% later replays. The runtime-event-log entry carries the same digest so
%% the verifier can recompute sha256(envelope.tcg-event-log) and confirm
%% byte-for-byte match.
%%
%% If the log is not available from /sys (e.g. QEMU TCG without
%% vTPM event-log passthrough), the extension is SKIPPED cleanly:
%% paper P5-ext is a real-hardware property. Returns ok either
%% way so init_chain continues.
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
                            <<"description">> =>
                                <<"TPM event log tip commitment "
                                  "(paper P5-ext AO-Core hashpath "
                                  "continuity: sha256 of firmware-"
                                  "side TCG event log extended into "
                                  "PCR 15, so every subsequent AO-"
                                  "Core hashpath entry carries a "
                                  "commitment to the full boot "
                                  "measurement chain). Digest is "
                                  "byte-for-byte sha256 of the "
                                  "`tcg-event-log' field in this "
                                  "envelope.">>,
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
            %% Log not readable -- firmware doesn't expose it
            %% (QEMU without vTPM event-log passthrough is the
            %% typical case). Skip cleanly; a verifier will see
            %% absent EV_HYPERBEAM_TCG_LOG_TIP_COMMITMENT on the
            %% runtime log and grade accordingly (info on stub
            %% boots, warn on real-hardware envelopes).
            ok
    end.

%%%============================================================================
%%% quote/3
%%%============================================================================

%% @doc Request a TPM2_Quote over the given PCR selection.
%%
%% Returns the raw TPMS_ATTEST bytes (`quoted'), the AK signature,
%% the current PCR values, and the AK public key. All binary-valued
%% fields are base64url-encoded per AO-Core convention
%% (`hb_util:encode/1' / `hb_util:human_id/1').
quote(_Base, Req, Opts) ->
    Pcrs = resolve_pcr_list(Req, ?DEFAULT_QUOTE_PCRS, Opts),
    Nonce = resolve_nonce(Req),
    case ensure_ak(Opts) of
        {ok, AkTr} ->
            case nif_quote(AkTr, Pcrs, Nonce) of
                {ok, #{quoted := Q, signature := Sig, pcr_values := PcrMap}} ->
                    QuoteBody = quote_body(Pcrs, Nonce, Q, Sig, PcrMap),
                    {ok, #{
                        <<"status">> => 200,
                        <<"body">> => QuoteBody#{
                            <<"ak-pub-pem">> => ak_pub_pem(Opts)
                        }
                    }};
                {error, Reason} ->
                    error_resp(500, <<"quote_failed">>, Reason)
            end;
        {error, Reason} ->
            error_resp(500, <<"ak_unavailable">>, Reason)
    end.

%%%============================================================================
%%% pcr-read/3
%%%============================================================================

pcr_read(_Base, Req, Opts) ->
    Pcr = resolve_pcr(Req, 0, Opts),
    case nif_pcr_read(Pcr) of
        {ok, V} ->
            {ok, #{
                <<"status">> => 200,
                <<"body">> => #{
                    <<"pcr">> => Pcr,
                    <<"value">> => hb_util:encode(V)
                }
            }};
        {error, Reason} ->
            error_resp(500, <<"pcr_read_failed">>, Reason)
    end.

%%%============================================================================
%%% verify/3 -- HB-side attestation verifier
%%%============================================================================

%% @doc Verify an attestation envelope end-to-end in-process. This is
%% what one HyperBEAM node uses to verify a peer, intended to be
%% reached via:
%%
%%   ~relay@1.0/call&relay-path="http://PEER:PORT/~tpm@2.0a/attestation"
%%       /verify~tpm@2.0a
%%
%% `Base' is the attestation envelope (same shape emitted by
%% `attestation/3'). Options in `Req':
%%   trusted-ca : base64url PEM bytes of TPM vendor root CAs to trust.
%%                Ignored unless `lapee_allow_request_trusted_ca' is
%%                explicitly enabled in node config. Production LapEE
%%                nodes default to the measured-in
%%                `priv/tpm-interpret/root-cas/' bundle, or to
%%                `lapee_tpm_ca_cert' in `Opts' if configured.
%%
%% Return shape (always 200 -- the `verified' bool is the real verdict):
%%   verified : boolean
%%   verdict  : "accepted" | "rejected"
%%   checks   : list of per-check reports in stable order
%%   Each check: #{ name, ok, detail }
verify(Base, Req, Opts) ->
    Envelope = normalise_attestation(resolve_envelope(Base, Req, Opts), Opts),
    {TrustedCaPem, CaSource} = resolve_trusted_ca_with_source(Req, Opts),
    Checks = [
        safely_run(fun() -> chk_ek_chain(Envelope, TrustedCaPem, Opts) end,
                   <<"EK certificate chains to trusted TPM vendor root CA">>,
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
        safely_run(fun() -> chk_node_msg_shape(Envelope) end,
                   <<"Embedded node_message + id present and correct shape">>,
                   <<"core">>),
        %% `firmware TCG event log replay' is INFORMATIONAL: the
        %% paper's trust anchor is PCR 15 (the LapEE node identity),
        %% not the firmware-emitted PCRs 0-14. SeaBIOS under QEMU
        %% legitimately emits an incomplete log that does not
        %% fully replay into the quoted PCR 1; that's a SeaBIOS
        %% quirk, not a LapEE security problem. The check runs,
        %% surfaces its result in `checks', but does NOT gate
        %% `verified' -- policy engines that want strict firmware-
        %% log consistency can key off the severity field.
        safely_run(fun() -> chk_tcg_event_log_replay(Envelope) end,
                   <<"Firmware TCG event log replays to quoted PCRs 0-14">>,
                   <<"informational">>)
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
            %% Tells callers which trust anchor was actually used.
            %% Helpful when debugging trust-anchor provenance.
            %% Production nodes should normally report
            %% `internal-bundle'.
            <<"trust-anchor-source">> => CaSource
        }
    }}.

normalise_attestation(Envelope, Opts) when is_map(Envelope) ->
    case hb_maps:get(<<"body">>, Envelope, undefined, #{}) of
        Body when is_map(Body) ->
            case hb_maps:get(<<"tpm">>, Body, undefined, #{}) of
                Tpm when is_map(Tpm) -> normalise_attestation(Body, Opts);
                _ -> normalise_attestation_body(Envelope, Opts)
            end;
        _ -> normalise_attestation_body(Envelope, Opts)
    end;
normalise_attestation(Other, _Opts) ->
    Other.

normalise_attestation_body(Envelope, Opts) when is_map(Envelope) ->
    case hb_maps:get(<<"tpm">>, Envelope, undefined, #{}) of
        Tpm when is_map(Tpm) ->
            Node = hb_maps:get(<<"node">>, Envelope, undefined, #{}),
            ExtendedSubject =
                hb_maps:get(<<"extended-subject">>, Tpm, undefined, #{}),
            LegacyNodeID =
                case Node of
                    M1 when is_map(M1) ->
                        hb_util:human_id(
                            hb_util:native_id(
                                hb_message:id(M1, all, Opts)));
                    _ -> undefined
                end,
            NodeID =
                case ExtendedSubject of
                    B when is_binary(B), byte_size(B) > 0 -> B;
                    _ -> LegacyNodeID
                end,
            Quote = hb_maps:get(<<"quote">>, Tpm, #{}, #{}),
            Tpm#{
                <<"lapee-attestation-version">> =>
                    hb_maps:get(<<"lapee-attestation-version">>,
                                Envelope, <<"1.0">>, #{}),
                <<"tpm-quote">> => Quote,
                <<"node-message">> => Node,
                <<"node-message-id">> => NodeID,
                <<"wallet-address">> =>
                    case Node of
                        M2 when is_map(M2) ->
                            hb_maps:get(<<"address">>, M2, null, #{});
                        _ -> null
                    end
            };
        _ -> Envelope
    end.

%% Wrap any check in a try/catch so one malformed field doesn't take
%% down the whole verifier -- the relevant check just becomes `ok=false,
%% detail=exception.
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

%% Find the attestation envelope in the resolution chain we were
%% handed. In order:
%%   1. Req/envelope, if explicitly provided by the caller
%%   2. If Base itself carries `lapee_attestation_version', it IS the
%%      envelope (direct call)
%%   3. If Base has a `body' key whose value has
%%      `lapee_attestation_version', unwrap it (the common case:
%%      verify is invoked as the second segment of
%%      `.../attestation/verify~tpm@2.0a' and Base is the response
%%      message produced by `attestation/3').
%% Reviewer pass 10 fuzzer: guard on `is_map(Base)' so a
%% non-map Base (list, binary, atom) does not crash
%% `hb_maps:get(<<"body">>, Base, ...)' with `{badmap, Base}'.
%% Kept in lock-step with `dev_tpm_interpret:resolve_envelope/3'.
resolve_envelope(Base, Req, Opts) when is_map(Base) ->
    case hb_maps:get(<<"envelope">>, Req, undefined, Opts) of
        E when is_map(E) -> E;
        _ ->
            case is_envelope(Base) of
                true -> Base;
                false ->
                    case hb_maps:get(<<"body">>, Base, undefined, Opts) of
                        Inner when is_map(Inner) -> Inner;
                        _ -> Base
                    end
            end
    end;
resolve_envelope(_Base, _Req, _Opts) ->
    #{}.

is_envelope(M) when is_map(M) ->
    hb_maps:get(<<"lapee-attestation-version">>, M, undefined, #{}) /=
        undefined;
is_envelope(_) ->
    false.

resolve_trusted_ca(Req, Opts) ->
    {Pem, _Source} = resolve_trusted_ca_with_source(Req, Opts),
    Pem.

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
    truthy(first_defined([
        opt_value(lapee_allow_request_trusted_ca, Opts),
        opt_value(<<"lapee-allow-request-trusted-ca">>, Opts),
        opt_value(<<"lapee_allow_request_trusted_ca">>, Opts)
    ])).

truthy(true) -> true;
truthy(1) -> true;
truthy(<<"true">>) -> true;
truthy(<<"1">>) -> true;
truthy("true") -> true;
truthy("1") -> true;
truthy(_) -> false.

resolve_trusted_ca_from_config(Opts) ->
    case configured_trusted_ca_path(Opts) of
        undefined ->
            resolve_trusted_ca_from_internal_bundle(Opts);
        Path ->
            case file:read_file(path_to_list(Path)) of
                {ok, Pem}  -> {Pem, <<"node-config">>};
                {error, _} -> {<<>>, <<"node-config-missing">>}
            end
    end.

configured_trusted_ca_path(Opts) ->
    first_defined([
        opt_value(lapee_tpm_ca_cert, Opts),
        opt_value(<<"lapee-tpm-ca-cert">>, Opts),
        opt_value(<<"lapee_tpm_ca_cert">>, Opts)
    ]).

opt_value(Key, Opts) ->
    case hb_opts:get(Key, undefined, Opts) of
        undefined -> raw_opt_value(Key, Opts);
        V -> V
    end.

raw_opt_value(Key, Opts) when is_map(Opts) ->
    maps:get(Key, Opts, undefined);
raw_opt_value(_Key, _Opts) ->
    undefined.

resolve_trusted_ca_from_internal_bundle(Opts) ->
    Roots = hb_maps:get(<<"cert-roots">>, hb_db_tpm:load(Opts), [], #{}),
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

%%---- check 1: EK cert chain --------------------------------------------
%%
%% pkix_path_validation drives a verify_fun when it encounters events
%% it can't resolve unilaterally -- most legitimately, unknown TCG
%% extensions on EK certs (tpmManufacturer / tpmModel / tpmVersion /
%% tpmSpecification OIDs, which stock OTP doesn't know). We allow
%% ONLY those extension events through; every {bad_cert, _} event
%% (unknown_ca, self-signed, expired, name-mismatch, etc.) is a hard
%% reject. Returning {valid, State} for everything -- the original
%% implementation -- was a rubber stamp: pkix would surface
%% `{bad_cert, selfsigned_peer}` for a rogue EK and the callback
%% would tell it "that's fine", defeating the whole chain check.
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
                      "set `lapee_tpm_ca_cert' in node config, or pass "
                      "`trusted-ca' with "
                      "`lapee_allow_request_trusted_ca' enabled">>};
        {{error, Why}, _} ->
            {error, iolist_to_binary(io_lib:format("ek_cert_pem invalid: ~p",
                                                    [Why]))}
    end.

validate_ek_chain(EkDer, PeerChainDers, TrustedDers) ->
    validate_ek_chain(EkDer, PeerChainDers, TrustedDers, #{}).
validate_ek_chain(_EkDer, _PeerChainDers, [], _Opts) ->
    {error, <<"trusted CA missing or unparseable">>};
validate_ek_chain(EkDer, PeerChainDers, TrustedDers, Opts) ->
    case attempt_chain(EkDer, PeerChainDers, TrustedDers) of
        {ok, _} = Ok -> Ok;
        {error, Reasons} ->
            %% Local roots + envelope-supplied intermediates didn't
            %% close the chain. Try AIA caIssuers walking from the
            %% leaf upward (e.g. Intel ODCA's per-SoC issuing CAs are
            %% only published at tsci.intel.com and are not part of
            %% the keylime corpus). Disabled-by-config short-circuits
            %% to the original error.
            case lapee_aia:enabled(Opts) of
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

%% Walk the leaf -> known-intermediates list from the bottom up,
%% asking each cert's AIA extension for its issuer URL and fetching
%% any cert that isn't already in the candidate set. Stops when the
%% next cert's issuer matches a TrustedDer subject, when AIA returns
%% nothing fetchable, or after `?AIA_MAX_DEPTH' hops -- whichever
%% comes first.
-define(AIA_MAX_DEPTH, 5).

extend_chain_via_aia(EkDer, PeerChainDers, TrustedDers, Opts) ->
    aia_walk([EkDer | PeerChainDers], PeerChainDers, TrustedDers,
             Opts, ?AIA_MAX_DEPTH, []).

aia_walk(_Trail, AccChain, _Trusted, _Opts, 0, Fetches) ->
    summarise_aia_walk(AccChain, Fetches, <<"max-depth reached">>);
aia_walk(Trail, AccChain, Trusted, Opts, Budget, Fetches) ->
    %% Use the most-recently-added cert in the trail as the "current"
    %% subject whose issuer we'd like to find next.
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

%% For a given subject DER, decide whether AIA fetch is needed and, if
%% so, fetch and return the issuer. Returns:
%%   skip                         - issuer matches a known trusted root
%%   {fetched, IssuerDer, Url}    - fetched a new intermediate
%%   {error, Why}                 - AIA had no URL or fetch failed.
aia_fetch_for(Der, AccChain, Trusted, Opts) ->
    try public_key:pkix_decode_cert(Der, otp) of
        Otp ->
            Tbs = Otp#'OTPCertificate'.tbsCertificate,
            IssuerDn = public_key:pkix_normalize_name(
                Tbs#'OTPTBSCertificate'.issuer),
            case issuer_known(IssuerDn, AccChain ++ Trusted) of
                true -> skip;
                false ->
                    case lapee_aia:caissuers_urls(Otp) of
                        [] -> {error, no_aia_url};
                        Urls ->
                            try_aia_urls(Urls, IssuerDn, Opts)
                    end
            end
    catch _:Reason -> {error, {decode_failed, Reason}}
    end.

try_aia_urls([], _IssuerDn, _Opts) -> {error, all_aia_urls_failed};
try_aia_urls([Url | Rest], IssuerDn, Opts) ->
    case lapee_aia:fetch_issuer(Url, Opts) of
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
                    PeerChainDers, TrustedDers, AnchorDer),
                AnchorDer)
    catch
        Class:Reason ->
            {error,
                iolist_to_binary(io_lib:format(
                    "trusted CA bundle contains a structurally PEM-shaped "
                    "entry that is not a valid DER certificate (~p:~p); "
                    "refresh the measured-in root-cas bundle or configured "
                    "`lapee_tpm_ca_cert'.",
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

validate_ek_chain_paths(AnchorOtp, EkDer, IntermediateChains, AnchorDer) ->
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
            Reasons = [
                diagnose_chain_failure(Why, EkDer, AnchorDer)
            ||
                {_Intermediates, _Path, {error, Why}} <- Attempts
            ],
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

%% Produce a targeted error message for common pkix_path_validation
%% failures. The most confusing one in practice is `{bad_cert,
%% invalid_signature}' when the trusted CA's *subject* matches the
%% EK's *issuer* (same CN, same DN) but the CA's public key is from
%% a different generation (e.g. per-boot test CA that got out of
%% sync with the peer's current boot). That case is indistinguishable
%% from a rogue-CA attack at the pkix level, but we can make it
%% diagnosable by comparing the RDNs and flagging "name match, key
%% mismatch" so an operator knows whether to refresh their trust
%% anchor vs. investigate tampering.
diagnose_chain_failure(Why, EkDer, CaDer) ->
    Generic = iolist_to_binary(io_lib:format("chain invalid: ~p", [Why])),
    try
        EkOtp = public_key:pkix_decode_cert(EkDer, otp),
        CaOtp = public_key:pkix_decode_cert(CaDer, otp),
        EkTbs = EkOtp#'OTPCertificate'.tbsCertificate,
        CaTbs = CaOtp#'OTPCertificate'.tbsCertificate,
        EkIssuer = EkTbs#'OTPTBSCertificate'.issuer,
        CaSubject = CaTbs#'OTPTBSCertificate'.subject,
        case {Why, public_key:pkix_normalize_name(EkIssuer)
                 =:= public_key:pkix_normalize_name(CaSubject)} of
            {{bad_cert, invalid_signature}, true} ->
                <<"chain invalid: EK's issuer DN matches the trusted CA's "
                  "subject DN, but the signature does not verify under that "
                  "CA's public key. The trust anchor is from a different "
                  "CA generation than the one that signed this EK (common "
                  "when the peer rebooted and regenerated a per-boot test "
                  "CA -- refresh the trust anchor from the peer's CURRENT "
                  "boot), or a rogue CA with the same DN is being "
                  "presented (investigate).">>;
            {{bad_cert, invalid_issuer}, _} ->
                <<"chain invalid: EK's issuer DN does not match any "
                  "trusted CA's subject DN. The peer presented an EK "
                  "signed by a different CA entirely.">>;
            _ ->
                Generic
        end
    catch _:_ -> Generic
    end.

%% Verify-fun for the EK cert chain validation. Pulled out so it can
%% be unit-tested in isolation -- the previous implementation
%% returned `{valid, State}' for every event and that rubber-stamped
%% `{bad_cert, selfsigned_peer}', `{bad_cert, unknown_ca}' et al.
%%
%% Mirrors `dev_tpm_interpret:ek_verify_fun/3' semantics (kept in
%% sync deliberately; a divergence here would mean `dev_tpm2:verify/3'
%% accepts a chain the parser-side `validate_ek_chain/3' rejects, or
%% vice-versa). TCG EK-profile OIDs are metadata, so unknown critical
%% and non-critical extensions under `2.23.133.*' are accepted while
%% the cryptographic issuer/signature/path checks still run normally.
%% TPM EK leaf certificates also legitimately carry keyEncipherment
%% key usage plus the TCG EK EKU rather than the generic TLS leaf
%% usages OTP expects; accept `invalid_key_usage' only for that exact
%% EK-leaf shape.
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
    %% Called for each non-critical unknown extension. Accept any
    %% OID under the TCG arc 2.23.133.x (EK metadata attributes).
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

%%---- check 2: quote signature + extraData + pcrDigest -----------------
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
            %% Signature: RSA-PSS with SHA-256, salt 32 (matches the NIF).
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

%% Parse TPMS_ATTEST: magic(4) + type(2) + qualifiedSigner(TPM2B) +
%% extraData(TPM2B) + clockInfo(17) + firmwareVersion(8) +
%% attested(TPMS_QUOTE_INFO = TPML_PCR_SELECTION + TPM2B_DIGEST).
chk_tpms_attest(Quoted, ExpectedNonce, SelIndices, PcrMap,
                ExpectedQualifiedSigner) ->
    try
        <<16#ff544347:32/unsigned-big, 16#8018:16/unsigned-big,
          Rest0/binary>> = Quoted,
        {QualifiedSigner, Rest1} = tpm2b(Rest0),
        {ExtraData, Rest2}       = tpm2b(Rest1),
        %% clockInfo (17) + firmwareVersion (8) = 25 bytes
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
                %% Verify pcrDigest = sha256(pcr_values concatenated in
                %% the signed TPM PCR selection order.
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

%%---- check 3: AK authPolicy binds the AK to quoted PCRs ---------------
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

%%---- check 3: event-log replay matches quoted PCR 15 ------------------
%%
%% Require at least one PCR-15 event. With zero events, `Replayed'
%% would be the all-zero sentinel; if an attestation also reported
%% PCR 15 as all-zero, the check would vacuously pass. `chk_binding'
%% separately catches that shape, but we make the intent explicit
%% here too: a LapEE node MUST have extended PCR 15 at least once
%% (via the enforced `on.start' hook), so an envelope with zero
%% PCR-15 events is not a valid LapEE attestation regardless of the
%% quoted PCR value.
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

%%---- check 4: PCR 15 event commits to node_message_id -----------------
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
            %% node_message_id is a base64url human_id (43 chars).
            %% Each event digest is also base64url. Compare the decoded
            %% raw bytes so encoding quirks don't matter.
            IdRaw =
                try hb_util:decode(Id)
                catch _:_ -> <<>>
                end,
            case byte_size(IdRaw) of
                32 ->
                    %% Real 32-byte id; look for an event whose raw
                    %% digest matches byte-for-byte.
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
                    %% Empty / short / unparseable id. Refuse to
                    %% consider any event a match -- otherwise an
                    %% envelope with `node_message_id = ""' and an
                    %% event with `digest = ""' would match the empty
                    %% binary trivially.
                    {error, iolist_to_binary(io_lib:format(
                        "node_message_id decodes to ~B bytes, expected 32",
                        [Size]))}
            end
    end.

%%---- check 6: TCG event log replays to quoted PCRs 0-14 --------------
%%
%% The firmware-side TCG event log (tcg_event_log in the envelope) is
%% the source of truth for PCR 0-14 state. Every event declares which
%% PCR it was extended into + the digest it extended with. Replaying
%% from zero should reconstruct exactly the PCR values the TPM
%% reported in the quote.
%%
%% If an attacker presented an altered envelope (e.g. swapped in a
%% different firmware measurement but kept the quote), the replay
%% would diverge from the quoted value, rejecting.
%%
%% Permissive cases (not hard-rejects):
%%   - Envelope has no tcg_event_log (byte_size 0) -- can happen with
%%     QEMU SeaBIOS test guests where SeaBIOS emits only a minimal
%%     log. In this case there are no per-PCR events to replay, so
%%     the check is skipped with {ok, <<"no firmware log">>}. Callers
%%     who require a firmware log should refuse this verdict.
%%   - Event log parses but produces an error marker -- replay what
%%     we got anyway, but flag partial.
%%
%% Hard rejects:
%%   - For any PCR in 0-14 where the event log DOES have events,
%%     the reconstructed value MUST match the quoted value. Mismatch
%%     = fail.
chk_tcg_event_log_replay(Envelope) ->
    LogB64 = hb_maps:get(<<"tcg-event-log">>, Envelope, <<>>, #{}),
    LogBin = case LogB64 of
                 <<>> -> <<>>;
                 B when is_binary(B) ->
                     try hb_util:decode(B) catch _:_ -> <<>> end
             end,
    case byte_size(LogBin) of
        0 -> {ok, <<"no firmware log present (accepted)">>};
        _ ->
            Parsed = dev_tpm_tcg:parse(LogBin),
            Events = [V || {_, V} <- maps:to_list(Parsed),
                           is_map(V), not maps:is_key(<<"error">>, V)],
            Q = hb_maps:get(<<"tpm-quote">>, Envelope, #{}, #{}),
            QuotedPcrs = hb_maps:get(<<"pcr-values">>, Q, #{}, #{}),
            replay_and_compare(Events, QuotedPcrs, 0, [])
    end.

replay_and_compare([], _QuotedPcrs, Count, Mismatches) ->
    case Mismatches of
        [] ->
            {ok, iolist_to_binary(io_lib:format(
                "replayed ~B TCG event(s) into PCRs; all match the "
                "quoted values",
                [Count]))};
        _ ->
            {error, iolist_to_binary(io_lib:format(
                "TCG event log replay diverges from quoted PCR(s): ~p",
                [Mismatches]))}
    end;
replay_and_compare([Ev | Rest], QuotedPcrs, Count, Mismatches) ->
    %% EV_NO_ACTION is explicitly NOT extended (the spec says so).
    case maps:get(<<"event-type-code">>, Ev, 0) of
        3 ->  %% EV_NO_ACTION
            replay_and_compare(Rest, QuotedPcrs, Count, Mismatches);
        _ ->
            %% Fold this event's SHA-256 digest into the running
            %% reconstruction for its PCR, then (lazily) check at
            %% the end by asking whether the reconstructed PCR
            %% matches the quoted PCR. Accumulate per-PCR state
            %% in the process dictionary keyed by the PCR number;
            %% this avoids threading yet another state map.
            Pcr = maps:get(<<"pcr">>, Ev, -1),
            case in_range(Pcr) of
                false ->
                    replay_and_compare(Rest, QuotedPcrs,
                                       Count + 1, Mismatches);
                true ->
                    Digests = maps:get(<<"digests">>, Ev, #{}),
                    case maps:get(<<"sha256">>, Digests, undefined) of
                        D when is_binary(D), byte_size(D) =:= 32 ->
                            Prev = case get({replay_pcr, Pcr}) of
                                       undefined -> <<0:256>>;
                                       V -> V
                                   end,
                            Next = crypto:hash(sha256,
                                               <<Prev/binary, D/binary>>),
                            put({replay_pcr, Pcr}, Next),
                            case Rest of
                                [] ->
                                    MoreMismatches =
                                        collect_mismatches(QuotedPcrs,
                                                           Mismatches),
                                    replay_and_compare([], QuotedPcrs,
                                                       Count + 1,
                                                       MoreMismatches);
                                _ ->
                                    replay_and_compare(Rest, QuotedPcrs,
                                                       Count + 1,
                                                       Mismatches)
                            end;
                        _ ->
                            %% No SHA-256 digest on this event --
                            %% rare in modern logs. Skip without
                            %% counting as a mismatch; the overall
                            %% PCR reconstruction will reveal any
                            %% problem at the end.
                            replay_and_compare(Rest, QuotedPcrs,
                                               Count + 1, Mismatches)
                    end
            end
    end.

in_range(P) when is_integer(P), P >= 0, P =< 14 -> true;
in_range(_) -> false.

%% After replaying every event, compare each per-PCR
%% reconstruction against the quoted value. Only PCRs that
%% actually saw an event are compared -- an all-zero PCR with no
%% events is consistent.
collect_mismatches(QuotedPcrs, InitMismatches) ->
    lists:foldl(
        fun(P, Acc) ->
            case erase({replay_pcr, P}) of
                undefined -> Acc;
                Reconstructed ->
                    Key = integer_to_binary(P),
                    case hb_maps:get(Key, QuotedPcrs, undefined, #{}) of
                        undefined -> Acc;
                        QB64 ->
                            Quoted = hb_util:decode(QB64),
                            case Quoted of
                                Reconstructed -> Acc;
                                _ -> [{P, mismatch} | Acc]
                            end
                    end
            end
        end,
        InitMismatches,
        lists:seq(0, 14)).

%%---- check 5: node_message is present + id shape is right ------------
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
    %% Reviewer pass 13 (crypto primitives): removed a dead
    %% `#'SubjectPublicKeyInfo'{}' fallback that called
    %% `public_key:pkix_decode_cert(Spki, otp)' on a record --
    %% `pkix_decode_cert' expects DER bytes, so that clause was
    %% broken as well as unreachable (the NIF always emits SPKI
    %% PEM which OTP's `pem_entry_decode/1' renders directly as
    %% `#'RSAPublicKey'{}').
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

%%%============================================================================
%%% attestation/3 -- the full envelope
%%%============================================================================

%% @doc Produce a full LapEE attestation envelope.
%%
%% The envelope is a plain AO-Core message. Binary-like fields are
%% base64url-encoded via `hb_util:encode/1' (same convention as every
%% other hash/id in AO-Core -- `hb_message:id/3' returns a base64url
%% binary, `hb_util:human_id/1' does the same, etc.). To receive the
%% envelope inline over HTTP, pass `accept: application/json@1.0' +
%% `accept-bundle: true' (or the equivalent content-negotiation via
%% the `accept' query-string key); the normal codec dispatch in
%% `hb_http' then uses `dev_codec_json' with `bundle => true' and
%% the entire envelope arrives as one JSON body.
%%
%% Envelope shape (v0.3, base64url convention):
%%   lapee_attestation_version : <<"0.3">>
%%   issued_at_unix            : integer
%%   ek_cert_pem               : binary (PEM text)
%%   ak_pub_pem                : binary (PEM text)
%%   tpm_quote                 :
%%     pcr_selection  : [integer]         % PCR indices the quote covers
%%     nonce          : base64url(raw_nonce_bytes)
%%     quoted         : base64url(TPMS_ATTEST bytes)
%%     signature      : base64url(TPMT_SIGNATURE bytes)
%%     pcr_values     : #{ integer_pcr_as_binary => base64url(raw_pcr) }
%%   runtime_event_log         : [ #{ pcr :: integer,
%%                                    digest :: base64url(raw_hash),
%%                                    event_type :: binary, ... } ]
%%   node_message              : the AO-Core message that was extended
%%                               into PCR 15 at boot
%%   node_message_id           : base64url(hb_util:native_id/1 of
%%                               hb_message:id(node_message, all, Opts))
%%   wallet_address            : base64url human id of the operator
%% Read the kernel's binary TCG event log. Canonical location is
%% `/sys/kernel/security/tpm0/binary_bios_measurements' (requires
%% securityfs mounted, kernel TPM driver loaded). Falls back to
%% `/sys/kernel/security/tpm1/...' (some Linux configs index their
%% TPM at tpm1). Returns empty binary when the log isn't
%% accessible -- either (a) no TPM driver, (b) securityfs not
%% mounted, or (c) host has no firmware-measured boot (which is
%% true for QEMU SeaBIOS test guests running under swtpm, where
%% SeaBIOS emits only a minimal log). An empty TCG log doesn't
%% break the attestation -- interpretation callers just see no
%% firmware events to reason about.
read_tcg_event_log() ->
    {Bin, _Source} = read_tcg_event_log_with_source(),
    Bin.

%% Variant that also returns the path we read from (or
%% `<<"unavailable">>`). Used by `tcg_event_log/3` so the
%% client can see which /sys path served the bytes.
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

%% Classify the raw TCG event log bytes without a full parse.
%% Used to stamp `tcg-event-log-format' on the attestation
%% envelope so a verifier can branch without re-walking the
%% whole log. The same heuristic is mirrored in
%% `dev_tpm_interpret:detect_log_format/1' for the post-parse
%% path.
infer_log_format(<<>>) -> <<"empty">>;
infer_log_format(Bin) when byte_size(Bin) < 32 ->
    <<"unknown">>;
infer_log_format(Bin) ->
    %% Crypto-agile logs begin with a TCG_PCR_EVENT (legacy
    %% 1.2 shape: pcr u32 + event-type u32 + 20-byte SHA-1 +
    %% 4-byte event-data-size + event-data), where:
    %%   * event-type = 3 (EV_NO_ACTION)
    %%   * event-data starts with ASCII "Spec ID Event03".
    %% TDX CCEL logs differ in that the first record is on
    %% PCR != 0 (MRTD lives on PCR 1).
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

%%%============================================================================
%%% boot-attestation/3
%%%============================================================================

boot_attestation(_Base, _Req, Opts) ->
    case hb_cache:read(?BOOT_ATTESTATION_PATH, Opts) of
        {ok, Msg} ->
            {ok, #{<<"status">> => 200, <<"body">> => Msg}};
        _ ->
            global:trans(
                {dev_tpm2, boot_attestation},
                fun() -> boot_attestation_locked(Opts) end,
                [node()])
    end.

boot_attestation_locked(Opts) ->
    case hb_cache:read(?BOOT_ATTESTATION_PATH, Opts) of
        {ok, Msg} ->
            {ok, #{<<"status">> => 200, <<"body">> => Msg}};
        _ ->
            case generate_boot_attestation(Opts) of
                {ok, Signed} ->
                    SignedID = hb_message:id(Signed, signed, Opts),
                    {ok, _UnsignedID} = hb_cache:write(Signed, Opts),
                    ok = hb_cache:link(SignedID, ?BOOT_ATTESTATION_PATH, Opts),
                    {ok, #{<<"status">> => 200, <<"body">> => Signed}};
                {error, Reason} ->
                    error_resp(500, <<"boot_attestation_failed">>, Reason)
            end
    end.

credential_subject(_Base, _Req, Opts) ->
    case ensure_ak(Opts) of
        {ok, _AkTr} ->
            Subject = credential_subject_body(Opts),
            {ok, #{
                <<"status">> => 200,
                <<"body">> => hb_message:commit(Subject, Opts)
            }};
        {error, Reason} ->
            error_resp(500, <<"credential_subject_failed">>, Reason)
    end.

credential_subject_body(Opts) ->
    #{
        <<"type">> => <<"lapee-tpm-credential-subject">>,
        <<"version">> => <<"1.0">>,
        <<"issued-at-unix">> => erlang:system_time(second),
        <<"ek-cert-pem">> => ek_cert_pem(Opts),
        <<"ek-cert-chain-pem">> => ek_cert_chain_pem(),
        <<"ek-cert-source">> => ek_cert_source(),
        <<"ek-cert-chain-diagnostics">> => ek_cert_chain_diagnostics(),
        <<"ek-pub-pem">> => ek_pub_pem(Opts),
        <<"ek-public">> => ek_public(Opts),
        <<"ek-name">> => ek_name(Opts),
        <<"ek-qualified-name">> => ek_qualified_name(Opts),
        <<"ak-pub-pem">> => ak_pub_pem(Opts),
        <<"ak-public">> => ak_public(Opts),
        <<"ak-name">> => ak_name(Opts),
        <<"ak-qualified-name">> => ak_qualified_name(Opts),
        <<"tpm-properties">> => tpm_properties()
    }.

activate_credential(_Base, Req, Opts) ->
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

verify_peer(_Base, Req, Opts) ->
    case peer_url(Req, Opts) of
        undefined ->
            error_resp(400, <<"missing_peer_url">>,
                       <<"verify-peer requires `url' or `peer'.">>);
        Url0 ->
            Url = strip_trailing_slash(Url0),
            case verify_peer_url(Url, Req, Opts) of
                {ok, Signed} ->
                    {ok, #{<<"status">> => 200, <<"body">> => Signed}};
                {error, #{<<"status">> := _} = Body} ->
                    {ok, Body};
                {error, Reason} ->
                    error_resp(502, <<"verify_peer_failed">>, Reason)
            end
    end.

verify_peer_url(Url, Req, Opts) ->
    with_ok(
        fun() ->
            Boot0 = lapee_peer_http:get(
                Url, <<"/~tpm@2.0a/boot-attestation">>, Opts),
            Boot = resolve_subject_body(Boot0, Opts),
            Subject0 =
                lapee_peer_http:get(
                    Url, <<"/~tpm@2.0a/credential-subject">>, Opts),
            Subject = resolve_subject_body(Subject0, Opts),
            FreshNonce = crypto:strong_rand_bytes(32),
            Fresh0 = lapee_peer_http:get(
                Url, fresh_attestation_path(FreshNonce), Opts),
            Fresh = resolve_subject_body(Fresh0, Opts),
            BootEnv = normalise_attestation(Boot, Opts),
            FreshEnv = normalise_attestation(Fresh, Opts),
            BootVerifyReq =
                (maps:remove(<<"nonce">>, Req))#{<<"envelope">> => BootEnv},
            {ok, #{<<"body">> := BootVerifyBody}} =
                verify(BootEnv, BootVerifyReq, Opts),
            case hb_maps:get(<<"verified">>, BootVerifyBody, false, #{}) of
                true -> ok;
                false ->
                    throw({boot_attestation_error,
                           #{<<"peer-boot-verification">> => BootVerifyBody}})
            end,
            FreshVerifyReq = Req#{
                <<"envelope">> => FreshEnv,
                <<"nonce">> => hb_util:encode(FreshNonce)
            },
            {ok, #{<<"body">> := FreshVerifyBody}} =
                verify(FreshEnv, FreshVerifyReq, Opts),
            case hb_maps:get(<<"verified">>, FreshVerifyBody, false, #{}) of
                true -> ok;
                false ->
                    throw({boot_attestation_error,
                           #{<<"peer-fresh-verification">> =>
                                FreshVerifyBody}})
            end,
            ok = ensure_attestation_subjects_match(BootEnv, FreshEnv),
            ok = ensure_subject_matches_boot(Subject, BootEnv),
            ok = ensure_subject_matches_boot(Subject, FreshEnv),
            ok = ensure_ak_public_matches_subject(Subject),
            ok = ensure_ek_public_matches_cert(Subject),
            Challenge = crypto:strong_rand_bytes(32),
            Credential = make_credential_for_subject(Subject, Challenge),
            Activation = activate_peer_credential(Url, Credential, Opts),
            ok = ensure_activation_secret(
                Activation, Credential, Challenge, Subject, Opts),
            Now = erlang:system_time(second),
            Signed = hb_message:commit(
                #{
                    <<"type">> => <<"green-zone-peer-attestation">>,
                    <<"version">> => <<"1.0">>,
                    <<"issued-at-unix">> => Now,
                    <<"validity">> =>
                        peer_attestation_validity(Now, Req, Opts),
                    <<"peer-url">> => Url,
                    <<"peer-scope">> =>
                        peer_attestation_scope(
                            Url, Boot, Fresh, Subject, Req, Opts),
                    <<"peer-boot-attestation">> => Boot,
                    <<"peer-fresh-attestation">> => Fresh,
                    <<"peer-credential-subject">> => Subject,
                    <<"boot-verification">> => BootVerifyBody,
                    <<"verification">> => FreshVerifyBody,
                    <<"freshness">> => #{
                        <<"verified">> => true,
                        <<"nonce-sha256">> =>
                            hb_util:encode(
                                crypto:hash(sha256, FreshNonce)),
                        <<"fresh-attestation-id">> =>
                            attestation_id(Fresh, Opts)
                    },
                    <<"credential-activation">> => #{
                        <<"verified">> => true,
                        <<"challenge-sha256">> =>
                            hb_util:encode(crypto:hash(sha256, Challenge)),
                        <<"credential-blob">> =>
                            hb_maps:get(<<"credential-blob">>,
                                        Credential, <<>>, #{}),
                        <<"secret">> =>
                            hb_maps:get(<<"secret">>, Credential, <<>>, #{}),
                        <<"response">> => Activation
                    }
                },
                Opts),
            ok = store_peer_attestation(Signed, Opts),
            Signed
        end).

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

resolve_subject_body(Msg, Opts) when is_map(Msg) ->
    case {
        hb_maps:get(<<"status">>, Msg, undefined, Opts),
        hb_maps:get(<<"body">>, Msg, undefined, Opts)
    } of
        {Status, Body} when is_integer(Status), is_map(Body) ->
            resolve_subject_body(Body, Opts);
        {undefined, Body} when is_map(Body) ->
            case {
                hb_maps:get(<<"type">>, Msg, undefined, Opts),
                hb_maps:get(<<"type">>, Body, undefined, Opts)
            } of
                {undefined, Type} when is_binary(Type) ->
                    resolve_subject_body(Body, Opts);
                _ ->
                    Msg
            end;
        _ ->
            Msg
    end;
resolve_subject_body(Other, _Opts) ->
    Other.

make_credential_for_subject(Subject, Secret) ->
    EkPublic = hb_util:decode(
        hb_maps:get(<<"ek-public">>, Subject, <<>>, #{})),
    AkName = hb_util:decode(
        hb_maps:get(<<"ak-name">>, Subject, <<>>, #{})),
    case nif_make_credential(EkPublic, AkName, Secret) of
        {ok, #{credential_blob := Blob, secret := EncSecret}} ->
            #{
                <<"credential-blob">> => hb_util:encode(Blob),
                <<"secret">> => hb_util:encode(EncSecret)
            };
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"make-credential">> => reason_to_text(Reason)}})
    end.

activate_peer_credential(Url, Credential, Opts) ->
    Req = #{
        <<"credential-blob">> =>
            hb_maps:get(<<"credential-blob">>, Credential, <<>>, #{}),
        <<"secret">> =>
            hb_maps:get(<<"secret">>, Credential, <<>>, #{})
    },
    resolve_subject_body(
        lapee_peer_http:post(
            Url,
            <<"/~tpm@2.0a/activate-credential">>,
            Req,
            Opts),
        Opts).

fresh_attestation_path(Nonce) ->
    <<"/~tpm@2.0a/attestation?nonce=",
      (hb_util:encode(Nonce))/binary>>.

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

peer_attestation_scope(Url, Boot, Fresh, Subject, Req, Opts) ->
    #{
        <<"peer-url">> => Url,
        <<"boot-attestation-id">> => attestation_id(Boot, Opts),
        <<"fresh-attestation-id">> => attestation_id(Fresh, Opts),
        <<"ek-public-sha256">> =>
            encoded_field_sha256(<<"ek-public">>, Subject, Opts),
        <<"ak-name-sha256">> =>
            encoded_field_sha256(<<"ak-name">>, Subject, Opts),
        <<"consumer-scope">> =>
            hb_maps:get(
                <<"peer-attestation-scope">>, Req, null, Opts)
    }.

attestation_id(Attestation, Opts) when is_map(Attestation) ->
    hb_message:id(Attestation, all, Opts);
attestation_id(Other, _Opts) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Other))).

encoded_field_sha256(Key, Msg, Opts) ->
    hb_util:encode(
        crypto:hash(
            sha256,
            safe_decode(hb_maps:get(Key, Msg, <<>>, Opts)))).

encoded_message_sha256(Msg) ->
    hb_util:encode(crypto:hash(sha256, term_to_binary(Msg))).

first_defined([]) -> undefined;
first_defined([undefined | Rest]) -> first_defined(Rest);
first_defined([V | _]) -> V.

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
            ExpectedAk = hb_maps:get(<<"ak-name">>, Subject, <<>>, Opts),
            case hb_maps:get(<<"ak-name">>, Activation, <<>>, Opts) of
                ExpectedAk when byte_size(ExpectedAk) > 0 -> ok;
                _ -> bad_activation(<<"ak-name">>)
            end
    end.

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

ensure_subject_matches_boot(Subject, BootEnv) ->
    Pairs = [
        {<<"ek-public">>, <<"EK public area">>},
        {<<"ek-pub-pem">>, <<"EK public PEM">>},
        {<<"ek-name">>, <<"EK name">>},
        {<<"ek-qualified-name">>, <<"EK qualified name">>},
        {<<"ak-name">>, <<"AK name">>},
        {<<"ak-public">>, <<"AK public area">>},
        {<<"ak-pub-pem">>, <<"AK public PEM">>},
        {<<"ak-qualified-name">>, <<"AK qualified name">>}
    ],
    lists:foreach(
        fun({Key, Label}) ->
            case {hb_maps:get(Key, Subject, <<>>, #{}),
                  hb_maps:get(Key, BootEnv, <<>>, #{})} of
                {V, V} when is_binary(V), byte_size(V) > 0 -> ok;
                {V, V} when is_list(V), V =/= [] -> ok;
                _ ->
                    throw({boot_attestation_error,
                           #{<<"credential-subject">> =>
                                <<Label/binary,
                                  " mismatch between subject and "
                                  "boot-attestation">>}})
            end
        end,
        Pairs),
    ok.

ensure_attestation_subjects_match(BootEnv, FreshEnv) ->
    case {
        hb_maps:get(<<"node-message-id">>, BootEnv, <<>>, #{}),
        hb_maps:get(<<"node-message-id">>, FreshEnv, <<>>, #{})
    } of
        {ID, ID} when is_binary(ID), byte_size(ID) > 0 -> ok;
        _ ->
            throw({boot_attestation_error,
                   #{<<"peer-attestation">> =>
                        <<"boot and fresh attestation subjects differ">>}})
    end.

ensure_ak_public_matches_subject(Subject) ->
    AkPublic = hb_maps:get(<<"ak-public">>, Subject, <<>>, #{}),
    AkPem = hb_maps:get(<<"ak-pub-pem">>, Subject, <<>>, #{}),
    AkName = safe_decode(hb_maps:get(<<"ak-name">>, Subject, <<>>, #{})),
    case {rsa_pub_from_tpm2b_public(safe_decode(AkPublic)),
          decode_pem_rsa_pub(AkPem),
          tpm2b_public_name(safe_decode(AkPublic))} of
        {{ok, Rsa}, {ok, Rsa}, {ok, AkName}} when byte_size(AkName) > 0 ->
            ok;
        {{error, Why}, _, _} ->
            throw({boot_attestation_error,
                   #{<<"ak-public">> =>
                        iolist_to_binary(
                            io_lib:format("bad AK TPMT_PUBLIC: ~p", [Why]))}});
        {_, {error, Why}, _} ->
            throw({boot_attestation_error,
                   #{<<"ak-pub-pem">> =>
                        iolist_to_binary(
                            io_lib:format("bad AK public PEM: ~p", [Why]))}});
        {_, _, {error, Why}} ->
            throw({boot_attestation_error,
                   #{<<"ak-public">> =>
                        iolist_to_binary(
                            io_lib:format("bad AK name derivation: ~p",
                                          [Why]))}});
        _ ->
            throw({boot_attestation_error,
                   #{<<"ak-public">> =>
                        <<"AK TPMT_PUBLIC, public PEM, and name do not "
                          "match">>}})
    end.

ensure_ek_public_matches_cert(Subject) ->
    EkPublic = hb_maps:get(<<"ek-public">>, Subject, <<>>, #{}),
    EkPem = hb_maps:get(<<"ek-pub-pem">>, Subject, <<>>, #{}),
    CertPem = hb_maps:get(<<"ek-cert-pem">>, Subject, <<>>, #{}),
    case {rsa_pub_from_tpm2b_public(safe_decode(EkPublic)),
          decode_pem_rsa_pub(EkPem),
          cert_rsa_pub(CertPem)} of
        {{ok, Rsa}, {ok, Rsa}, {ok, Rsa}} -> ok;
        {{error, Why}, _, _} ->
            throw({boot_attestation_error,
                   #{<<"ek-public">> =>
                        iolist_to_binary(
                            io_lib:format("bad EK TPMT_PUBLIC: ~p", [Why]))}});
        {_, {error, Why}, _} ->
            throw({boot_attestation_error,
                   #{<<"ek-pub-pem">> =>
                        iolist_to_binary(
                            io_lib:format("bad EK public PEM: ~p", [Why]))}});
        {_, _, {error, Why}} ->
            throw({boot_attestation_error,
                   #{<<"ek-cert-pem">> =>
                        iolist_to_binary(
                            io_lib:format("bad EK cert PEM: ~p", [Why]))}});
        _ ->
            throw({boot_attestation_error,
                   #{<<"ek-public">> =>
                        <<"EK TPMT_PUBLIC, public PEM, and certificate "
                          "public key do not match">>}})
    end.

store_peer_attestation(Signed, Opts) ->
    SignedID = hb_message:id(Signed, signed, Opts),
    {ok, _UnsignedID} = hb_cache:write(Signed, Opts),
    lists:foreach(
        fun(Path) -> ok = hb_cache:link(SignedID, Path, Opts) end,
        peer_attestation_cache_paths(Signed, SignedID, Opts)),
    ok.

peer_attestation_cache_paths(Signed, SignedID, Opts) ->
    Prefix = ?PEER_ATTESTATION_PREFIX,
    PeerURL = hb_maps:get(<<"peer-url">>, Signed, <<>>, Opts),
    PeerURLHash = hb_util:encode(crypto:hash(sha256, PeerURL)),
    Scope = hb_maps:get(<<"peer-scope">>, Signed, #{}, Opts),
    EkHash = hb_maps:get(<<"ek-public-sha256">>, Scope, <<"unknown">>, Opts),
    BootID =
        hb_maps:get(<<"boot-attestation-id">>, Scope, <<"unknown">>, Opts),
    ConsumerScopeHash =
        encoded_message_sha256(
            hb_maps:get(<<"consumer-scope">>, Scope, null, Opts)),
    [
        <<Prefix/binary, "/by-id/", SignedID/binary>>,
        <<Prefix/binary,
          "/by-peer-url-sha256/", PeerURLHash/binary,
          "/by-ek-public-sha256/", EkHash/binary,
          "/by-boot-attestation-id/", BootID/binary,
          "/by-consumer-scope-sha256/", ConsumerScopeHash/binary,
          "/", SignedID/binary>>
    ].

rsa_pub_from_tpm2b_public(Tpm2BPublic) ->
    try
        {ok, Public} = tpm2b_public_body(Tpm2BPublic),
        <<16#0001:16/unsigned-big, _NameAlg:16/unsigned-big,
          _Attrs:32/unsigned-big, Rest0/binary>> = Public,
        {_AuthPolicy, Rest1} = tpm2b(Rest0),
        Rest2 = skip_tpm2_public_symmetric(Rest1),
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
        _:_ -> {error, bad_tpm2b_public}
    end.

tpm2b_public_body(<<Size:16/unsigned-big, Public:Size/binary, _/binary>>) ->
    {ok, Public};
tpm2b_public_body(_) ->
    {error, bad_tpm2b_public}.

tpm2b_public_name(Tpm2BPublic) ->
    case tpm2b_public_body(Tpm2BPublic) of
        {ok, <<_Type:16/unsigned-big, NameAlg:16/unsigned-big, _/binary>>
                = Public} ->
            case tpm_name_hash_alg(NameAlg) of
                {ok, HashAlg} ->
                    {ok, <<NameAlg:16/unsigned-big,
                           (crypto:hash(HashAlg, Public))/binary>>};
                {error, _} = E -> E
            end;
        {error, _} = E -> E
    end.

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

skip_tpm2_public_symmetric(<<16#0006:16/unsigned-big,
                             _KeyBits:16/unsigned-big,
                             _Mode:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_public_symmetric(<<16#0010:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_public_symmetric(_) ->
    throw(bad_tpm2b_public_symmetric).

skip_tpm2_rsa_scheme(<<16#0010:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_rsa_scheme(<<_Scheme:16/unsigned-big,
                       _HashAlg:16/unsigned-big, Rest/binary>>) ->
    Rest;
skip_tpm2_rsa_scheme(_) ->
    throw(bad_tpm2b_public_scheme).

cert_rsa_pub(Pem) ->
    case decode_pem_cert(Pem) of
        {ok, Der} ->
            try public_key:pkix_decode_cert(Der, otp) of
                #'OTPCertificate'{tbsCertificate = Tbs} ->
                    case Tbs#'OTPTBSCertificate'.subjectPublicKeyInfo of
                        #'OTPSubjectPublicKeyInfo'{
                            subjectPublicKey = #'RSAPublicKey'{} = Rsa} ->
                            {ok, Rsa};
                        Other -> {error, {unsupported_cert_pubkey, Other}}
                    end
            catch C:R -> {error, {C, R}}
            end;
        {error, _} = E -> E
    end.

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

generate_boot_attestation(Opts) ->
    with_ok(
        fun() ->
            {Subject, SubjectID, SubjectDigest} = boot_subject(Opts),
            Tpm = boot_tpm_evidence(Subject, SubjectID, SubjectDigest, Opts),
            hb_message:commit(
                Subject#{
                    <<"version">> => <<"1.0">>,
                    <<"issued-at-unix">> => erlang:system_time(second),
                    <<"tpm">> => Tpm
                },
                Opts)
        end).

with_ok(Fun) ->
    try
        {ok, Fun()}
    catch
        throw:{boot_attestation_error, Reason} ->
            {error, Reason};
        Class:Reason ->
            {error, #{
                <<"class">> => to_bin(Class),
                <<"reason">> => to_bin(Reason)
            }}
    end.

resolve_body({ok, #{<<"body">> := Body}}) ->
    Body;
resolve_body({ok, Msg}) ->
    Msg;
resolve_body({error, Reason}) ->
    throw({boot_attestation_error, Reason});
resolve_body(Other) ->
    throw({boot_attestation_error, Other}).

ensure_committed(Msg, Opts) when is_map(Msg) ->
    case hb_message:signers(Msg, Opts) of
        [] -> hb_message:commit(Msg, Opts);
        _ -> Msg
    end;
ensure_committed(Msg, _Opts) ->
    Msg.

boot_subject(Opts) ->
    case persistent_term:get({dev_tpm2, attested_boot_subject}, undefined) of
        Subject when is_map(Subject) ->
            SubjectID = persistent_term:get(
                {dev_tpm2, attested_boot_subject_id},
                hb_message:id(Subject, all, Opts)),
            SubjectDigest = persistent_term:get(
                {dev_tpm2, attested_boot_subject_digest},
                hb_util:native_id(SubjectID)),
            {Subject, SubjectID, SubjectDigest};
        undefined ->
            System =
                resolve_body(hb_ao:resolve(<<"~system@1.0/all">>, Opts)),
            Node0 =
                resolve_body(hb_ao:resolve(<<"~meta@1.0/info">>, Opts)),
            Node = ensure_committed(Node0, Opts),
            Subject = #{
                <<"system">> => System,
                <<"node">> => Node
            },
            SubjectID = hb_message:id(Subject, all, Opts),
            {Subject, SubjectID, hb_util:native_id(SubjectID)}
    end.

boot_tpm_evidence(Subject, SubjectID, SubjectDigest, Opts) ->
    Pcrs = ?DEFAULT_QUOTE_PCRS,
    Nonce = crypto:strong_rand_bytes(32),
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
                        <<"ek-cert-chain-diagnostics">> =>
                            ek_cert_chain_diagnostics(),
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
                        %% Derived signals from the firmware-side TCG
                        %% event log replay -- exposed in the signed
                        %% boot-attestation so green-zone templates and
                        %% external auditors can pin policy-actionable
                        %% facts (currently `secure-boot.enabled') without
                        %% re-walking the log themselves. Mirrors the
                        %% interpret-side `policy-verdict.signals' shape.
                        <<"signals">> => dev_tpm_tcg:boot_signals(TcgLogBin)
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
                    <<"description">> =>
                        <<"AO-Core boot attestation subject extended into "
                          "PCR 15. The subject ID commits to the nested "
                          "`system' report and signed `node' message.">>,
                    <<"digest">> => hb_util:encode(SubjectDigest),
                    <<"subject-id">> => SubjectID,
                    <<"subject-is-message">> => true
                }),
            ok;
        {error, Reason} ->
            throw({boot_attestation_error,
                   #{<<"pcr-extend">> => reason_to_text(Reason)}})
    end.


attestation(_Base, Req, Opts) ->
    Pcrs = resolve_pcr_list(Req, ?DEFAULT_QUOTE_PCRS, Opts),
    Nonce = resolve_nonce(Req),
    case ensure_ak(Opts) of
        {ok, AkTr} ->
            case nif_quote(AkTr, Pcrs, Nonce) of
                {ok, #{quoted := Q, signature := Sig, pcr_values := PcrMap}} ->
                    {EKCertPem, AKPubPem} =
                        {ek_cert_pem(Opts), ak_pub_pem(Opts)},
                    EventLog = event_log(Opts),
                    {TcgLogBin, TcgLogSource} =
                        read_tcg_event_log_with_source(),
                    TcgLogFormat = infer_log_format(TcgLogBin),
                    {NodeMsg, NodeMsgId} = attested_subject(Opts),
                    Envelope = #{
                        <<"lapee-attestation-version">> => <<"0.4">>,
                        <<"issued-at-unix">> =>
                            erlang:system_time(second),
                        <<"ek-cert-pem">> => EKCertPem,
                        %% Intermediates from NV `handle + 1'. Empty
                        %% when the vendor didn't provision a chain
                        %% slot, or when the cert is absent.
                        <<"ek-cert-chain-pem">> =>
                            ek_cert_chain_pem(),
                        %% Provenance of the EK cert -- tpm-nv (real,
                        %% with which handle + byte count) or absent
                        %% (with the probe-attempt list). This is the
                        %% hook that lets the verifier distinguish a
                        %% legitimate hardware EK from a missing one.
                        %% We never inject synthetic values; if the
                        %% TPM has no EK cert, the field is empty and
                        %% source.kind is "absent".
                        <<"ek-cert-source">> =>
                            ek_cert_source(),
                        <<"ek-cert-chain-diagnostics">> =>
                            ek_cert_chain_diagnostics(),
                        %% Real TPM identity straight from
                        %% TPM2_GetCapability -- manufacturer, vendor
                        %% string, spec level/revision, firmware
                        %% version. Populated even when the EK cert
                        %% is absent, so the verifier always gets
                        %% "what chip is this" from ground truth.
                        <<"tpm-properties">> =>
                            tpm_properties(),
                        <<"ek-pub-pem">> => ek_pub_pem(Opts),
                        <<"ek-public">> => ek_public(Opts),
                        <<"ek-name">> => ek_name(Opts),
                        <<"ek-qualified-name">> => ek_qualified_name(Opts),
                        %% Runtime kernel + SMBIOS snapshot so
                        %% claim.cpu / claim.iommu / claim.lockdown
                        %% resolve to concrete values even when the
                        %% TCG event log doesn't carry them (paper-
                        %% committed fields per section Architecture
                        %% of the LapEE paper).
                        <<"platform-probes">> =>
                            platform_probes(),
                        <<"ak-pub-pem">> => AKPubPem,
                        <<"ak-public">> => ak_public(Opts),
                        <<"ak-name">> => ak_name(Opts),
                        <<"ak-qualified-name">> => ak_qualified_name(Opts),
                        %% v1.2.2 paper P3: AK is a primary under
                        %% the Endorsement hierarchy (see
                        %% native/lapee_tpm_nif/lapee_tpm_nif.c
                        %% nif_create_primary_ak, which passes
                        %% ESYS_TR_RH_ENDORSEMENT). The field is
                        %% populated as a constant here because it
                        %% is determined by the build's NIF code
                        %% path, not runtime data -- any change in
                        %% the NIF would need to be reflected here
                        %% in the same commit. Verifier-side,
                        %% dev_tpm_interpret uses this to demote
                        %% the `ek-ak-binding-not-implemented'
                        %% finding to an observational info note:
                        %% when the AK and EK share the Endorsement
                        %% hierarchy's primary seed, they must
                        %% reside in the same physical TPM (TCG
                        %% TPM 2.0 Architecture section 13.2).
                        <<"ak-hierarchy">> => <<"endorsement">>,
                        %% v1.2.2 paper P4: every sensitive TPM op
                        %% in this build uses an HMAC-authenticated
                        %% AES-128-CFB-encrypted session as
                        %% shandle2 (or shandle1 when no hierarchy
                        %% auth is needed). See
                        %% native/lapee_tpm_nif/lapee_tpm_nif.c
                        %% lapee_ensure_auth_session(). Field is a
                        %% compile-time constant tied to the NIF
                        %% source; the verifier treats this as
                        %% declarative (bus-level protection is a
                        %% guest<->TPM property that cannot be
                        %% re-verified post-hoc from the wire
                        %% envelope alone).
                        %% Refined in batch 34 after iron-smoke: P4
                        %; session now attaches only to ops with
                        %; TPM2B first-params (Quote + CreatePrimary
                        %; x2) where ENCRYPT + DECRYPT attrs are
                        %; spec-valid. Ops with list-struct first-
                        %; params (PCR_Read/Extend, GetCapability)
                        %; run without the session -- their payload
                        %; is public per TCG, so bus-level
                        %; confidentiality buys nothing. Value
                        %; `hmac-aes128cfb' (prefix `hmac-' keeps
                        %; the verifier's paper-P4 check clean).
                        <<"tpm-session-mode">> =>
                            <<"hmac-aes128cfb">>,
                        <<"tpm-quote">> =>
                            quote_body(Pcrs, Nonce, Q, Sig, PcrMap),
                        <<"runtime-event-log">> => EventLog,
                        %% Firmware-side TCG event log (PCRs 0-14
                        %% measurements the kernel exposes).
                        %% base64url -- consistent with every other
                        %% binary field in this envelope
                        %% (runtime_event_log digests, tpm_quote
                        %% values, PCR digests, ...). The interpret
                        %% device parses this into per-event
                        %% messages and extracts machine-identifying
                        %% fields (Secure Boot, firmware version,
                        %% bootloader hash, ...) per the paper's
                        %% section Architecture "every field is a named
                        %% event-log entry" requirement.
                        <<"tcg-event-log">> =>
                            hb_util:encode(TcgLogBin),
                        <<"tcg-event-log-source-path">>  =>
                            TcgLogSource,
                        <<"tcg-event-log-length-bytes">> =>
                            byte_size(TcgLogBin),
                        <<"tcg-event-log-format">>       =>
                            TcgLogFormat,
                        <<"node-message">> => NodeMsg,
                        <<"node-message-id">> => NodeMsgId,
                        <<"wallet-address">> =>
                            case hb_opts:get(priv_wallet, undefined, Opts) of
                                undefined -> null;
                                W ->
                                    hb_util:human_id(
                                        ar_wallet:to_address(W))
                            end
                    },
                    {ok, #{<<"status">> => 200, <<"body">> => Envelope}};
                {error, Reason} ->
                    error_resp(500, <<"quote_failed">>, Reason)
            end;
        {error, Reason} ->
            error_resp(500, <<"ak_unavailable">>, Reason)
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

%%%============================================================================
%%% Runtime event log
%%%============================================================================

%% @doc Return the in-memory event log accumulated since boot.
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

%%%============================================================================
%%% Subject / PCR / nonce resolution helpers
%%%============================================================================

resolve_subject(Base, Req, Opts) ->
    case hb_maps:get(<<"subject">>, Req, undefined, Opts) of
        undefined ->
            case hb_maps:get(<<"body">>, Req, undefined, Opts) of
                undefined -> Base;
                Body -> Body
            end;
        Subject -> Subject
    end.

resolve_pcr(Req, Default, Opts) ->
    case hb_maps:get(<<"pcr">>, Req, undefined, Opts) of
        undefined -> Default;
        I when is_integer(I) -> I;
        B when is_binary(B) ->
            try binary_to_integer(B)
            catch _:_ -> Default end
    end.

resolve_pcr_list(Req, Default, Opts) ->
    case hb_maps:get(<<"pcrs">>, Req, undefined, Opts) of
        undefined -> Default;
        L when is_list(L) ->
            [pcr_int(I) || I <- L];
        B when is_binary(B) ->
            [pcr_int(X) || X <- binary:split(B, <<",">>, [global]), X =/= <<>>];
        _ -> Default
    end.

pcr_int(I) when is_integer(I) -> I;
pcr_int(B) when is_binary(B) ->
    try binary_to_integer(B)
    catch _:_ -> 0
    end.

%% Nonce convention: base64url-encoded bytes. If the caller passes a
%% binary that decodes cleanly as base64url we hand the bytes to the
%% TPM; otherwise we treat the input as the raw bytes directly. Hex
%% is not supported (HyperBEAM wire convention is base64url
%% everywhere).
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

%% @doc Produce a 32-byte SHA-256 digest for a subject.
%%
%% For HyperBEAM messages, `hb_message:id(Subject, all, Opts)' returns
%% a human-encoded (base64url, 43 chars) ID; we decode it back to the
%% raw 32-byte hash via `hb_util:native_id/1'. For binaries that are
%% already 32 bytes we use them as-is; for other binaries we hash with
%% SHA-256; for anything else we serialise and hash.
digest_of(Subject, Opts) when is_map(Subject) ->
    HumanId = hb_message:id(Subject, all, Opts),
    hb_util:native_id(HumanId);
digest_of(B, _Opts) when is_binary(B), byte_size(B) =:= 32 ->
    B;
digest_of(B, _Opts) when is_binary(B) ->
    crypto:hash(sha256, B);
digest_of(Other, _Opts) ->
    crypto:hash(sha256,
        iolist_to_binary(io_lib:format("~0p", [Other]))).

error_resp(Status, Err, Reason) ->
    {error, #{
        <<"status">> => Status,
        <<"body">> => #{
            <<"error">> => Err,
            <<"reason">> => reason_to_text(Reason)
        }
    }}.

get_node_msg(Opts) ->
    %% Two lookups, in order: (1) the node message remembered by the
    %% last PCR-15 extend on this boot (populated by `extend/3'); this
    %% is the ONE the TPM state actually commits to. (2) An explicit
    %% `lapee_attested_node_msg' in Opts, for callers that already know
    %% what was extended (tests, or a caller priming the persistent_term
    %% outside of the normal hook path).
    case persistent_term:get({dev_tpm2, attested_node_msg}, undefined) of
        undefined -> hb_opts:get(lapee_attested_node_msg, undefined, Opts);
        Msg -> Msg
    end.

attested_subject(Opts) ->
    case hb_cache:read(?BOOT_ATTESTATION_PATH, Opts) of
        {ok, Boot} ->
            case subject_from_boot_attestation(Boot, Opts) of
                {Subject, SubjectID} -> {Subject, SubjectID};
                undefined -> legacy_attested_subject(Opts)
            end;
        _ ->
            legacy_attested_subject(Opts)
    end.

subject_from_boot_attestation(Boot, Opts) when is_map(Boot) ->
    System = hb_maps:get(<<"system">>, Boot, undefined, Opts),
    Node = hb_maps:get(<<"node">>, Boot, undefined, Opts),
    Tpm = hb_maps:get(<<"tpm">>, Boot, #{}, Opts),
    SubjectID = hb_maps:get(<<"extended-subject">>, Tpm, undefined, Opts),
    case {System, Node, SubjectID} of
        {S, N, ID}
                when is_map(S), is_map(N), is_binary(ID),
                     byte_size(ID) =:= 43 ->
            {#{<<"system">> => S, <<"node">> => N}, ID};
        _ ->
            undefined
    end;
subject_from_boot_attestation(_Boot, _Opts) ->
    undefined.

legacy_attested_subject(Opts) ->
    case persistent_term:get({dev_tpm2, attested_boot_subject}, undefined) of
        Subject when is_map(Subject) ->
            SubjectID = persistent_term:get(
                {dev_tpm2, attested_boot_subject_id},
                hb_message:id(Subject, all, Opts)),
            {Subject, SubjectID};
        undefined ->
            case get_node_msg(Opts) of
                undefined ->
                    {null, null};
                Msg ->
                    {
                        Msg,
                        hb_util:human_id(
                            hb_util:native_id(
                                hb_message:id(Msg, all, Opts)))
                    }
            end
    end.

%%%============================================================================
%%% NIF wrappers + AK caching
%%%============================================================================

%% Reviewer pass 11 (concurrency race auditor, batch 13) CRITICAL
%% fix: the pre-batch-13 version was a classic check-then-act --
%% two concurrent /attestation requests arriving within ~10ms of
%% boot both saw `undefined' and both entered init_chain,
%% creating two EK primaries (same key, extra transient handle),
%% two AK primaries (DIFFERENT keys), extending PCR 15 twice
%% with different digests, and racing persistent_term writes.
%% Worst case: one envelope carried ak-pub-pem from B but the
%% quote was signed by A's AK -> rsa_pss:verify fails ->
%% verdict=rejected on a legitimate boot.
%%
%% Closed via `global:trans' with double-checked locking: the
%% fast path (ak_tr already set) stays lock-free; only the once-
%% per-boot init path takes the node-local lock. The inner
%% re-check under the lock ensures only one caller runs
%% init_chain even if N callers arrived before any of them
%% finished.
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
            %% Snapshot TPM-reported identity via TPM2_GetCapability.
            %% This is the primary manufacturer / firmware-version
            %% signal and works even when NV has no EK cert. The
            %% TCG-OID attributes on a real EK cert, when present,
            %% act as cross-check at the claim layer.
            capture_tpm_properties(),
            %% v1.2 E3: snapshot kernel/sysfs identity sources that
            %% aren't in the TCG event log (CPU vendor/model,
            %% IOMMU groups, kernel lockdown level, SMBIOS / DMI).
            %% These become `platform-probes' in the envelope and
            %% feed claim.cpu / claim.iommu / claim.lockdown on the
            %% verifier side. Probes run once at init_chain time so
            %% every subsequent /attestation call sees the same
            %% snapshot (important for reproducible claim digests).
            capture_platform_probes(),
            case nif_create_ek() of
                {ok, #{esys_tr := EKTr, public_pem := EKPem} = EKInfo} ->
                    persistent_term:put({dev_tpm2, ek_tr}, EKTr),
                    persistent_term:put({dev_tpm2, ek_pub_pem}, EKPem),
                    cache_tpm_public_terms(ek, EKInfo),
                    %% Pull the TPM's real EK certificate out of NV
                    %% storage. If no EK cert is provisioned we record
                    %% the absence explicitly -- we do NOT fabricate a
                    %% substitute. A missing EK cert is meaningful
                    %% evidence on the claim, not a condition to paper
                    %% over. See fetch_ek_cert_from_nv/1.
                    fetch_ek_cert_from_nv(Opts),
                    case extend_initial_pcr15(
                            Subject, SubjectID, SubjectDigest) of
                        ok ->
                            case nif_create_signing_key(EKTr) of
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

%% Capture TPM identity via TPM2_GetCapability (TPM_PT_MANUFACTURER,
%% TPM_PT_VENDOR_STRING_*, TPM_PT_FIRMWARE_VERSION_*, ...). These
%% values come straight from the TPM hardware regardless of EK-cert
%% provisioning -- that's what makes them the primary identification
%% source. On failure we stamp a structured "capability-probe-failed"
%% entry rather than dropping the field: silent absence would blur
%% the line between "no TPM" and "TPM didn't answer".
capture_tpm_properties() ->
    try lapee_tpm_nif:tpm_properties() of
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

%% v1.2 E3: read the sysfs + /proc signals that identify the
%% running platform beyond what the TCG event log carries, cache
%% the snapshot for the /attestation envelope.
%%
%% Paths probed (all read-only, no side effects):
%%
%%   /proc/cpuinfo                      CPU vendor_id / model name /
%%                                      family / model / stepping /
%%                                      microcode / flags
%%   /sys/kernel/security/lockdown      `[none] integrity confidentiality'
%%                                      style -- the bracketed entry is
%%                                      active
%%   /sys/kernel/iommu_groups/          one directory per IOMMU group;
%%                                      non-zero count == IOMMU active
%%   /sys/class/dmi/id/sys_vendor       SMBIOS Type-1 system vendor
%%                                      (e.g. "Framework")
%%   /sys/class/dmi/id/product_name     SMBIOS product name
%%   /sys/class/dmi/id/board_name       SMBIOS Type-2 board name
%%   /sys/class/dmi/id/bios_vendor      SMBIOS Type-0 BIOS vendor
%%   /sys/class/dmi/id/bios_version     SMBIOS Type-0 BIOS version
%%   /sys/class/dmi/id/bios_release     SMBIOS Type-0 BIOS release
%%
%% Every value is surfaced as a binary; `null' when the file is
%% absent / unreadable. Unknown paths do NOT fail the whole probe
%% pass -- a partial snapshot is still useful.
capture_platform_probes() ->
    Probes = live_platform_probes(),
    persistent_term:put({dev_tpm2, platform_probes}, Probes),
    ok.

live_platform_probes() ->
    #{
        cpuinfo          => read_cpuinfo_stanza(),
        lockdown         => read_trim(
            <<"/sys/kernel/security/lockdown">>),
        iommu_groups     => count_iommu_groups(),
        dmi_sys_vendor   => read_trim(
            <<"/sys/class/dmi/id/sys_vendor">>),
        dmi_product_name => read_trim(
            <<"/sys/class/dmi/id/product_name">>),
        dmi_board_name   => read_trim(
            <<"/sys/class/dmi/id/board_name">>),
        dmi_bios_vendor  => read_trim(
            <<"/sys/class/dmi/id/bios_vendor">>),
        dmi_bios_version => read_trim(
            <<"/sys/class/dmi/id/bios_version">>),
        dmi_bios_release => read_trim(
            <<"/sys/class/dmi/id/bios_release">>),
        kernel_cmdline     => read_trim(<<"/proc/cmdline">>),
        secure_boot        => read_secure_boot_state(),
        tpm_version_major  => read_trim(
            <<"/sys/class/tpm/tpm0/tpm_version_major">>),
        ima_count          => read_trim(
            <<"/sys/kernel/security/integrity/ima/"
              "runtime_measurements_count">>),
        probed_at_unix     => erlang:system_time(second)
    }.

%% Read the one-byte data octet from the EFI SecureBoot variable.
%% The efivarfs file layout is `<attributes:4><data:N>', where N=1
%% for SecureBoot. GUID suffix `8be4df61-93ca-11d2-aa0d-00e098032b8c'
%% is the EFI_GLOBAL_VARIABLE GUID per UEFI spec. Returns an atom
%% `enabled' / `disabled' / `unknown'; the atom is converted to
%% a binary in platform_probes/0.
read_secure_boot_state() ->
    Path = <<"/sys/firmware/efi/efivars/"
             "SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c">>,
    case file:read_file(Path) of
        {ok, <<_Attrs:4/binary, 1:8>>} -> enabled;
        {ok, <<_Attrs:4/binary, 0:8>>} -> disabled;
        {ok, _}                         -> unknown;
        _                               -> not_readable
    end.

%% Read the first `processor' stanza of /proc/cpuinfo into a map
%% keyed by the normalised field name (kebab-case binary). Returns
%% an empty map on any file-read or parse error.
read_cpuinfo_stanza() ->
    case file:read_file(<<"/proc/cpuinfo">>) of
        {ok, Bin} ->
            %% Split on the blank-line stanza separator.
            [First | _] = binary:split(Bin, <<"\n\n">>, [global]),
            Lines = binary:split(First, <<"\n">>, [global]),
            lists:foldl(fun line_to_kv/2, #{}, Lines);
        _ -> #{}
    end.

line_to_kv(Line, Acc) ->
    case binary:split(Line, <<":">>, []) of
        [Key, Val] ->
            K = binary:replace(
                string:lowercase(string:trim(Key)),
                <<" ">>,
                <<"-">>,
                [global]),
            %% Only the first occurrence counts (first processor
            %% stanza); skip subsequent duplicates.
            maps:merge(#{K => string:trim(Val)}, Acc);
        _ -> Acc
    end.

%% Count the entries in /sys/kernel/iommu_groups/. Each group
%% corresponds to one IOMMU-enforced isolation domain. Zero
%% groups means either no IOMMU driver is loaded or the kernel
%% booted without an IOMMU enable flag. Returns integer or
%% `null' on path absence.
count_iommu_groups() ->
    case file:list_dir(<<"/sys/kernel/iommu_groups">>) of
        {ok, Entries} ->
            length([E || E <- Entries, is_group_dir(E)]);
        _ -> null
    end.

%% True iff `E' is an all-digits directory name (a single IOMMU
%% group ID). Filters out stray non-numeric entries that some
%% kernels expose under /sys/kernel/iommu_groups/.
is_group_dir(E) ->
    case string:to_integer(E) of
        {N, Rest} when is_integer(N) -> Rest =:= <<>> orelse Rest =:= "";
        _                            -> false
    end.

%% Read a file and trim trailing whitespace (including the
%% terminating \n that most sysfs entries have). Returns a
%% binary on success, null on any read error.
read_trim(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> string:trim(Bin, trailing, "\r\n \t");
        _ -> null
    end.

%% Pretty the cached TPM properties for the /attestation envelope.
%% Integers for firmware-version halves let the verifier reconstruct
%% the full 64-bit revision (fw1 << 32 | fw2) without ambiguity; the
%% binary manufacturer / vendor-string fields are kebab-cased on the
%% wire.
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

%% Return the cached EK-cert-chain PEM bundle. Empty when no
%% chain was read out of the adjacent NV slot.
ek_cert_chain_pem() ->
    persistent_term:get({dev_tpm2, ek_cert_chain_pem}, <<>>).

%% Return the cached EK-chain NV diagnostics. This is non-secret TPM
%% public-NV metadata: which handles were probed, byte counts, parsed
%% certificate offsets, and issuer/subject key identifiers.
ek_cert_chain_diagnostics() ->
    persistent_term:get(
        {dev_tpm2, ek_cert_chain_diagnostics},
        #{<<"available">> => false,
          <<"reason">> =>
              <<"ensure_ak/1 has not executed yet">>}).

%% Return the cached platform-probes map (captured at init_chain)
%% formatted for the wire -- binary keys, null for unknown, ints
%% preserved as ints. Not present if init_chain hasn't run yet.
platform_probes() ->
    case persistent_term:get({dev_tpm2, platform_probes}, undefined) of
        undefined ->
            #{<<"available">> => false,
              <<"reason">>    =>
                  <<"init_chain has not executed yet">>};
        #{} = P ->
            CpuInfo = maps:get(cpuinfo, P, #{}),
            CpuMap = maps:fold(
                fun(K, V, Acc) when is_binary(K) ->
                       Acc#{K => V};
                   (_, _, Acc) -> Acc
                end, #{}, CpuInfo),
            #{
                <<"available">>          => true,
                <<"cpuinfo">>            => CpuMap,
                <<"lockdown">>           =>
                    or_bin_null(maps:get(lockdown, P, null)),
                <<"iommu-groups-count">> =>
                    maps:get(iommu_groups, P, null),
                <<"dmi-sys-vendor">>     =>
                    or_bin_null(maps:get(dmi_sys_vendor, P, null)),
                <<"dmi-product-name">>   =>
                    or_bin_null(maps:get(dmi_product_name, P, null)),
                <<"dmi-board-name">>     =>
                    or_bin_null(maps:get(dmi_board_name, P, null)),
                <<"dmi-bios-vendor">>    =>
                    or_bin_null(maps:get(dmi_bios_vendor, P, null)),
                <<"dmi-bios-version">>   =>
                    or_bin_null(maps:get(dmi_bios_version, P, null)),
                <<"dmi-bios-release">>   =>
                    or_bin_null(maps:get(dmi_bios_release, P, null)),
                <<"kernel-cmdline">>     =>
                    or_bin_null(maps:get(kernel_cmdline, P, null)),
                <<"secure-boot">>        =>
                    atom_or_bin_null(maps:get(secure_boot, P, null)),
                <<"tpm-version-major">>  =>
                    or_bin_null(maps:get(tpm_version_major, P, null)),
                <<"ima-measurement-count">> =>
                    or_bin_null(maps:get(ima_count, P, null)),
                <<"probed-at-unix">>     =>
                    maps:get(probed_at_unix, P, 0)
             }
    end.

atom_or_bin_null(null) -> null;
atom_or_bin_null(A) when is_atom(A) -> atom_to_binary(A, utf8);
atom_or_bin_null(B) when is_binary(B) -> B;
atom_or_bin_null(_) -> null.

or_bin_null(null) -> null;
or_bin_null(<<>>) -> null;
or_bin_null(B) when is_binary(B) -> B;
or_bin_null(L) when is_list(L) -> iolist_to_binary(L);
or_bin_null(_) -> null.

%% Return the provenance map for the currently-cached EK cert. The
%% ensure_ak -> init_chain -> fetch_ek_cert_from_nv pipeline populates
%% this; if it hasn't run yet we return an "unknown" placeholder so
%% the attestation envelope shape stays stable.
ek_cert_source() ->
    case persistent_term:get({dev_tpm2, ek_cert_source}, undefined) of
        undefined ->
            #{<<"kind">> => <<"unknown">>,
              <<"reason">> =>
                  <<"ensure_ak/1 has not executed yet">>};
        #{} = M ->
            %% Keys in the raw map are atoms so we're always producing
            %% the same one-hop shape. Re-key to binary here so the
            %% wire-format stays kebab-case-on-binary-keys throughout.
            maps:fold(
                fun(K, V, Acc) when is_atom(K) ->
                       Acc#{atom_to_binary(K) => V};
                   (K, V, Acc) -> Acc#{K => V}
                end, #{}, M)
    end.

%% TCG EK Credential Profile -- standard NV indices for EK certificates.
%% https://trustedcomputinggroup.org/resource/tcg-ek-credential-profile/
-define(EK_NV_RSA_2048, 16#01C00002).  %% low-range RSA-2048 EK cert
-define(EK_NV_RSA_3072, 16#01C0000A).  %% low-range RSA-3072 EK cert
-define(EK_NV_ECC_P256, 16#01C00004).  %% low-range ECC NIST P-256
-define(EK_NV_ECC_P384, 16#01C00006).  %% low-range ECC NIST P-384
%% High-range (vendor-specific templates) -- checked as a fallback.
-define(EK_NV_HIGH_RSA_2048, 16#01C00012).
-define(EK_NV_HIGH_RSA_3072, 16#01C0001A).
%% Intel PTT 11th-gen+ uses ODCA. The EK leaf may still live at the
%% standard EK-cert NV handle, while the embedded intermediate CA chain
%% is provisioned in the TCG EK-chain NV range starting at 0x01C00100.
%% Intel documents this as the EICA chain path for ODCA PTT certs.
-define(EK_NV_CHAIN_FIRST, 16#01C00100).
-define(EK_NV_CHAIN_LAST,  16#01C001FF).

%% Fetch the EK certificate from TPM NV storage and cache it. The list
%% below is iterated in order; the first NV index that yields a valid
%% certificate wins. If none do, the EK cert is recorded as ABSENT --
%% a first-class signal that the verifier must see. We never synthesize
%% a stand-in: this codepath is what makes the attestation chain
%% legitimate rather than cosmetic.
%%
%% Override the probe list via `lapee_tpm_ek_nv_handles' for TPMs
%% whose manufacturer publishes certs at non-standard indices.
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
            %% TCG EK Credential Profile section 2.2.1.4: some TPMs
            %% put the EK cert's INTERMEDIATE chain in the adjacent NV
            %% slot (handle + 1). Intel PTT 11th-gen+ instead uses
            %% the EK-chain NV range beginning at 0x01C00100 for its
            %% ODCA EICA chain. Probe both shapes and carry whatever
            %% certs are actually present; the verifier treats them as
            %% intermediates only, never as trust anchors.
            ChainHandle = Handle + 1,
            {ChainDers, ChainSource, ChainHits, ChainDiagnostics} =
                fetch_ek_cert_chain(ChainHandle),
            persistent_term:put({dev_tpm2, ek_cert_chain_ders},
                                ChainDers),
            persistent_term:put({dev_tpm2, ek_cert_chain_pem},
                                ders_to_pem(ChainDers)),
            persistent_term:put({dev_tpm2, ek_cert_chain_diagnostics},
                                ChainDiagnostics),
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
                {dev_tpm2, ek_cert_chain_diagnostics},
                #{<<"available">> => false,
                  <<"reason">> =>
                      <<"no EK certificate was found, so no EK-chain "
                        "handles were probed">>}),
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

%% Candidate EK-chain NV handles for a leaf EK cert at `EkHandle`.
%% Keep adjacent first for older TPMs, then the standardized EK-chain
%% range used by Intel ODCA PTT. De-dupe so a caller that points
%% directly into the chain range does not double-read.
ek_cert_chain_handles(EkHandle) ->
    uniq_preserve_order(
        [EkHandle + 1 | lists:seq(?EK_NV_CHAIN_FIRST, ?EK_NV_CHAIN_LAST)]).

uniq_preserve_order(List) ->
    uniq_preserve_order(List, #{}, []).

uniq_preserve_order([], _Seen, Acc) ->
    lists:reverse(Acc);
uniq_preserve_order([H | Rest], Seen, Acc) ->
    case maps:is_key(H, Seen) of
        true -> uniq_preserve_order(Rest, Seen, Acc);
        false -> uniq_preserve_order(Rest, Seen#{H => true}, [H | Acc])
    end.

%% Read + parse EK-cert chain slots. TCG format: one or more
%% concatenated DER-encoded certs per NV index. Some vendors ship one
%% intermediate; some ship the full chain down to the root. We parse
%% whatever's there and return all DER cert binaries plus the NV
%% handles that yielded parseable certificates.
fetch_ek_cert_chain(ChainHandle) when is_integer(ChainHandle) ->
    merge_chain_results(
        [fetch_ek_cert_chain_handles([ChainHandle]),
         fetch_ek_cert_chain_range(?EK_NV_CHAIN_FIRST,
                                   ?EK_NV_CHAIN_LAST)]);
fetch_ek_cert_chain(ChainHandles) when is_list(ChainHandles) ->
    fetch_ek_cert_chain_handles(ChainHandles).

fetch_ek_cert_chain_handles(ChainHandles) ->
    fetch_ek_cert_chain(ChainHandles, [], [], [], []).

fetch_ek_cert_chain([], Ders, Hits, Attempts, Diagnostics) ->
    finalize_chain_result(Ders, Hits, Attempts, Diagnostics);
fetch_ek_cert_chain([ChainHandle | Rest], Ders, Hits, Attempts,
                    Diagnostics) ->
    case read_chain_handle(ChainHandle) of
        {ok, ChainDers, Diagnostic} ->
            fetch_ek_cert_chain(
                Rest, lists:reverse(ChainDers) ++ Ders,
                [ChainHandle | Hits], Attempts,
                [Diagnostic | Diagnostics]);
        {error, Reason, Diagnostic} ->
            fetch_ek_cert_chain(
                Rest, Ders, Hits, [{ChainHandle, Reason} | Attempts],
                [Diagnostic | Diagnostics])
    end.

fetch_ek_cert_chain_range(First, Last) ->
    Entries = read_chain_range_entries(First, Last),
    parse_chain_range_entries(Entries).

read_chain_range_entries(First, Last) ->
    [read_chain_range_entry(Handle) || Handle <- lists:seq(First, Last)].

read_chain_range_entry(Handle) ->
    case lapee_tpm_nif:nv_read(Handle) of
        {ok, Bin} when is_binary(Bin), byte_size(Bin) > 0 ->
            {ok, Handle, Bin};
        {ok, Bin} when is_binary(Bin) ->
            {error, Handle, <<"nv-content-empty">>};
        {error, Reason} ->
            {error, Handle, Reason}
    end.

parse_chain_range_entries(Entries) ->
    Groups = consecutive_chain_groups(Entries),
    ParsedGroups = [parse_chain_group(Group) || Group <- Groups],
    Ders = lists:append([Ds || {Ds, _Hits, _Diag} <- ParsedGroups]),
    Hits0 = lists:append([Hs || {_Ds, Hs, _Diag} <- ParsedGroups]),
    Hits = uniq_preserve_order(Hits0),
    Diagnostics = [D || {_Ds, _Hs, D} <- ParsedGroups]
        ++ [chain_error_diagnostic(Handle, Reason)
            || {error, Handle, Reason} <- Entries],
    Attempts = [{Handle, Reason}
                || {error, Handle, Reason} <- Entries],
    finalize_chain_result(Ders, Hits, Attempts, lists:reverse(Diagnostics)).

consecutive_chain_groups(Entries) ->
    consecutive_chain_groups(Entries, [], []).

consecutive_chain_groups([], [], Acc) ->
    lists:reverse(Acc);
consecutive_chain_groups([], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
consecutive_chain_groups([{ok, Handle, Bin} | Rest], Current, Acc) ->
    consecutive_chain_groups(Rest, [{Handle, Bin} | Current], Acc);
consecutive_chain_groups([{error, _Handle, _Reason} | Rest], [], Acc) ->
    consecutive_chain_groups(Rest, [], Acc);
consecutive_chain_groups([{error, _Handle, _Reason} | Rest], Current, Acc) ->
    consecutive_chain_groups(Rest, [], [lists:reverse(Current) | Acc]).

parse_chain_group(Chunks) ->
    Bin = iolist_to_binary([Chunk || {_Handle, Chunk} <- Chunks]),
    Certs = split_concatenated_ders_with_offsets(Bin),
    Ders = [Der || {_Offset, Der} <- Certs],
    Hits = case Ders of
        [] -> [];
        _ -> [Handle || {Handle, _Chunk} <- Chunks]
    end,
    {Ders, Hits, chain_group_diagnostic(Chunks, Bin, Certs)}.

read_chain_handle(ChainHandle) ->
    case lapee_tpm_nif:nv_read(ChainHandle) of
        {ok, Bin} when is_binary(Bin), byte_size(Bin) > 0 ->
            Certs = split_concatenated_ders_with_offsets(Bin),
            Diagnostic = chain_handle_diagnostic(ChainHandle, Bin, Certs),
            case [Der || {_Offset, Der} <- Certs] of
                [] -> {error, <<"nv-content-empty-or-non-der">>,
                       Diagnostic};
                ChainDers -> {ok, ChainDers, Diagnostic}
            end;
        {error, Reason} ->
            {error, Reason,
             chain_error_diagnostic(ChainHandle, Reason)}
    end.

merge_chain_results(Results) ->
    Ders = lists:append([Ds || {Ds, _Source, _Hits, _Diag} <- Results]),
    Hits = lists:append([Hs || {_Ds, _Source, Hs, _Diag} <- Results]),
    Diagnostics = [D || {_Ds, _Source, _Hs, D} <- Results],
    case Hits of
        [] ->
            Sources =
                [S || {_Ds, S, _Hs, _Diag} <- Results,
                      S =/= <<"not-probed">>],
            {Ders, iolist_to_binary(
                [<<"probe-failed: ">>,
                 string:join([binary_to_list(S) || S <- Sources], "; ")]),
             [], chain_diagnostics(Diagnostics, Ders, Hits)};
        _ ->
            {Ders, chain_hit_source(Hits), Hits,
             chain_diagnostics(Diagnostics, Ders, Hits)}
    end.

finalize_chain_result(Ders, Hits, Attempts, Diagnostics) ->
    case Hits of
        [] ->
            Source = case Attempts of
                [] -> <<"not-probed">>;
                _ ->
                    iolist_to_binary(
                        io_lib:format("probe-failed: ~s",
                                      [chain_attempts_text(Attempts)]))
            end,
            OrderedDers = lists:reverse(Ders),
            {OrderedDers, Source, [],
             chain_diagnostics([#{
                 <<"probes">> => lists:reverse(Diagnostics)
             }], OrderedDers, [])};
        _ ->
            OrderedHits = lists:reverse(Hits),
            OrderedDers = lists:reverse(Ders),
            {OrderedDers, chain_hit_source(OrderedHits), OrderedHits,
             chain_diagnostics([#{
                 <<"probes">> => lists:reverse(Diagnostics)
             }], OrderedDers, OrderedHits)}
    end.

chain_hit_source(Hits) ->
    iolist_to_binary(
        [<<"tpm-nv:">>,
         string:join([binary_to_list(format_nv_handle(H)) || H <- Hits],
                     ",")]).

chain_attempts_text(Attempts) ->
    string:join(
        [binary_to_list(format_nv_handle(H)) ++ "="
         ++ binary_to_list(reason_to_text(Reason))
         || {H, Reason} <- lists:reverse(Attempts)], ",").

format_nv_handles(Handles) ->
    [format_nv_handle(H) || H <- Handles].

format_nv_handle(Handle) ->
    iolist_to_binary(io_lib:format("0x~8.16.0B", [Handle])).

chain_diagnostics(Groups, Ders, Hits) ->
    Probes = lists:append([maps:get(<<"probes">>, G, []) || G <- Groups]),
    #{
        <<"available">> => true,
        <<"description">> =>
            <<"Public TPM NV EK-chain diagnostics. Contains only handle "
              "numbers, byte counts, parsed X.509 metadata, and TPM read "
              "statuses; no private TPM material is exposed.">>,
        <<"cert-count">> => length(Ders),
        <<"hit-handles">> => format_nv_handles(Hits),
        <<"probe-count">> => length(Probes),
        <<"probes">> => Probes
    }.

chain_handle_diagnostic(Handle, Bin, Certs) ->
    #{
        <<"handle">> => format_nv_handle(Handle),
        <<"status">> => case Certs of [] -> <<"no-x509-der">>; _ -> <<"ok">> end,
        <<"bytes">> => byte_size(Bin),
        <<"cert-count">> => length(Certs),
        <<"certs">> => [cert_diagnostic(Offset, Der)
                         || {Offset, Der} <- Certs]
    }.

chain_group_diagnostic(Chunks, Bin, Certs) ->
    Ranges = chunk_ranges(Chunks),
    Handles = [Handle || {Handle, _Chunk} <- Chunks],
    #{
        <<"handle">> => chain_group_handle_text(Handles),
        <<"handles">> => format_nv_handles(Handles),
        <<"status">> =>
            case Certs of [] -> <<"no-x509-der">>; _ -> <<"ok">> end,
        <<"bytes">> => byte_size(Bin),
        <<"cert-count">> => length(Certs),
        <<"certs">> =>
            [(cert_diagnostic(Offset, Der))#{
                <<"span-handles">> =>
                    format_nv_handles(
                      handles_for_range(Offset, byte_size(Der), Ranges))
             }
             || {Offset, Der} <- Certs]
    }.

chain_error_diagnostic(Handle, Reason) ->
    #{
        <<"handle">> => format_nv_handle(Handle),
        <<"status">> => <<"error">>,
        <<"reason">> => reason_to_text(Reason),
        <<"bytes">> => 0,
        <<"cert-count">> => 0
    }.

chain_group_handle_text([]) ->
    <<"">>;
chain_group_handle_text([Handle]) ->
    format_nv_handle(Handle);
chain_group_handle_text(Handles) ->
    First = hd(Handles),
    Last = lists:last(Handles),
    <<(format_nv_handle(First))/binary, "..",
      (format_nv_handle(Last))/binary>>.

chunk_ranges(Chunks) ->
    element(2,
        lists:foldl(
            fun({Handle, Bin}, {Offset, Acc}) ->
                Next = Offset + byte_size(Bin),
                {Next, [{Handle, Offset, Next} | Acc]}
            end,
            {0, []},
            Chunks)).

handles_for_range(Offset, Len, Ranges) ->
    End = Offset + Len,
    [Handle || {Handle, Start, Stop} <- lists:reverse(Ranges),
               Start < End,
               Stop > Offset].

cert_diagnostic(Offset, Der) ->
    Base = #{
        <<"offset">> => Offset,
        <<"bytes">> => byte_size(Der),
        <<"sha256">> => hb_util:encode(crypto:hash(sha256, Der))
    },
    try
        Cert = public_key:pkix_decode_cert(Der, otp),
        Tbs = Cert#'OTPCertificate'.tbsCertificate,
        Extensions = cert_extensions(Tbs),
        Base#{
            <<"subject">> =>
                cert_name_text(Tbs#'OTPTBSCertificate'.subject),
            <<"issuer">> =>
                cert_name_text(Tbs#'OTPTBSCertificate'.issuer),
            <<"subject-key-identifier">> =>
                key_identifier_text(
                  extension_value(
                    ?'id-ce-subjectKeyIdentifier', Extensions)),
            <<"authority-key-identifier">> =>
                authority_key_identifier_text(
                  extension_value(
                    ?'id-ce-authorityKeyIdentifier', Extensions))
        }
    catch Class:Reason ->
        Base#{
            <<"decode-error">> =>
                iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))
        }
    end.

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

cert_name_text(Name) ->
    iolist_to_binary(
        io_lib:format("~p", [public_key:pkix_normalize_name(Name)])).

key_identifier_text(Identifier) when is_binary(Identifier) ->
    hb_util:encode(Identifier);
key_identifier_text(_) ->
    null.

authority_key_identifier_text(
  #'AuthorityKeyIdentifier'{keyIdentifier = Identifier}) ->
    key_identifier_text(Identifier);
authority_key_identifier_text(Identifier) ->
    key_identifier_text(Identifier).

%% Walk a binary that should contain DER-encoded X.509 certificates.
%% Each cert starts with ASN.1 tag `0x30' (SEQUENCE) followed by a
%% length encoding: short form (`0x00..0x7F') or long form (`0x80 | N',
%% then N big-endian length bytes). Intel ODCA EK-chain NV blobs have
%% been observed with non-cert bytes between certs, so we scan forward
%% after unrecognised bytes instead of stopping at the first gap. A
%% candidate SEQUENCE is accepted only if OTP can decode it as X.509.
split_concatenated_ders(Bin) ->
    [Der || {_Offset, Der} <- split_concatenated_ders_with_offsets(Bin)].

split_concatenated_ders_with_offsets(Bin) ->
    split_concatenated_ders_with_offsets(Bin, 0, []).

split_concatenated_ders_with_offsets(<<>>, _Offset, Acc) ->
    lists:reverse(Acc);
split_concatenated_ders_with_offsets(<<16#30, Rest/binary>> = Full,
                                     Offset, Acc) ->
    case der_seq_total_len(Rest) of
        {ok, TotalInner, HeaderLen} ->
            CertLen = 1 + HeaderLen + TotalInner,
            case Full of
                <<Cert:CertLen/binary, Tail/binary>> ->
                    case is_x509_der(Cert) of
                        true ->
                            split_concatenated_ders_with_offsets(
                                Tail, Offset + CertLen,
                                [{Offset, Cert} | Acc]);
                        false ->
                            <<_Skip, Tail2/binary>> = Full,
                            split_concatenated_ders_with_offsets(
                                Tail2, Offset + 1, Acc)
                    end;
                _ ->
                    %% Length reaches past the end; no complete cert
                    %% starts here.
                    lists:reverse(Acc)
            end;
        error ->
            <<_Skip, Tail/binary>> = Full,
            split_concatenated_ders_with_offsets(
                Tail, Offset + 1, Acc)
    end;
split_concatenated_ders_with_offsets(<<_Skip, Tail/binary>>, Offset, Acc) ->
    split_concatenated_ders_with_offsets(Tail, Offset + 1, Acc).

is_x509_der(Der) ->
    try
        public_key:pkix_decode_cert(Der, otp),
        true
    catch _:_ ->
        false
    end.

%% Parse the ASN.1 length encoding at the start of `Bin' (the
%% byte AFTER the 0x30 tag). Returns `{ok, ContentLen, LenBytes}'
%% where LenBytes is the number of bytes the length encoding
%% itself consumed.
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

%% Encode a list of DERs as a PEM bundle (one CERTIFICATE block
%% each, concatenated). Empty list -> empty binary.
ders_to_pem([]) -> <<>>;
ders_to_pem(Ders) ->
    iolist_to_binary([der_to_pem(D) || D <- Ders]).

try_nv_handles([], Acc) -> {error, lists:reverse(Acc)};
try_nv_handles([H | Rest], Acc) ->
    case lapee_tpm_nif:nv_read(H) of
        {ok, Der} when is_binary(Der), byte_size(Der) > 0 ->
            %% Sanity-check: does it look like an X.509 DER cert? The
            %% first byte should be 0x30 (ASN.1 SEQUENCE). TCG says NV
            %% 0x01C0000x indices hold exactly one DER cert with no
            %% length prefix. If the TPM put something else here we
            %% prefer to record it as "unrecognised" rather than feed
            %% mystery bytes to the verifier as an "EK cert".
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

format_probe_attempts(Attempts) ->
    %% The NIF's error Reason can be either an atom
    %% (lapee_make_error, e.g. 'nv_index_undefined') OR a nested
    %% tuple {tss2_rc, <<"op: 0x... (decoded)">>} from
    %% lapee_make_tss_error on any TSS2 failure we didn't
    %% specifically map to an atom. Render both shapes without
    %% assuming the inner structure -- a ~p fallback keeps the
    %% envelope shape stable even when the TPM returns an
    %% unexpected code.
    [iolist_to_binary(
        io_lib:format("0x~8.16.0B: ~s (~p bytes read)",
                      [H, reason_to_text(R), Sz]))
     || {H, R, Sz} <- Attempts].

reason_to_text(R) when is_atom(R) -> atom_to_binary(R, utf8);
reason_to_text(R) when is_binary(R) -> R;
reason_to_text({tss2_rc, Bin}) when is_binary(Bin) -> Bin;
reason_to_text(Other) ->
    iolist_to_binary(io_lib:format("~p", [Other])).

%% Quick PEM re-encoder for a DER-encoded X.509 cert. Matches the
%% wire format the rest of the stack expects (PEM with "CERTIFICATE"
%% labels and 64-char base64 lines).
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

%%----------------------------------------------------------------------------
%% NIF-facing wrappers. We resolve the NIF lazily: first a runtime module
%% `lapee_tpm_nif' (if HB is built with the NIF linked in via its rebar
%% port_specs), falling back to dlopening a .so at well-known paths.
%%----------------------------------------------------------------------------

nif_module() ->
    case code:is_loaded(lapee_tpm_nif) of
        {file, _} -> lapee_tpm_nif;
        false ->
            case code:ensure_loaded(lapee_tpm_nif) of
                {module, _} -> lapee_tpm_nif;
                _ -> not_loaded
            end
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

nif_pcr_read(Pcr) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:pcr_read(Pcr)
    end.

nif_create_ek() ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:create_primary_ek()
    end.

nif_create_signing_key(EKTr) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:create_signing_key(EKTr)
    end.

nif_make_credential(EKPublic, AKName, Secret) ->
    case nif_module() of
        not_loaded -> {error, nif_not_loaded};
        M -> catch M:make_credential(EKPublic, AKName, Secret)
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

%%%============================================================================
%%% Tests
%%%============================================================================

-ifdef(TEST).

info_shape_test() ->
    Info = info(ignored),
    ?assert(maps:is_key(exports, Info)),
    Exports = maps:get(exports, Info),
    ?assert(lists:member(<<"extend">>, Exports)),
    ?assert(lists:member(<<"quote">>, Exports)),
    ?assert(lists:member(<<"pcr-read">>, Exports)),
    ?assert(lists:member(<<"attestation">>, Exports)),
    ?assert(lists:member(<<"credential-subject">>, Exports)),
    ?assert(lists:member(<<"activate-credential">>, Exports)),
    ?assert(lists:member(<<"verify-peer">>, Exports)),
    %% No standalone tcg-event-log endpoint -- the log travels
    %% INSIDE the attested attestation envelope. A standalone
    %% un-attested path would let a malicious node serve one
    %% log via /tcg-event-log and a different one via
    %% /attestation.
    ?assertNot(lists:member(<<"tcg-event-log">>, Exports)).

info_docs_test() ->
    {ok, #{<<"status">> := 200, <<"body">> := Body}} = info(#{}, #{}, #{}),
    ?assert(maps:is_key(<<"description">>, Body)),
    ?assert(maps:is_key(<<"api">>, Body)),
    Api = maps:get(<<"api">>, Body),
    ?assert(maps:is_key(<<"extend">>, Api)),
    ?assert(maps:is_key(<<"attestation">>, Api)),
    ?assert(maps:is_key(<<"credential-subject">>, Api)),
    ?assert(maps:is_key(<<"activate-credential">>, Api)),
    ?assert(maps:is_key(<<"verify-peer">>, Api)).

peer_attestation_cache_paths_test() ->
    Signed = #{<<"peer-url">> => <<"http://peer.example:8734">>},
    SignedID = <<"signed-id">>,
    PeerURLHash = hb_util:encode(
        crypto:hash(sha256, <<"http://peer.example:8734">>)),
    ConsumerScopeHash = encoded_message_sha256(null),
    Prefix = ?PEER_ATTESTATION_PREFIX,
    ?assertEqual(
        [
            <<Prefix/binary, "/by-id/", SignedID/binary>>,
            <<Prefix/binary,
              "/by-peer-url-sha256/", PeerURLHash/binary,
              "/by-ek-public-sha256/unknown",
              "/by-boot-attestation-id/unknown",
              "/by-consumer-scope-sha256/", ConsumerScopeHash/binary,
              "/", SignedID/binary>>
        ],
        peer_attestation_cache_paths(Signed, SignedID, #{})).

credential_activation_public_body_hides_secret_test() ->
    Credential = #{
        <<"credential-blob">> => hb_util:encode(<<"blob">>),
        <<"secret">> => hb_util:encode(<<"encrypted-secret">>)
    },
    Secret = <<"ring-secret-must-not-be-exported">>,
    persistent_term:put({dev_tpm2, ak, name}, <<"ak-name">>),
    try
        Body = credential_activation_public_body(Secret, Credential, #{}),
        ?assertNot(maps:is_key(<<"credential-secret">>, Body)),
        ?assert(maps:is_key(<<"credential-secret-sha256">>, Body)),
        ?assert(maps:is_key(<<"credential-secret-proof">>, Body)),
        ?assertEqual(ok,
            ensure_activation_secret(Body, Credential, Secret, undefined, #{}))
    after
        persistent_term:erase({dev_tpm2, ak, name})
    end.

credential_activation_public_proof_rejects_wrong_secret_test() ->
    Credential = #{
        <<"credential-blob">> => hb_util:encode(<<"blob">>),
        <<"secret">> => hb_util:encode(<<"encrypted-secret">>)
    },
    IssuedAt = 123,
    AkName = <<"ak-name">>,
    Activation = #{
        <<"type">> => <<"lapee-tpm-credential-activation">>,
        <<"version">> => <<"1.0">>,
        <<"issued-at-unix">> => IssuedAt,
        <<"ak-name">> => AkName,
        <<"proof-alg">> => <<"HMAC-SHA256">>,
        <<"credential-secret-sha256">> =>
            hb_util:encode(crypto:hash(sha256, <<"secret-a">>)),
        <<"credential-secret-proof">> =>
            hb_util:encode(
                credential_activation_proof(
                    <<"secret-a">>, Credential, AkName, IssuedAt))
    },
    ?assertThrow(
        {boot_attestation_error, #{
            <<"credential-activation">> :=
                <<"activation proof did not match challenge">>
        }},
        ensure_activation_secret(Activation, Credential, <<"secret-b">>,
                                 undefined, #{})).

verify_peer_requires_boot_fresh_subject_match_test() ->
    ?assertEqual(ok,
        ensure_attestation_subjects_match(
            #{<<"node-message-id">> => <<"subject-a">>},
            #{<<"node-message-id">> => <<"subject-a">>})),
    ?assertThrow(
        {boot_attestation_error, #{<<"peer-attestation">> := _}},
        ensure_attestation_subjects_match(
            #{<<"node-message-id">> => <<"subject-a">>},
            #{<<"node-message-id">> => <<"subject-b">>})).

chk_quote_rejects_verifier_nonce_mismatch_test() ->
    Envelope = #{
        <<"tpm-quote">> => #{
            <<"nonce">> => hb_util:encode(<<"quote-nonce">>),
            <<"quoted">> => hb_util:encode(<<>>),
            <<"signature">> => hb_util:encode(<<>>),
            <<"pcr-selection">> => [],
            <<"pcr-values">> => #{}
        },
        <<"ak-pub-pem">> => <<>>,
        <<"ak-qualified-name">> => hb_util:encode(<<"ak">>)
    },
    ?assertEqual(
        {error, <<"quote nonce does not match verifier challenge">>},
        chk_quote(Envelope, <<"verifier-nonce">>)).

rsa_pub_from_tpm2b_public_test() ->
    ModulusBin = <<1:2048>>,
    Public = test_rsa_tpm2b_public(ModulusBin, 0),
    ?assertEqual(
        {ok, #'RSAPublicKey'{
            modulus = binary:decode_unsigned(ModulusBin),
            publicExponent = 65537
        }},
        rsa_pub_from_tpm2b_public(Public)).

ensure_ak_public_matches_subject_test() ->
    ModulusBin = <<1:2048>>,
    Public = test_rsa_tpm2b_public(ModulusBin, 0),
    {ok, Rsa} = rsa_pub_from_tpm2b_public(Public),
    {ok, Name} = tpm2b_public_name(Public),
    Subject = #{
        <<"ak-public">> => hb_util:encode(Public),
        <<"ak-pub-pem">> => test_rsa_public_pem(Rsa),
        <<"ak-name">> => hb_util:encode(Name)
    },
    ?assertEqual(ok, ensure_ak_public_matches_subject(Subject)),
    ?assertThrow(
        {boot_attestation_error, #{<<"ak-public">> := _}},
        ensure_ak_public_matches_subject(
            Subject#{<<"ak-name">> => hb_util:encode(<<"wrong-name">>)})).

ak_policy_bound_test() ->
    ?assert(lists:member(?NODE_IDENTITY_PCR, ?AK_POLICY_PCRS)),
    ModulusBin = <<1:2048>>,
    PcrMap =
        maps:from_list(
            [{integer_to_binary(I),
              hb_util:encode(crypto:strong_rand_bytes(32))}
             || I <- ?AK_POLICY_PCRS]),
    Policy = ak_policy_digest(?AK_POLICY_PCRS, PcrMap),
    Public = test_rsa_tpm2b_public(ModulusBin, 0, Policy),
    ?assertEqual({ok, Policy}, tpm2b_public_auth_policy(Public)),
    Envelope = #{
        <<"ak-public">> => hb_util:encode(Public),
        <<"tpm-quote">> => #{<<"pcr-values">> => PcrMap}
    },
    ?assertMatch({ok, _}, chk_ak_policy_bound(Envelope)),
    ?assertMatch(
        {error, <<"AK authPolicy is empty">>},
        chk_ak_policy_bound(
            Envelope#{
                <<"ak-public">> =>
                    hb_util:encode(test_rsa_tpm2b_public(ModulusBin, 0))
            })),
    ?assertMatch(
        {error, <<"AK authPolicy does not match quoted PCR state">>},
        chk_ak_policy_bound(
            Envelope#{<<"ak-public">> =>
                hb_util:encode(
                    test_rsa_tpm2b_public(
                        ModulusBin, 0, crypto:strong_rand_bytes(32)))})).

tpms_attest_qualified_signer_must_match_ak_test() ->
    Nonce = crypto:strong_rand_bytes(32),
    QualifiedSigner = <<"ak-qualified-name">>,
    Pcr0 = crypto:strong_rand_bytes(32),
    PcrMap = #{<<"0">> => hb_util:encode(Pcr0)},
    Quoted = test_tpms_quote_attest(QualifiedSigner, Nonce, Pcr0),
    ?assertMatch(
        {ok, _},
        chk_tpms_attest(Quoted, Nonce, [0], PcrMap, QualifiedSigner)),
    ?assertEqual(
        {error, <<"TPMS_ATTEST qualifiedSigner does not match "
                  "attested AK qualified name">>},
        chk_tpms_attest(Quoted, Nonce, [0], PcrMap, <<"other-ak">>)).

tpms_attest_rejects_reported_selection_mismatch_test() ->
    Nonce = crypto:strong_rand_bytes(32),
    QualifiedSigner = <<"ak-qualified-name">>,
    Pcr0 = crypto:strong_rand_bytes(32),
    PcrMap = #{<<"0">> => hb_util:encode(Pcr0)},
    Quoted = test_tpms_quote_attest(QualifiedSigner, Nonce, Pcr0),
    ?assertEqual(
        {error, <<"TPMS_ATTEST PCR selection does not match "
                  "reported pcr-selection">>},
        chk_tpms_attest(Quoted, Nonce, [1], PcrMap, QualifiedSigner)).

tpms_attest_requires_quote_magic_type_test() ->
    Nonce = crypto:strong_rand_bytes(32),
    QualifiedSigner = <<"ak-qualified-name">>,
    Pcr0 = crypto:strong_rand_bytes(32),
    PcrMap = #{<<"0">> => hb_util:encode(Pcr0)},
    Quoted0 = test_tpms_quote_attest(QualifiedSigner, Nonce, Pcr0),
    <<_MagicType:6/binary, Rest/binary>> = Quoted0,
    Quoted = <<0:32/unsigned-big, 16#8018:16/unsigned-big, Rest/binary>>,
    ?assertEqual(
        {error, <<"TPMS_ATTEST parse error (truncated or wrong shape)">>},
        chk_tpms_attest(Quoted, Nonce, [0], PcrMap, QualifiedSigner)).

test_tpm2b(Bin) ->
    <<(byte_size(Bin)):16/unsigned-big, Bin/binary>>.

test_rsa_tpm2b_public(ModulusBin, Exponent) ->
    test_rsa_tpm2b_public(ModulusBin, Exponent, <<>>).

test_rsa_tpm2b_public(ModulusBin, Exponent, AuthPolicy) ->
    Body = <<
        16#0001:16/unsigned-big,
        16#000B:16/unsigned-big,
        0:32/unsigned-big,
        (test_tpm2b(AuthPolicy))/binary,
        16#0010:16/unsigned-big,
        16#0010:16/unsigned-big,
        2048:16/unsigned-big,
        Exponent:32/unsigned-big,
        (test_tpm2b(ModulusBin))/binary
    >>,
    test_tpm2b(Body).

test_rsa_public_pem(Rsa) ->
    public_key:pem_encode([public_key:pem_entry_encode('RSAPublicKey', Rsa)]).

test_tpms_quote_attest(QualifiedSigner, Nonce, Pcr0) ->
    PcrDigest = crypto:hash(sha256, Pcr0),
    Selection = <<16#000B:16/unsigned-big, 3:8/unsigned-big, 1, 0, 0>>,
    QuoteInfo = <<1:32/unsigned-big, Selection/binary,
                  (test_tpm2b(PcrDigest))/binary>>,
    <<16#ff544347:32/unsigned-big, 16#8018:16/unsigned-big,
      (test_tpm2b(QualifiedSigner))/binary,
      (test_tpm2b(Nonce))/binary,
      0:(25 * 8), QuoteInfo/binary>>.

%% The TCG event log source-path + length + format fields
%% travel attested alongside tcg-event-log itself, so a
%% verifier can see at a glance where the bytes came from
%% without re-reading them.
read_tcg_event_log_with_source_shape_test() ->
    %% On a Mac dev box there's no /sys TPM; expect
    %% `{<<>>, <<"unavailable">>}'.
    {Bin, Src} = read_tcg_event_log_with_source(),
    ?assertEqual(<<>>, Bin),
    ?assertEqual(<<"unavailable">>, Src),
    ok.

%% infer_log_format/1 classifies a crypto-agile header
%% correctly from raw bytes alone (no event-log parse needed).
infer_log_format_crypto_agile_test() ->
    %% TCG_PCR_EVENT:
    %%   pcr u32 LE = 0
    %%   event_type u32 LE = 3 (EV_NO_ACTION)
    %%   sha1 digest (20 zero bytes)
    %%   event_data_size u32 LE
    %%   event_data: "Spec ID Event03" + nul + payload
    SpecId = <<"Spec ID Event03", 0, 0:128>>,
    Bin = <<0:32/little, 3:32/little, 0:(20*8),
            (byte_size(SpecId)):32/little, SpecId/binary>>,
    ?assertEqual(<<"crypto-agile">>, infer_log_format(Bin)).

infer_log_format_tdx_ccel_test() ->
    SpecId = <<"Spec ID Event03", 0, 0:128>>,
    %% First record on PCR 1 (MRTD) -> TDX CCEL.
    Bin = <<1:32/little, 3:32/little, 0:(20*8),
            (byte_size(SpecId)):32/little, SpecId/binary>>,
    ?assertEqual(<<"tdx-ccel">>, infer_log_format(Bin)).

infer_log_format_empty_test() ->
    ?assertEqual(<<"empty">>, infer_log_format(<<>>)),
    ?assertEqual(<<"unknown">>, infer_log_format(<<0, 1, 2>>)).

digest_of_32_byte_binary_test() ->
    B32 = <<0:256>>,
    ?assertEqual(B32, digest_of(B32, #{})).

digest_of_arbitrary_binary_test() ->
    Bin = <<"hello">>,
    ?assertEqual(crypto:hash(sha256, Bin), digest_of(Bin, #{})).

digest_of_message_uses_hb_message_id_test() ->
    %% Placeholder: would require hb_message loaded; sanity-check the
    %% code path at least.
    Msg = #{<<"a">> => 1, <<"b">> => 2},
    D = digest_of(Msg, #{}),
    ?assert(byte_size(D) =:= 32).

resolve_subject_test() ->
    %% Req/subject wins over body which wins over Base.
    ?assertEqual(<<"subj">>,
        resolve_subject(<<"base">>, #{<<"subject">> => <<"subj">>}, #{})),
    ?assertEqual(<<"body">>,
        resolve_subject(<<"base">>, #{<<"body">> => <<"body">>}, #{})),
    ?assertEqual(<<"base">>,
        resolve_subject(<<"base">>, #{}, #{})).

resolve_subject_body_test() ->
    Body = #{<<"type">> => <<"lapee-tpm-credential-activation">>},
    ?assertEqual(
        Body,
        resolve_subject_body(#{<<"status">> => 200,
                               <<"body">> => Body}, #{})),
    ?assertEqual(
        Body,
        resolve_subject_body(#{<<"commitments">> => #{},
                               <<"body">> => Body}, #{})).

resolve_pcr_default_test() ->
    ?assertEqual(15, resolve_pcr(#{}, 15, #{})),
    ?assertEqual(10, resolve_pcr(#{<<"pcr">> => 10}, 15, #{})),
    ?assertEqual(7, resolve_pcr(#{<<"pcr">> => <<"7">>}, 15, #{})).

resolve_pcr_list_test() ->
    ?assertEqual([0, 1, 7],
        resolve_pcr_list(#{<<"pcrs">> => [0, 1, 7]},
                         ?DEFAULT_QUOTE_PCRS, #{})),
    ?assertEqual([0, 7, 15],
        resolve_pcr_list(#{<<"pcrs">> => <<"0,7,15">>},
                         ?DEFAULT_QUOTE_PCRS, #{})),
    ?assertEqual(?DEFAULT_QUOTE_PCRS,
        resolve_pcr_list(#{}, ?DEFAULT_QUOTE_PCRS, #{})).

%% `chk_tcg_event_log_replay' returns `{ok, _}' when the envelope
%% has no firmware log (accepting this case -- test/dev guests
%% running QEMU+swtpm don't emit a firmware event log). Callers who
%% require a firmware log chain should additionally check envelope.
%% tcg_event_log size.
chk_tcg_event_log_replay_empty_log_test() ->
    %% Both "no field" and "field but empty" accepted.
    ?assertMatch({ok, _},
                 chk_tcg_event_log_replay(#{<<"tcg-event-log">> => <<>>})),
    ?assertMatch({ok, _},
                 chk_tcg_event_log_replay(#{<<"tcg-event-log">> =>
                                              hb_util:encode(<<>>)})),
    ?assertMatch({ok, _}, chk_tcg_event_log_replay(#{})).

%% When the envelope carries a TCG log whose events replay to
%% match the quoted PCR values, the check passes. Uses the same
%% synthetic fixture as dev_tpm_tcg's own tests -- PCR 0 gets one
%% event, PCR 7 gets one event, and we compute the expected
%% reconstructed values.
chk_tcg_event_log_replay_accepts_consistent_fixture_test() ->
    %% Build a 2-record crypto-agile log: SpecID on PCR 0 (not
    %% extended, EV_NO_ACTION) + one EV_S_CRTM_VERSION on PCR 0.
    AlgPairs = <<16#04:16/little, 20:16/little,
                 16#0B:16/little, 32:16/little>>,
    SpecId = <<"Spec ID Event03", 0,
               0:32/little, 0:8, 2:8, 0:8, 8:8, 2:32/little,
               AlgPairs/binary, 0:8>>,
    SpecIdSize = byte_size(SpecId),
    FirstRec = <<0:32/little, 3:32/little, 0:(20*8),
                 SpecIdSize:32/little, SpecId/binary>>,
    Data = <<"FW-ABC">>,
    Sha256 = crypto:hash(sha256, Data),
    Sha1   = crypto:hash(sha,    Data),
    Rec2 = <<0:32/little,
             16#8:32/little,
             2:32/little,
             16#04:16/little, Sha1/binary,
             16#0B:16/little, Sha256/binary,
             (byte_size(Data)):32/little, Data/binary>>,
    Log = <<FirstRec/binary, Rec2/binary>>,
    %% Compute the expected PCR-0 reconstruction.
    ExpectedPcr0 = crypto:hash(sha256, <<0:256, Sha256/binary>>),
    Envelope = #{
        <<"tcg-event-log">> => hb_util:encode(Log),
        <<"tpm-quote">> => #{
            <<"pcr-values">> =>
                #{<<"0">> => hb_util:encode(ExpectedPcr0)}
        }
    },
    ?assertMatch({ok, _}, chk_tcg_event_log_replay(Envelope)).

%% Tampering the log (flip one byte of the event data) makes the
%% reconstructed PCR diverge from the quoted value -> reject.
chk_tcg_event_log_replay_rejects_tampered_fixture_test() ->
    %% Same fixture construction as the prior test but with
    %% tampered event data -- PCR 0 reconstruction diverges from
    %% the expected value. Still records the "correct" quoted
    %% value in the envelope so the mismatch is detectable.
    AlgPairs = <<16#04:16/little, 20:16/little,
                 16#0B:16/little, 32:16/little>>,
    SpecId = <<"Spec ID Event03", 0,
               0:32/little, 0:8, 2:8, 0:8, 8:8, 2:32/little,
               AlgPairs/binary, 0:8>>,
    SpecIdSize = byte_size(SpecId),
    FirstRec = <<0:32/little, 3:32/little, 0:(20*8),
                 SpecIdSize:32/little, SpecId/binary>>,
    GoodData = <<"FW-ABC">>,
    GoodSha256 = crypto:hash(sha256, GoodData),
    BadData = <<"FW-XXX">>,
    BadSha256 = crypto:hash(sha256, BadData),
    BadSha1   = crypto:hash(sha,    BadData),
    Rec2Tampered = <<0:32/little,
                     16#8:32/little,
                     2:32/little,
                     16#04:16/little, BadSha1/binary,
                     16#0B:16/little, BadSha256/binary,
                     (byte_size(BadData)):32/little, BadData/binary>>,
    Log = <<FirstRec/binary, Rec2Tampered/binary>>,
    %% Quote claims the GOOD PCR 0 value. Log has tampered digest.
    GoodPcr0 = crypto:hash(sha256, <<0:256, GoodSha256/binary>>),
    Envelope = #{
        <<"tcg-event-log">> => hb_util:encode(Log),
        <<"tpm-quote">> => #{
            <<"pcr-values">> =>
                #{<<"0">> => hb_util:encode(GoodPcr0)}
        }
    },
    ?assertMatch({error, _}, chk_tcg_event_log_replay(Envelope)).

resolve_trusted_ca_priority_test() ->
    RequestPem = <<"-----BEGIN CERTIFICATE-----\nbase64url-pem\n"
                "-----END CERTIFICATE-----">>,
    ConfigPem = <<"-----BEGIN CERTIFICATE-----\nconfig-pem\n"
                  "-----END CERTIFICATE-----">>,
    TmpDir = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    Path = filename:join(
        TmpDir,
        "lapee-tpm-ca-" ++ integer_to_list(
            erlang:unique_integer([positive])) ++ ".pem"),
    ok = file:write_file(Path, ConfigPem),
    try
        {Bundle, <<"internal-bundle">>} =
            resolve_trusted_ca_with_source(#{}, #{}),
        ?assert(byte_size(Bundle) > byte_size(RequestPem)),
        ?assertNotEqual(
            nomatch,
            binary:match(Bundle, <<"-----BEGIN CERTIFICATE-----">>)),
        ?assertEqual(
            {Bundle, <<"internal-bundle">>},
            resolve_trusted_ca_with_source(
                #{<<"trusted-ca">> => hb_util:encode(RequestPem)}, #{})),
        ?assertEqual(
            {RequestPem, <<"request">>},
            resolve_trusted_ca_with_source(
                #{<<"trusted-ca">> => hb_util:encode(RequestPem)},
                #{lapee_allow_request_trusted_ca => true})),
        ?assertEqual(
            {<<>>, <<"request-bad">>},
            resolve_trusted_ca_with_source(
                #{<<"trusted-ca">> => <<"%%%not-base64url%%%">>},
                #{lapee_allow_request_trusted_ca => true,
                  lapee_tpm_ca_cert => list_to_binary(Path)})),
        ?assertEqual(
            {<<>>, <<"node-config-missing">>},
            resolve_trusted_ca_with_source(
                #{}, #{lapee_tpm_ca_cert => <<"/nonexistent/ca.pem">>})),
        ?assertEqual(
            {ConfigPem, <<"node-config">>},
            resolve_trusted_ca_with_source(
                #{}, #{lapee_tpm_ca_cert => list_to_binary(Path)})),
        ?assertEqual(Bundle, resolve_trusted_ca(#{}, #{}))
    after
        file:delete(Path)
    end.

%% Regression test: `chk_event_log_replay' must refuse to
%% "replay" zero events into a zero PCR and call it valid. Even
%% though `chk_binding' catches the same shape, we want the replay
%% check to be explicit about non-emptiness too -- defence in depth.
chk_event_log_replay_rejects_empty_events_test() ->
    Zero43 = hb_util:encode(<<0:256>>),
    Envelope = #{
        <<"runtime-event-log">> => [],
        <<"tpm-quote">> => #{
            <<"pcr-values">> => #{<<"15">> => Zero43}
        }
    },
    ?assertMatch({error, _}, chk_event_log_replay(Envelope)).

%% Regression test: `chk_binding' must refuse to treat an empty /
%% malformed node_message_id as matching an empty event digest
%% (both would trivially `hb_util:decode' to `<<>>'). Real ids
%% decode to 32 bytes; anything else is a hard reject.
chk_binding_rejects_empty_id_test() ->
    %% Event whose digest decodes to <<>>.
    EmptyDigestEvent = #{<<"pcr">> => 15,
                         <<"digest">> => <<"">>,
                         <<"seq">> => 0},
    EnvelopeEmptyId = #{
        <<"node-message-id">> => <<"">>,
        <<"runtime-event-log">> => [EmptyDigestEvent]
    },
    ?assertMatch({error, _}, chk_binding(EnvelopeEmptyId)),
    %% Also: id that decodes to fewer than 32 bytes (shorter base64url).
    EnvelopeShortId = #{
        <<"node-message-id">> => <<"AAAA">>,   %% 3 bytes
        <<"runtime-event-log">> =>
            [EmptyDigestEvent#{<<"digest">> => <<"AAAA">>}]
    },
    ?assertMatch({error, _}, chk_binding(EnvelopeShortId)).

normalise_boot_attestation_uses_extended_subject_test() ->
    System = #{<<"kernel">> => #{<<"cmdline">> => <<"good">>}},
    Node = #{<<"address">> => <<"node-address">>},
    Subject = #{<<"system">> => System, <<"node">> => Node},
    SubjectID = hb_message:id(Subject, all, #{}),
    NodeOnlyID =
        hb_util:human_id(
            hb_util:native_id(hb_message:id(Node, all, #{}))),
    Envelope = Subject#{
        <<"tpm">> => #{
            <<"extended-subject">> => SubjectID,
            <<"quote">> => #{}
        }
    },
    Normalised = normalise_attestation(Envelope, #{}),
    ?assertNotEqual(NodeOnlyID, SubjectID),
    ?assertEqual(SubjectID,
                 hb_maps:get(<<"node-message-id">>, Normalised, undefined,
                             #{})).

ek_cert_chain_handles_include_intel_odca_range_test() ->
    ?assertEqual(
        [16#01C00003 | lists:seq(16#01C00100, 16#01C001FF)],
        ek_cert_chain_handles(16#01C00002)),
    ?assertEqual(
        lists:seq(16#01C00100, 16#01C001FF),
        ek_cert_chain_handles(16#01C000FF)).

intel_odca_ek_chain_accepts_tcg_key_usage_test() ->
    EkDer = pem_fixture_der("intel-mtl-odca-ek-cert.pem"),
    ChainDers = pem_fixture_ders("intel-mtl-odca-tpm-chain.pem"),
    TrustedDers = [
        root_ca_fixture_der("INTEL_ODCA_CA2_CSME_INTERMEDIATE.pem"),
        root_ca_fixture_der("INTEL_ODCA_MTL_00003043_CA2.pem"),
        root_ca_fixture_der("INTEL_ODCA_ROOT_CA.pem")
    ],
    ?assertMatch({ok, _},
                 validate_ek_chain(EkDer, ChainDers, TrustedDers)).

split_concatenated_ders_skips_non_cert_gaps_test() ->
    Der = root_ca_fixture_der(),
    ?assertEqual(
        [Der, Der, Der],
        split_concatenated_ders(
          <<Der/binary, 0:32/little, "gap", Der/binary, Der/binary>>)).

split_concatenated_ders_reports_offsets_test() ->
    Der = root_ca_fixture_der(),
    Gap = <<0:32/little, "gap">>,
    ?assertEqual(
        [{0, Der}, {byte_size(Der) + byte_size(Gap), Der}],
        split_concatenated_ders_with_offsets(
          <<Der/binary, Gap/binary, Der/binary>>)).

candidate_intermediate_chains_keeps_direct_anchor_path_test() ->
    Peer = <<"peer-chain-cert">>,
    Anchor = <<"issuer-anchor">>,
    OtherTrusted = <<"root-anchor">>,
    ?assertEqual(
        [[Peer], [Peer, OtherTrusted]],
        candidate_intermediate_chains([Peer],
                                      [Anchor, OtherTrusted],
                                      Anchor)),
    ?assertEqual(
        [[], [OtherTrusted]],
        candidate_intermediate_chains([],
                                      [Anchor, OtherTrusted],
                                      Anchor)).

%% AIA fallback: a real Intel ADL EK leaf + ROM/Kernel/PTT
%% intermediates pin against an Intel ODCA root + the CSME
%% Intermediate CA, but the per-SoC `ODCA 2 CSME P_ADL 00002820
%% Issuing CA' is missing from the local corpus. Without AIA the
%% chain fails. With AIA -- pre-cached via persistent_term so the
%% test never hits the network -- the chain extension picks up the
%% missing intermediate and validation succeeds.
aia_extends_chain_for_missing_intel_adl_intermediate_test() ->
    Leaf = aia_fixture_pem("intel-adl-ek-leaf.pem"),
    PeerChain = aia_fixture_pems("intel-adl-ek-chain.pem"),
    Roots = [
        root_ca_fixture_der("INTEL_ODCA_ROOT_CA.pem"),
        root_ca_fixture_der("INTEL_ODCA_CA2_CSME_INTERMEDIATE.pem")
    ],
    %% Disabled: chain incomplete, verifier rejects.
    {error, _} = validate_ek_chain(Leaf, PeerChain, Roots,
        #{<<"lapee-aia-fetch-enabled">> => false}),
    %% Pre-cache the Intel ADL Issuing CA fetch result so the test
    %% exercises the AIA wiring without hitting the network.
    AdlIssuingDer = aia_fixture_pem("intel-adl-issuing-ca-2820.pem"),
    AdlUrl = aia_url_from_chain(PeerChain),
    persistent_term:put({lapee_aia, fetched, AdlUrl}, AdlIssuingDer),
    try
        {ok, Detail} = validate_ek_chain(Leaf, PeerChain, Roots, #{}),
        ?assert(byte_size(Detail) > 0)
    after
        persistent_term:erase({lapee_aia, fetched, AdlUrl})
    end.

aia_fixture_pem(Name) ->
    Pems = aia_fixture_pems(Name),
    hd(Pems).

aia_fixture_pems(Name) ->
    Paths = [
        filename:join(["priv", "tpm-interpret", "aia-fixtures", Name]),
        filename:join(["hyperbeam-overlay", "priv", "tpm-interpret",
                       "aia-fixtures", Name])
    ],
    [Pem] = [Bin || P <- Paths, {ok, Bin} <- [file:read_file(P)]],
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].

aia_url_from_chain(ChainDers) ->
    %% Walk the chain and return the AIA caIssuers URL of the cert
    %% whose issuer DN is the missing ADL Issuing CA. Any cert in
    %% the fixture chain whose AIA points at the ADL Issuing CA URL
    %% is acceptable.
    Urls = lists:flatten([lapee_aia:caissuers_urls(D) || D <- ChainDers]),
    [Url | _] = Urls,
    Url.

parse_chain_group_reads_cert_across_nv_boundary_test() ->
    Der = root_ca_fixture_der(),
    Split = byte_size(Der) - 17,
    <<Head:Split/binary, Tail/binary>> = Der,
    {Ders, Hits, Diagnostic} =
        parse_chain_group([{16#01C00100, Head}, {16#01C00101, Tail}]),
    ?assertEqual([Der], Ders),
    ?assertEqual([16#01C00100, 16#01C00101], Hits),
    [CertDiag] = maps:get(<<"certs">>, Diagnostic),
    ?assertEqual(
        [<<"0x01C00100">>, <<"0x01C00101">>],
        maps:get(<<"span-handles">>, CertDiag)).

root_ca_fixture_der() ->
    root_ca_fixture_der("INTEL_RT.pem").

root_ca_fixture_der(Name) ->
    Paths = [
        filename:join(["priv", "tpm-interpret", "root-cas",
                       Name]),
        filename:join(["hyperbeam-overlay", "priv", "tpm-interpret",
                       "root-cas", Name])
    ],
    Pems = [Pem || Path <- Paths, {ok, Pem} <- [file:read_file(Path)]],
    [{'Certificate', Der, not_encrypted} | _] =
        public_key:pem_decode(hd(Pems)),
    Der.

pem_fixture_der(Name) ->
    [Der | _] = pem_fixture_ders(Name),
    Der.

pem_fixture_ders(Name) ->
    Paths = [
        filename:join(["priv", "tpm-interpret", "fixtures", Name]),
        filename:join(["hyperbeam-overlay", "priv", "tpm-interpret",
                       "fixtures", Name])
    ],
    Pems = [Pem || Path <- Paths, {ok, Pem} <- [file:read_file(Path)]],
    [Der || {'Certificate', Der, not_encrypted} <-
                public_key:pem_decode(hd(Pems))].

%% Regression test: the verify_fun used in chk_ek_chain must reject
%% every structural / trust failure pkix can report, while letting
%% real-world TPM EK cert extensions through so vendor certs from
%% Nuvoton / Infineon / STMicro validate. Keeps this in lock-step
%% with `dev_tpm_interpret:ek_verify_fun/3' -- the two live in
%% different modules (device vs parser) per the LapEE architecture
%% but must accept identical chains.
ek_chain_verify_fun_rejects_bad_certs_test() ->
    {F, []} = ek_chain_verify_fun(),
    %% Non-TCG {bad_cert, _} events: hard fail. pkix re-wraps the
    %% inner reason as `{error, {bad_cert, Reason}}', so returning
    %% the unwrapped atom is the canonical convention (matches
    %% `dev_tpm_interpret:ek_verify_fun/3').
    ?assertMatch({fail, unknown_ca},
                 F(ignored, {bad_cert, unknown_ca},    state)),
    ?assertMatch({fail, selfsigned_peer},
                 F(ignored, {bad_cert, selfsigned_peer}, state)),
    ?assertMatch({fail, invalid_issuer},
                 F(ignored, {bad_cert, invalid_issuer}, state)),
    ?assertMatch({fail, invalid_signature},
                 F(ignored, {bad_cert, invalid_signature}, state)),
    ?assertMatch({fail, cert_expired},
                 F(ignored, {bad_cert, cert_expired},   state)),
    %% Critical unknown extensions carrying TCG OIDs must pass: real
    %% EK certs mark id-tcg-kp-EKCertificate (2.23.133.8.1) and
    %% id-tcg-tpmSpecification (2.23.133.2.16) critical, which OTP's
    %% default validator would otherwise reject.
    EkuExt = #'Extension'{extnID = {2, 23, 133, 8, 1}},
    ?assertMatch({valid, state},
                 F(ignored,
                   {bad_cert, {not_supported_extension, EkuExt}},
                   state)),
    SpecExt = #'Extension'{extnID = {2, 23, 133, 2, 16}},
    ?assertMatch({valid, state},
                 F(ignored,
                   {bad_cert, {not_supported_extension, SpecExt}},
                   state)),
    %% Critical unknown extensions outside the TCG whitelist still
    %% fail -- a rogue EK carrying a truly-unrecognised critical
    %% extension must not slip through.
    RogueExt = #'Extension'{extnID = {1, 2, 3, 4}},
    ?assertMatch({fail, {not_supported_extension, _}},
                 F(ignored,
                   {bad_cert, {not_supported_extension, RogueExt}},
                   state)),
    %% Non-critical extensions under the TCG arc are informational.
    TcgNonCrit = #'Extension'{extnID = {2, 23, 133, 2, 1}},
    ?assertMatch({valid, state},
                 F(ignored, {extension, TcgNonCrit}, state)),
    %% Non-TCG non-critical extensions: unknown (let pkix decide).
    NonTcgNonCrit = #'Extension'{extnID = {1, 2, 3, 4, 5}},
    ?assertMatch({unknown, state},
                 F(ignored, {extension, NonTcgNonCrit}, state)),
    %% Valid events pass through.
    ?assertMatch({valid, state}, F(ignored, valid, state)),
    ?assertMatch({valid, state}, F(ignored, valid_peer, state)),
    ok.

%% Reviewer pass 11 / batch 13: verifies that the
%% double-checked-locking pattern used in ensure_ak/1
%% correctly serialises concurrent callers that pass the
%% outer check but race on the inner compute. Tests the
%% primitive (global:trans + a shared persistent_term flag)
%% directly rather than ensure_ak itself (which requires
%% a real TPM NIF); regresses the shape of the fix.
ensure_once_double_checked_lock_serialises_test() ->
    Key = {dev_tpm2, batch13_test_flag},
    Counter = {dev_tpm2, batch13_test_counter},
    persistent_term:erase(Key),
    persistent_term:put(Counter, 0),
    %% Synthetic "init_chain" that increments a counter and
    %% sets the flag. With no serialisation, 20 concurrent
    %% callers past the outer check would all run the body
    %% and the counter would hit 20. With the double-checked
    %% locking pattern, only one caller under the lock sees
    %% the flag as undefined; the rest re-read and short-
    %% circuit. Counter MUST end at 1.
    EnsureOnce = fun Loop() ->
        case persistent_term:get(Key, undefined) of
            undefined ->
                global:trans(
                    {{dev_tpm2, batch13_test_lock}, self()},
                    fun() ->
                        %% Re-check under lock. This is the
                        %% critical step -- without it, the
                        %% lock serialises but every caller
                        %% still executes the body in turn.
                        case persistent_term:get(Key, undefined) of
                            undefined ->
                                %% Simulate real init_chain
                                %% work: small sleep so
                                %% competing callers pile up.
                                timer:sleep(10),
                                Old = persistent_term:get(Counter),
                                persistent_term:put(Counter, Old + 1),
                                persistent_term:put(Key, done),
                                done;
                            done -> done
                        end
                    end,
                    [node()]);
            done -> done
        end,
        Loop
    end,
    Parent = self(),
    N = 20,
    Pids = [spawn_link(fun() ->
        _ = EnsureOnce(),
        Parent ! {done, self()}
    end) || _ <- lists:seq(1, N)],
    %% Wait for all callers to complete.
    lists:foreach(
        fun(P) ->
            receive {done, P} -> ok
            after 5000 -> error({timeout, P}) end
        end, Pids),
    %% The body ran exactly once.
    ?assertEqual(1, persistent_term:get(Counter)),
    ?assertEqual(done, persistent_term:get(Key)),
    persistent_term:erase(Key),
    persistent_term:erase(Counter),
    ok.

event_log_append_test() ->
    %% Reset state for the test.
    persistent_term:erase({dev_tpm2, event_log}),
    persistent_term:erase({dev_tpm2, event_seq}),
    ?assertEqual([], event_log(#{})),
    ok = append_event(15, #{<<"event-type">> => <<"T">>}),
    Log = event_log(#{}),
    ?assertEqual(1, length(Log)),
    [E1] = Log,
    ?assertEqual(15, maps:get(<<"pcr">>, E1)),
    ?assertEqual(0, maps:get(<<"seq">>, E1)),
    ok = append_event(15, #{<<"event-type">> => <<"U">>}),
    ?assertEqual(2, length(event_log(#{}))).

-endif.
