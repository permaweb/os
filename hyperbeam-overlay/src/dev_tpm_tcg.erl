%%% @doc Minimal TCG event-log helpers for LapEE.
%%%
%%% LapEE keeps the full firmware log as evidence, but the runtime verifier only
%%% needs three pieces locally: parse events well enough to replay PCRs, extract
%%% the measured Secure Boot variable, and decode ACPI table headers for
%%% `~system@1.0'.  Broader firmware interpretation belongs in external
%%% analysis tools, not in the boot appliance.
-module(dev_tpm_tcg).
-export([boot_signals/1, parse_acpi_table/1, parse_acpi_rsdp/1]).

%%%============================================================================
%%% Event-log parsing
%%%============================================================================

parse(Bin) when is_binary(Bin) ->
    case parse_first_record(Bin) of
        {ok, First, Algs, Rest} ->
            {Events, _Tail} = parse_crypto_agile(Rest, Algs, 2, [First]),
            index_map([with_event_type(Ev) || Ev <- Events]);
        {error, _} = Err ->
            case parse_legacy(Bin, 1, []) of
                {ok, Events} ->
                    index_map([with_event_type(Ev) || Ev <- Events]);
                _ ->
                    #{<<"error">> => fmt_error(Err)}
            end
    end;
parse(_) ->
    #{<<"error">> => <<"input is not a binary">>}.

parse_first_record(
    <<Pcr:32/little, Type:32/little, Digest:20/binary,
      Size:32/little, Rest/binary>>) ->
    case Rest of
        <<Event:Size/binary, Tail/binary>> ->
            case parse_spec_id(Event) of
                {ok, Algs} ->
                    {ok, #{
                        <<"seq">> => 1,
                        <<"pcr">> => Pcr,
                        <<"event-type-code">> => Type,
                        <<"digests">> => #{<<"sha1">> => Digest},
                        <<"event-data">> => Event
                    }, Algs, Tail};
                error ->
                    Head = binary:part(Event, 0, min(byte_size(Event), 16)),
                    {error, {no_spec_id_header, Size, Head}}
            end;
        _ ->
            {error, {first_record_truncated, Size}}
    end;
parse_first_record(_) ->
    {error, truncated}.

parse_spec_id(<<"Spec ID Event03", 0, _Class:32/little,
                _Minor:8, _Major:8, _Errata:8, _Uintn:8,
                Count:32/little, Rest/binary>>) ->
    parse_alg_list(Rest, Count, #{});
parse_spec_id(_) ->
    error.

parse_alg_list(_Rest, 0, Acc) ->
    {ok, Acc};
parse_alg_list(<<Alg:16/little, Size:16/little, Rest/binary>>, N, Acc)
        when N > 0 ->
    parse_alg_list(Rest, N - 1, Acc#{Alg => Size});
parse_alg_list(_, _, _) ->
    error.

parse_crypto_agile(<<>>, _Algs, _Seq, Acc) ->
    {lists:reverse(Acc), <<>>};
parse_crypto_agile(
    <<Pcr:32/little, Type:32/little, Count:32/little, Rest0/binary>>,
    Algs,
    Seq,
    Acc) ->
    case parse_digests(Rest0, Count, Algs, #{}) of
        {ok, Digests, <<Size:32/little, Rest1/binary>>} ->
            case Rest1 of
                <<Event:Size/binary, Tail/binary>> ->
                    parse_crypto_agile(
                        Tail,
                        Algs,
                        Seq + 1,
                        [#{
                            <<"seq">> => Seq,
                            <<"pcr">> => Pcr,
                            <<"event-type-code">> => Type,
                            <<"digests">> => Digests,
                            <<"event-data">> => Event
                        } | Acc]);
                _ ->
                    {lists:reverse([parse_error(Seq, truncated_event) | Acc]),
                     <<>>}
            end;
        _ ->
            {lists:reverse([parse_error(Seq, truncated_digest) | Acc]), <<>>}
    end;
parse_crypto_agile(_Tail, _Algs, Seq, Acc) ->
    {lists:reverse([parse_error(Seq, truncated_record) | Acc]), <<>>}.

parse_digests(Rest, 0, _Algs, Acc) ->
    {ok, Acc, Rest};
parse_digests(<<Alg:16/little, Rest0/binary>>, N, Algs, Acc) when N > 0 ->
    Size = maps:get(Alg, Algs, alg_size(Alg)),
    case Rest0 of
        <<Digest:Size/binary, Rest/binary>> ->
            parse_digests(
                Rest,
                N - 1,
                Algs,
                Acc#{alg_name(Alg) => Digest});
        _ ->
            error
    end;
parse_digests(_, _, _, _) ->
    error.

parse_legacy(<<>>, _Seq, Acc) ->
    {ok, lists:reverse(Acc)};
parse_legacy(
    <<Pcr:32/little, Type:32/little, Digest:20/binary,
      Size:32/little, Rest/binary>>,
    Seq,
    Acc) ->
    case Rest of
        <<Event:Size/binary, Tail/binary>> ->
            parse_legacy(
                Tail,
                Seq + 1,
                [#{
                    <<"seq">> => Seq,
                    <<"pcr">> => Pcr,
                    <<"event-type-code">> => Type,
                    <<"digests">> => #{<<"sha1">> => Digest},
                    <<"event-data">> => Event
                } | Acc]);
        _ ->
            {ok, lists:reverse([parse_error(Seq, truncated_event) | Acc])}
    end;
parse_legacy(_, _Seq, _Acc) ->
    error.

parse_error(Seq, Reason) ->
    #{
        <<"seq">> => Seq,
        <<"error">> =>
            iolist_to_binary(io_lib:format("~p", [Reason]))
    }.

alg_size(16#0004) -> 20;  % SHA-1
alg_size(16#000B) -> 32;  % SHA-256
alg_size(16#000C) -> 48;  % SHA-384
alg_size(16#000D) -> 64;  % SHA-512
alg_size(16#0012) -> 32;  % SM3-256
alg_size(_) -> 0.

alg_name(16#0004) -> <<"sha1">>;
alg_name(16#000B) -> <<"sha256">>;
alg_name(16#000C) -> <<"sha384">>;
alg_name(16#000D) -> <<"sha512">>;
alg_name(16#0012) -> <<"sm3-256">>;
alg_name(Alg) ->
    iolist_to_binary(io_lib:format("alg-0x~.16B", [Alg])).

%%%============================================================================
%%% Narrow semantic decoders
%%%============================================================================

decode_events(Events) when is_map(Events) ->
    maps:map(
        fun(_K, V) when is_map(V) -> decode_event(V);
           (_K, V) -> V
        end,
        Events);
decode_events(Other) ->
    Other.

decode_event(Event = #{<<"event-type-code">> := Code}) ->
    Event#{<<"parsed">> => decode_event_data(Code, Event)};
decode_event(Other) ->
    Other.

decode_event_data(16#80000001, Event) ->
    decode_uefi_variable(Event);
decode_event_data(16#80000002, Event) ->
    decode_uefi_variable(Event);
decode_event_data(16#800000E0, Event) ->
    decode_uefi_variable(Event);
decode_event_data(3, #{<<"event-data">> := <<"Spec ID Event03", 0, _/binary>>}) ->
    #{<<"kind">> => <<"spec-id">>};
decode_event_data(3, #{<<"event-data">> := <<"StartupLocality", 0, L:8, _/binary>>}) ->
    #{<<"kind">> => <<"startup-locality">>, <<"locality">> => L};
decode_event_data(5, #{<<"event-data">> := Data}) ->
    #{<<"text">> => printable_or_hash(Data)};
decode_event_data(16#80000007, #{<<"event-data">> := Data}) ->
    #{<<"text">> => printable_or_hash(Data)};
decode_event_data(_, _) ->
    #{}.

boot_signals(<<>>) ->
    #{};
boot_signals(LogBin) when is_binary(LogBin) ->
    Events =
        [Ev || {_K, Ev} <- lists:sort(maps:to_list(decode_events(parse(LogBin)))),
               is_map(Ev),
               not maps:is_key(<<"error">>, Ev)],
    case [Ev || Ev <- Events, measured_variable_name(Ev) =:= <<"SecureBoot">>] of
        [] ->
            #{<<"secure-boot">> => #{<<"enabled">> => <<"unknown">>}};
        [Ev | _] ->
            Sem = nested_get(Ev, [<<"parsed">>, <<"semantic">>], #{}),
            #{
                <<"secure-boot">> => #{
                    <<"enabled">> =>
                        maps:get(
                            <<"secure-boot-enabled">>, Sem, <<"unknown">>),
                    <<"provenance">> => #{
                        <<"seq">> => maps:get(<<"seq">>, Ev, null),
                        <<"pcr">> => maps:get(<<"pcr">>, Ev, null),
                        <<"event-type">> =>
                            maps:get(<<"event-type">>, Ev, null)
                    }
                }
            }
    end.

measured_variable_name(Event) ->
    nested_get(Event, [<<"parsed">>, <<"variable-name">>], <<>>).

decode_uefi_variable(#{<<"event-data">> := Data}) ->
    case Data of
        <<Guid:16/binary, NameLen:64/little, DataLen:64/little, Rest/binary>> ->
            NameBytes = NameLen * 2,
            case Rest of
                <<NameUtf16:NameBytes/binary, VarData:DataLen/binary,
                  _/binary>> ->
                    Name = utf16le(NameUtf16),
                    #{
                        <<"variable-guid">> => guid(Guid),
                        <<"variable-name">> => Name,
                        <<"variable-data">> => VarData,
                        <<"variable-data-length">> => DataLen,
                        <<"semantic">> =>
                            uefi_variable_semantic(Name, VarData)
                    };
                _ ->
                    #{<<"error">> => <<"truncated UEFI variable">>}
            end;
        _ ->
            #{<<"error">> => <<"event data is not a UEFI variable">>}
    end;
decode_uefi_variable(_) ->
    #{}.

uefi_variable_semantic(<<"SecureBoot">>, <<1>>) ->
    #{<<"secure-boot-enabled">> => true};
uefi_variable_semantic(<<"SecureBoot">>, <<0>>) ->
    #{<<"secure-boot-enabled">> => false};
uefi_variable_semantic(<<"SecureBoot">>, _) ->
    #{<<"secure-boot-enabled">> => <<"malformed">>};
uefi_variable_semantic(<<"SetupMode">>, <<B:8>>) ->
    #{<<"setup-mode">> => B =:= 1};
uefi_variable_semantic(<<"AuditMode">>, <<B:8>>) ->
    #{<<"audit-mode">> => B =:= 1};
uefi_variable_semantic(<<"DeployedMode">>, <<B:8>>) ->
    #{<<"deployed-mode">> => B =:= 1};
uefi_variable_semantic(Name, Data)
        when Name =:= <<"PK">>; Name =:= <<"KEK">>;
             Name =:= <<"db">>; Name =:= <<"dbx">>;
             Name =:= <<"MokList">>; Name =:= <<"MokListX">>;
             Name =:= <<"MokListRT">>; Name =:= <<"MokListXRT">> ->
    #{
        <<"data-sha256">> => hb_util:encode(crypto:hash(sha256, Data)),
        <<"data-length">> => byte_size(Data)
    };
uefi_variable_semantic(<<"BootCurrent">>, <<N:16/little>>) ->
    #{<<"boot-current">> => boot_var(N)};
uefi_variable_semantic(<<"BootNext">>, <<N:16/little>>) ->
    #{<<"boot-next">> => boot_var(N)};
uefi_variable_semantic(<<"BootOrder">>, Data)
        when byte_size(Data) > 0, byte_size(Data) rem 2 =:= 0 ->
    #{
        <<"boot-order">> => [boot_var(N) || <<N:16/little>> <= Data],
        <<"boot-order-count">> => byte_size(Data) div 2
    };
uefi_variable_semantic(_, _) ->
    #{}.

boot_var(N) ->
    iolist_to_binary(io_lib:format("Boot~4.16.0B", [N])).

%%%============================================================================
%%% ACPI + small exported compatibility helpers
%%%============================================================================

parse_acpi_table(<<Sig:4/binary, Length:32/little, Rev:8, Checksum:8,
                   OemId:6/binary, OemTableId:8/binary,
                   OemRev:32/little, CreatorId:4/binary,
                   CreatorRev:32/little, _/binary>> = Bin)
        when byte_size(Bin) >= 36 ->
    #{
        <<"table-signature">> => Sig,
        <<"table-signature-name">> => acpi_signature_name(Sig),
        <<"length">> => Length,
        <<"revision">> => Rev,
        <<"checksum">> => Checksum,
        <<"oem-id">> => strip_zeros(OemId),
        <<"oem-table-id">> => strip_zeros(OemTableId),
        <<"oem-revision">> => OemRev,
        <<"creator-id">> => strip_zeros(CreatorId),
        <<"creator-revision">> => CreatorRev
    };
parse_acpi_table(_) ->
    #{<<"error">> => <<"not an ACPI table header">>}.

parse_acpi_rsdp(<<"RSD PTR ", Checksum:8, OemId:6/binary,
                  Rev:8, RsdtAddr:32/little, Rest/binary>>) ->
    Base = #{
        <<"table-signature">> => <<"RSD PTR ">>,
        <<"checksum">> => Checksum,
        <<"oem-id">> => strip_zeros(OemId),
        <<"revision">> => Rev,
        <<"rsdt-address">> => RsdtAddr
    },
    case {Rev, Rest} of
        {V, <<Length:32/little, XsdtAddr:64/little,
              ExtChecksum:8, _Reserved:3/binary, _/binary>>}
                when V >= 2 ->
            Base#{
                <<"length">> => Length,
                <<"xsdt-address">> => XsdtAddr,
                <<"extended-checksum">> => ExtChecksum
            };
        _ ->
            Base
    end;
parse_acpi_rsdp(_) ->
    #{<<"error">> => <<"not an ACPI RSDP">>}.

%%%============================================================================
%%% Names + small utilities
%%%============================================================================

with_event_type(Ev = #{<<"event-type-code">> := Code}) ->
    Ev#{<<"event-type">> => static_event_type_name(Code)};
with_event_type(Ev) ->
    Ev.

static_event_type_name(16#1) -> <<"EV_POST_CODE">>;
static_event_type_name(16#3) -> <<"EV_NO_ACTION">>;
static_event_type_name(16#4) -> <<"EV_SEPARATOR">>;
static_event_type_name(16#5) -> <<"EV_ACTION">>;
static_event_type_name(16#6) -> <<"EV_EVENT_TAG">>;
static_event_type_name(16#7) -> <<"EV_S_CRTM_CONTENTS">>;
static_event_type_name(16#8) -> <<"EV_S_CRTM_VERSION">>;
static_event_type_name(16#9) -> <<"EV_CPU_MICROCODE">>;
static_event_type_name(16#80000001) -> <<"EV_EFI_VARIABLE_DRIVER_CONFIG">>;
static_event_type_name(16#80000002) -> <<"EV_EFI_VARIABLE_BOOT">>;
static_event_type_name(16#80000003) -> <<"EV_EFI_BOOT_SERVICES_APPLICATION">>;
static_event_type_name(16#80000004) -> <<"EV_EFI_BOOT_SERVICES_DRIVER">>;
static_event_type_name(16#80000005) -> <<"EV_EFI_RUNTIME_SERVICES_DRIVER">>;
static_event_type_name(16#80000007) -> <<"EV_EFI_ACTION">>;
static_event_type_name(16#8000000B) -> <<"EV_EFI_HANDOFF_TABLES2">>;
static_event_type_name(16#800000E0) -> <<"EV_EFI_VARIABLE_AUTHORITY">>;
static_event_type_name(Code) ->
    iolist_to_binary(io_lib:format("EV_UNKNOWN_0x~.16B", [Code])).

acpi_signature_name(<<"RSDT">>) -> <<"Root System Description Table">>;
acpi_signature_name(<<"XSDT">>) -> <<"Extended System Description Table">>;
acpi_signature_name(<<"FACP">>) -> <<"Fixed ACPI Description Table">>;
acpi_signature_name(<<"FACS">>) -> <<"Firmware ACPI Control Structure">>;
acpi_signature_name(<<"DSDT">>) -> <<"Differentiated System Description Table">>;
acpi_signature_name(<<"SSDT">>) -> <<"Secondary System Description Table">>;
acpi_signature_name(<<"APIC">>) -> <<"Multiple APIC Description Table">>;
acpi_signature_name(<<"BGRT">>) -> <<"Boot Graphics Resource Table">>;
acpi_signature_name(<<"DMAR">>) -> <<"DMA Remapping Table">>;
acpi_signature_name(<<"MSDM">>) -> <<"Microsoft Data Management Table">>;
acpi_signature_name(<<"RSD PTR ">>) -> <<"Root System Description Pointer">>;
acpi_signature_name(Sig) ->
    iolist_to_binary(io_lib:format("ACPI table ~s", [Sig])).

index_map(Events) ->
    maps:from_list(
        [{integer_to_binary(maps:get(<<"seq">>, Ev, I)), Ev}
         || {I, Ev} <- lists:zip(lists:seq(1, length(Events)), Events)]).

nested_get(M, [], _Default) ->
    M;
nested_get(M, [K | Rest], Default) when is_map(M) ->
    case maps:get(K, M, undefined) of
        undefined -> Default;
        V -> nested_get(V, Rest, Default)
    end;
nested_get(_, _, Default) ->
    Default.

utf16le(Bin) ->
    try strip_zeros(unicode:characters_to_binary(Bin, {utf16, little}, utf8)) of
        V -> V
    catch
        _:_ -> strip_zeros(Bin)
    end.

guid(<<A:32/little, B:16/little, C:16/little, D:2/binary, E:6/binary>>) ->
    iolist_to_binary(
        io_lib:format(
            "~8.16.0B-~4.16.0B-~4.16.0B-~s-~s",
            [A, B, C, hex(D), hex(E)]));
guid(Bin) ->
    hex(Bin).

hex(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0B", [B]) || <<B:8>> <= Bin]).

strip_zeros(Bin) when is_binary(Bin) ->
    list_to_binary(lists:reverse(drop_zeros(lists:reverse(binary_to_list(Bin)))));
strip_zeros(Other) ->
    Other.

drop_zeros([0 | Rest]) -> drop_zeros(Rest);
drop_zeros([$\s | Rest]) -> drop_zeros(Rest);
drop_zeros(Rest) -> Rest.

printable_or_hash(Bin) ->
    Stripped = strip_zeros(Bin),
    case printable(Stripped) of
        true -> Stripped;
        false ->
            #{<<"sha256">> => hb_util:encode(crypto:hash(sha256, Bin)),
              <<"length">> => byte_size(Bin)}
    end.

printable(<<>>) ->
    true;
printable(<<C, Rest/binary>>) when C >= 32, C < 127 ->
    printable(Rest);
printable(_) ->
    false.

fmt_error(Err) ->
    iolist_to_binary(io_lib:format("~p", [Err])).
