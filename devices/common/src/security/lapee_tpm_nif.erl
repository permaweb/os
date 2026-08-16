%%%-------------------------------------------------------------------
%%% @doc lapee_tpm_nif — raw NIF bindings to libtss2-esys.
%%%
%%% This module is the lowest layer: every exported function is a NIF.
%%% The shared library is built from c_src/ and placed in priv/.
%%%-------------------------------------------------------------------
-module(lapee_tpm_nif).

-export([
    startup/0,
    pcr_extend/2,
    create_primary_ek/0,
    create_signing_key/0,
    activate_credential/4,
    quote/3,
    tpm_properties/0,
    nv_read/1
]).

-on_load(init/0).

-define(LIBNAME, "lapee_tpm_nif").

init() ->
    SoName = filename:join(priv_dir(), ?LIBNAME),
    %% Default TCTI for dev; appliance init overrides this with /dev/tpm0.
    DefaultTcti = "swtpm:host=127.0.0.1,port=2321",
    Tcti =
        case os:getenv("LAPEE_TPM_TCTI") of
            false -> DefaultTcti;
            V -> V
        end,
    %% The TPM NIF must not be a global VM precondition: SNP guests,
    %% verifier-only nodes, and tests may load modules that reference
    %% `lapee_tpm_nif' without having a TPM TCTI. A load failure leaves
    %% the Erlang stubs active, so TPM operations still fail closed with
    %% `nif_not_loaded' while non-TPM paths can run.
    case erlang:load_nif(SoName, Tcti) of
        ok ->
            ok;
        {error, _} = Err ->
            %% on_load runs very early -- logger may not be up yet.
            io:format(
                standard_error,
                "[lapee_tpm_nif] running without NIF "
                "(load_nif returned ~p)~n",
                [Err]
            ),
            ok
    end.

priv_dir() ->
    case os:getenv("LAPEE_TPM_NIF_DIR") of
        false -> priv_dir_from_code();
        Dir -> Dir
    end.

priv_dir_from_code() ->
    case code:which(?MODULE) of
        Path when is_list(Path) -> filename:dirname(Path);
        _ -> fallback_priv_dir()
    end.

fallback_priv_dir() ->
    case filelib:is_dir(filename:join("..", "priv")) of
        true -> filename:join("..", "priv");
        false -> "priv"
    end.

%% --- NIF stubs; real implementations live in c_src/ ---

startup() -> erlang:nif_error(nif_not_loaded).

pcr_extend(_Idx, _Data) -> erlang:nif_error(nif_not_loaded).

create_primary_ek() -> erlang:nif_error(nif_not_loaded).

create_signing_key() -> erlang:nif_error(nif_not_loaded).

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

%% Read the full bytes of an NV index addressed by its TPM handle.
%% Chunked reads handled inside the NIF. Returns {ok, Data::binary()}
%% or {error, Reason} where Reason is one of:
%%   <<"nv_index_undefined">>    -- handle not defined
%%   <<"nv_index_empty">>        -- defined but zero-length
%%   <<"nv_index_not_readable">> -- attributes forbid any read path
%%   <<"Esys_NV_Read: ...">>     -- any other TSS2 failure
nv_read(_TpmHandle) -> erlang:nif_error(nif_not_loaded).
