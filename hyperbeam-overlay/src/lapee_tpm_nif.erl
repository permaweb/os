%%%-------------------------------------------------------------------
%%% @doc lapee_tpm_nif — raw NIF bindings to libtss2-esys.
%%%
%%% This module is the lowest layer: every exported function is a NIF.
%%% The shared library is built from c_src/ and placed in priv/.
%%%-------------------------------------------------------------------
-module(lapee_tpm_nif).

-export([
    startup/0,
    pcr_read/1,
    pcr_extend/2,
    create_primary_ek/0,
    create_signing_key/1,
    make_credential/3,
    activate_credential/4,
    quote/3,
    tpm_properties/0,
    nv_read_public/1,
    nv_read/1,
    flush_context/1,
    set_tcti/1
]).

-on_load(init/0).

%% NIF lives alongside the rest of HB's priv files when the `lapee'
%% rebar3 profile is used; at release time `priv/lapee_tpm_nif.so' ends
%% up at `lib/hb-<vsn>/priv/', which `code:priv_dir(hb)' finds.
-define(APPNAME, hb).
-define(LIBNAME, "lapee_tpm_nif").

init() ->
    SoName =
        case code:priv_dir(?APPNAME) of
            {error, bad_name} ->
                case filelib:is_dir(filename:join("..", "priv")) of
                    true ->
                        filename:join("../priv", ?LIBNAME);
                    false ->
                        filename:join("priv", ?LIBNAME)
                end;
            Dir ->
                filename:join(Dir, ?LIBNAME)
        end,
    %% Default TCTI for dev; appliance init overrides this with /dev/tpm0.
    DefaultTcti = "swtpm:host=127.0.0.1,port=2321",
    Tcti =
        case os:getenv("LAPEE_TPM_TCTI") of
            false -> DefaultTcti;
            V -> V
        end,
    %% Allow verifier-only HB instances (no TPM present) to load this
    %% module successfully. With LAPEE_TPM_ALLOW_NO_NIF=1, a load
    %% failure is logged but treated as OK — the NIF stubs still
    %% raise `nif_not_loaded' if called, so attest operations fail
    %% explicitly while verify/parse paths (which don't touch the
    %% TPM) continue to work.
    case erlang:load_nif(SoName, Tcti) of
        ok ->
            ok;
        {error, _} = Err ->
            case os:getenv("LAPEE_TPM_ALLOW_NO_NIF") of
                V1 when V1 =:= false; V1 =:= ""; V1 =:= "0" ->
                    Err;
                _ ->
                    %% on_load runs very early — logger may not be up
                    %% yet. Use stderr directly.
                    io:format(standard_error,
                              "[lapee_tpm_nif] running without NIF "
                              "(LAPEE_TPM_ALLOW_NO_NIF set; load_nif "
                              "returned ~p)~n",
                              [Err]),
                    ok
            end
    end.

%% --- NIF stubs; real implementations live in c_src/ ---

startup() -> erlang:nif_error(nif_not_loaded).

pcr_read(_Idx) -> erlang:nif_error(nif_not_loaded).

pcr_extend(_Idx, _Data) -> erlang:nif_error(nif_not_loaded).

create_primary_ek() -> erlang:nif_error(nif_not_loaded).

create_signing_key(_ParentHandle) -> erlang:nif_error(nif_not_loaded).

%% Build a TPM2 credential blob for `AkName' under `EkPublic'.
%% `EkPublic' is a marshalled TPM2B_PUBLIC, `AkName' is the raw
%% TPM2B_NAME payload returned by ReadPublic, and `Secret' is the
%% verifier-chosen 32-byte credential. Returns
%% `{ok, #{credential_blob, secret}}', both marshalled TPM2B binaries.
make_credential(_EkPublic, _AkName, _Secret) ->
    erlang:nif_error(nif_not_loaded).

%% Recover a MakeCredential secret using the loaded AK and EK handles.
%% The recovered certInfo is the verifier's original secret iff the AK
%% and EK live in the same TPM and match the names used by the verifier.
activate_credential(_AkHandle, _EkHandle, _CredentialBlob, _Secret) ->
    erlang:nif_error(nif_not_loaded).

quote(_SignHandle, _PcrList, _Nonce) -> erlang:nif_error(nif_not_loaded).

%% Query TPM2_GetCapability for standard manufacturer / vendor-string
%% / spec-version / firmware-version fields. Returns
%% {ok, #{manufacturer, vendor_string, spec_family, spec_level,
%%        spec_revision, firmware_version_1, firmware_version_2,
%%        day_of_year, year}} regardless of whether the TPM has an EK
%% cert provisioned in NV. This is the primary real-TPM-identification
%% path for the claim layer; the EK cert's TCG-OID attributes, when
%% present, act as a cross-check rather than the sole source.
tpm_properties() -> erlang:nif_error(nif_not_loaded).

%% Read the public metadata of an NV index addressed by its TPM handle
%% (e.g. 16#01C00002 for the RSA-2048 EK cert index). Returns
%% {ok, #{data_size, attributes, name_alg, auth_policy_len, handle}} on
%% success, or {error, <<"nv_index_undefined">>} when the handle is not
%% provisioned on this TPM -- which is the canonical signal that the
%% manufacturer did not populate an EK cert at that index.
nv_read_public(_TpmHandle) -> erlang:nif_error(nif_not_loaded).

%% Read the full bytes of an NV index addressed by its TPM handle.
%% Chunked reads handled inside the NIF. Returns {ok, Data::binary()}
%% or {error, Reason} where Reason is one of:
%%   <<"nv_index_undefined">>    -- handle not defined
%%   <<"nv_index_empty">>        -- defined but zero-length
%%   <<"nv_index_not_readable">> -- attributes forbid any read path
%%   <<"Esys_NV_Read: ...">>     -- any other TSS2 failure
nv_read(_TpmHandle) -> erlang:nif_error(nif_not_loaded).

flush_context(_Handle) -> erlang:nif_error(nif_not_loaded).

set_tcti(_TctiString) -> erlang:nif_error(nif_not_loaded).
