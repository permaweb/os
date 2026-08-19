%%% @doc Minimal TCG event-log helpers for LapEE.
%%%
%%% LapEE keeps the full firmware log as evidence, but the runtime verifier only
%%% needs four pieces locally: parse events well enough to replay PCRs, extract
%%% the measured Secure Boot variable, summarize measured boot-image events,
%%% and decode ACPI table headers for `~system@1.0'.  Broader interpretation
%%% belongs in external
%%% analysis tools, not in the boot appliance.
-module(lib_lapee_tpm_tcg).
-export([boot_signals/1, boot_signals/2,
         boot_signals_from_events/1, boot_signals_from_events/2,
         decoded_events/1, decoded_events_with_errors/1,
         replay_pcrs/2, replay_pcrs_from_events/2, parse_acpi_table/1,
         parse_acpi_rsdp/1]).

%%%============================================================================
%%% Event-log parsing
%%%============================================================================

parse(Bin) when is_binary(Bin) ->
    case parse_first_record(Bin) of
        {ok, First, Algs, Rest} ->
            {Events, _Tail} = parse_crypto_agile(Rest, Algs, 2, [First]),
            index_map(Events);
        {error, _} = Err ->
            case parse_legacy(Bin, 1, []) of
                {ok, Events} ->
                    index_map(Events);
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
decode_event_data(16#0000000D, #{<<"event-data">> := Data}) ->
    #{<<"text">> => event_text(Data)};
decode_event_data(16#80000007, #{<<"event-data">> := Data}) ->
    #{<<"text">> => event_text(Data)};
decode_event_data(_, _) ->
    #{}.

boot_signals(<<>>) ->
    #{};
boot_signals(LogBin) when is_binary(LogBin) ->
    boot_signals(LogBin, #{}).

boot_signals(<<>>, _Opts) ->
    #{};
boot_signals(LogBin, Opts) when is_binary(LogBin) ->
    boot_signals_from_events(decoded_events(LogBin), Opts).

boot_signals_from_events(Events) when is_list(Events) ->
    boot_signals_from_events(Events, #{}).

boot_signals_from_events(Events, Opts) when is_list(Events) ->
    SecureBoot = secure_boot_signal(Events),
    SecureBootPolicy = secure_boot_policy_signal(Events, Opts),
    LoadedImage = loaded_image_signal(Events, Opts),
    Signals = #{<<"secure-boot">> => SecureBoot},
    Signals2 = maybe_signal(
        <<"secure-boot-policy">>, SecureBootPolicy, Signals),
    maybe_signal(<<"loaded-image">>, LoadedImage, Signals2).

maybe_signal(_Key, Signal, Signals) when map_size(Signal) =:= 0 ->
    Signals;
maybe_signal(Key, Signal, Signals) ->
    Signals#{Key => Signal}.

secure_boot_signal(Events) ->
    case [Ev || Ev <- Events, measured_variable_name(Ev) =:= <<"SecureBoot">>] of
        [] ->
            #{<<"enabled">> => <<"unknown">>};
        [Ev | _] ->
            Sem = nested_get(Ev, [<<"parsed">>, <<"semantic">>], #{}),
            #{
                <<"enabled">> =>
                    maps:get(
                        <<"secure-boot-enabled">>, Sem, <<"unknown">>),
                <<"provenance">> => #{
                    <<"seq">> => maps:get(<<"seq">>, Ev, null),
                    <<"pcr">> => maps:get(<<"pcr">>, Ev, null),
                    <<"event-type-code">> =>
                        maps:get(<<"event-type-code">>, Ev, null)
                }
            }
    end.

secure_boot_policy_signal(Events, Opts) ->
    Vars = secure_boot_policy_variables(Events, Opts),
    case map_size(Vars) of
        0 ->
            #{};
        _ ->
            Db = maps:get(<<"db">>, Vars, #{}),
            ImageSigners = maps:get(<<"signers">>, Db, #{}),
            Base = #{
                <<"source">> => <<"tcg-event-log">>,
                <<"status">> => <<"measured">>,
                <<"variables">> => Vars,
                <<"image-signers">> => ImageSigners,
                <<"image-signer-count">> =>
                    maps:get(<<"signer-count">>, Db, 0),
                <<"image-signers-digest">> =>
                    maps:get(<<"signer-digest">>, Db, stable_digest(#{}, Opts)),
                <<"image-signers-digest-algorithm">> =>
                    <<"ao-core-uncommitted-message-id-v1">>
            },
            case maps:get(<<"dbx">>, Vars, undefined) of
                undefined -> Base;
                Dbx ->
                    Base#{<<"revocations-digest">> =>
                        maps:get(
                            <<"signer-digest">>, Dbx, stable_digest(#{}, Opts))}
            end
    end.

secure_boot_policy_variables(Events, Opts) ->
    PolicyEvents =
        [Ev || Ev <- Events,
               event_pcr(Ev) =:= 7,
               event_type(Ev) =:= 16#80000001,
               lists:member(
                   measured_variable_name(Ev),
                   [<<"PK">>, <<"KEK">>, <<"db">>, <<"dbx">>])],
    maps:map(
        fun(_Name, Ev) -> signature_database_summary(Ev, Opts) end,
        lists:foldl(
            fun(Ev, Acc) ->
                Acc#{policy_variable_key(measured_variable_name(Ev)) => Ev}
            end,
            #{},
            PolicyEvents)).

policy_variable_key(<<"PK">>) -> <<"pk">>;
policy_variable_key(<<"KEK">>) -> <<"kek">>;
policy_variable_key(Name) -> Name.

signature_database_summary(Ev, Opts) ->
    Data = nested_get(Ev, [<<"parsed">>, <<"variable-data">>], <<>>),
    Entries = parse_signature_database(Data),
    Signers = indexed_signers(Entries),
    #{
        <<"signer-count">> => length(Entries),
        <<"signer-digest">> => stable_digest(Signers, Opts),
        <<"signers">> => Signers,
        <<"provenance">> => #{
            <<"seq">> => maps:get(<<"seq">>, Ev, null),
            <<"pcr">> => event_pcr(Ev),
            <<"event-type-code">> => event_type(Ev),
            <<"sha256">> => event_sha256(Ev)
        }
    }.

parse_signature_database(Bin) when is_binary(Bin) ->
    parse_signature_lists(Bin, []);
parse_signature_database(_) ->
    [].

parse_signature_lists(<<>>, Acc) ->
    lists:reverse(Acc);
parse_signature_lists(<<Type:16/binary, ListSize:32/little,
                        HeaderSize:32/little, SigSize:32/little,
                        Rest/binary>>, Acc)
        when ListSize >= 28, SigSize >= 16,
             ListSize - 28 =< byte_size(Rest),
             HeaderSize =< ListSize - 28 ->
    EntriesSize = ListSize - 28 - HeaderSize,
    case Rest of
        <<_Header:HeaderSize/binary, EntriesBin:EntriesSize/binary,
          Tail/binary>> ->
            parse_signature_lists(
                Tail,
                parse_signature_entries(Type, SigSize, EntriesBin, Acc));
        _ ->
            lists:reverse(Acc)
    end;
parse_signature_lists(_Malformed, Acc) ->
    lists:reverse(Acc).

parse_signature_entries(_Type, _SigSize, <<>>, Acc) ->
    Acc;
parse_signature_entries(Type, SigSize, Bin, Acc)
        when byte_size(Bin) >= SigSize ->
    <<Owner:16/binary, Data:(SigSize - 16)/binary, Rest/binary>> = Bin,
    parse_signature_entries(
        Type,
        SigSize,
        Rest,
        [signature_entry(Type, Owner, Data) | Acc]);
parse_signature_entries(_Type, _SigSize, _Tail, Acc) ->
    Acc.

signature_entry(TypeGuid, OwnerGuid, Data) ->
    Type = signature_type(guid(TypeGuid)),
    #{
        <<"type">> => Type,
        <<"owner">> => guid(OwnerGuid),
        <<"size">> => byte_size(Data),
        <<"sha256">> => hb_util:encode(crypto:hash(sha256, Data))
    }.

signature_type(<<"A5C059A1-94E4-4AA7-87B5-AB155C2BF072">>) ->
    <<"x509">>;
signature_type(<<"C1C41626-504C-4092-ACA9-41F936934328">>) ->
    <<"sha256">>;
signature_type(<<"3BD2A492-96C0-4079-B420-FCF98EF103ED">>) ->
    <<"x509-sha256">>;
signature_type(<<"E2B36190-879B-4A3D-AD8D-F2E7BBA32784">>) ->
    <<"rsa2048-sha256">>;
signature_type(<<"3C5766E8-269C-4E34-AA14-ED776E85B3B6">>) ->
    <<"rsa2048">>;
signature_type(Guid) ->
    Guid.

indexed_signers(Entries) ->
    maps:from_list(
        [{integer_to_binary(I), Entry}
         || {I, Entry} <- lists:zip(lists:seq(1, length(Entries)), Entries)]).

decoded_events(LogBin) ->
    {Events, _Errors} = decoded_events_with_errors(LogBin),
    Events.

decoded_events_with_errors(LogBin) ->
    Decoded =
        [
            Ev
         || {_K, Ev} <- lists:sort(maps:to_list(decode_events(parse(LogBin)))),
            is_map(Ev)
        ],
    {
        [Ev || Ev <- Decoded, not maps:is_key(<<"error">>, Ev)],
        [Ev || Ev <- Decoded, maps:is_key(<<"error">>, Ev)]
    }.

loaded_image_signal(Events, Opts) ->
    Apps = [Ev || Ev <- Events,
                  event_pcr(Ev) =:= 4,
                  has_sha256(Ev)],
    Uki = [Ev || Ev <- Events,
                 event_pcr(Ev) =:= 11,
                 has_sha256(Ev)],
    case {Apps, Uki} of
        {[], []} ->
            #{};
        _ ->
            Components = #{
                <<"efi-application">> =>
                    last_component(Apps),
                <<"uki-events">> =>
                    indexed_components(Uki)
            },
            #{
                <<"components-digest">> => stable_digest(Components, Opts),
                <<"components-digest-algorithm">> =>
                    <<"ao-core-uncommitted-message-id-v1">>,
                <<"source">> => <<"tcg-event-log">>,
                <<"status">> => <<"measured">>,
                <<"components">> => Components,
                <<"provenance">> => #{
                    <<"efi-application-events">> =>
                        indexed_event_provenance(Apps),
                    <<"uki-events">> =>
                        indexed_event_provenance(Uki)
                }
            }
    end.

last_component([]) ->
    #{};
last_component(Events) ->
    event_component(lists:last(Events)).

indexed_components(Events) ->
    maps:from_list(
        [{integer_to_binary(I), event_component(Ev)}
         || {I, Ev} <- lists:zip(lists:seq(1, length(Events)), Events)]).

indexed_event_provenance(Events) ->
    maps:from_list(
        [{integer_to_binary(I), event_provenance(Ev)}
         || {I, Ev} <- lists:zip(lists:seq(1, length(Events)), Events)]).

event_component(Ev) ->
    Base = #{
        <<"pcr">> => event_pcr(Ev),
        <<"event-type-code">> => event_type(Ev),
        <<"sha256">> => event_sha256(Ev)
    },
    case parsed_event_text(Ev) of
        <<>> -> Base;
        Text -> Base#{<<"text">> => Text}
    end.

event_provenance(Ev) ->
    #{
        <<"seq">> => maps:get(<<"seq">>, Ev, null),
        <<"pcr">> => event_pcr(Ev),
        <<"event-type-code">> => event_type(Ev),
        <<"sha256">> => event_sha256(Ev),
        <<"event-data-sha256">> =>
            hb_util:encode(
                crypto:hash(
                    sha256,
                    maps:get(<<"event-data">>, Ev, <<>>)))
    }.

stable_digest(Msg, Opts) ->
    hb_message:id(
        hb_message:uncommitted_deep(Msg, Opts),
        uncommitted,
        Opts).

replay_pcrs(LogBin, Pcrs) when is_binary(LogBin), is_list(Pcrs) ->
    replay_pcrs_from_events(decoded_events(LogBin), Pcrs);
replay_pcrs(_, Pcrs) when is_list(Pcrs) ->
    maps:from_list([{Pcr, hb_util:encode(<<0:256>>)} || Pcr <- Pcrs]).

replay_pcrs_from_events(Events, Pcrs) when is_list(Events), is_list(Pcrs) ->
    Wanted = maps:from_list([{Pcr, <<0:256>>} || Pcr <- Pcrs]),
    Replayed =
        lists:foldl(
            fun replay_event/2,
            Wanted,
            [Ev || Ev <- Events, has_sha256(Ev)]),
    maps:map(fun(_Pcr, Digest) -> hb_util:encode(Digest) end, Replayed);
replay_pcrs_from_events(_, Pcrs) when is_list(Pcrs) ->
    maps:from_list([{Pcr, hb_util:encode(<<0:256>>)} || Pcr <- Pcrs]).

replay_event(Ev, Acc) ->
    Pcr = event_pcr(Ev),
    case {maps:is_key(Pcr, Acc), is_spec_id_event(Ev)} of
        {true, true} ->
            Acc;
        {true, _} ->
            Old = maps:get(Pcr, Acc),
            Acc#{Pcr => crypto:hash(sha256, <<Old/binary, (raw_sha256(Ev))/binary>>)};
        _ ->
            Acc
    end.

is_spec_id_event(#{<<"event-data">> := <<"Spec ID Event03", _/binary>>}) ->
    true;
is_spec_id_event(_) ->
    false.

has_sha256(Ev) ->
    is_binary(raw_sha256(Ev)).

event_sha256(Ev) ->
    hb_util:encode(raw_sha256(Ev)).

raw_sha256(Ev) ->
    nested_get(Ev, [<<"digests">>, <<"sha256">>], undefined).

event_pcr(Ev) ->
    maps:get(<<"pcr">>, Ev, null).

event_type(Ev) ->
    maps:get(<<"event-type-code">>, Ev, null).

parsed_event_text(Ev) ->
    nested_get(Ev, [<<"parsed">>, <<"text">>], <<>>).

event_text(Bin) when is_binary(Bin) ->
    Text = utf16le(Bin),
    case printable_text(Text) of
        true -> Text;
        false -> ascii_text(Bin)
    end;
event_text(_) ->
    <<>>.

ascii_text(Bin) ->
    Text = strip_zeros(Bin),
    case printable_text(Text) of
        true -> Text;
        false -> <<>>
    end.

printable_text(<<>>) ->
    false;
printable_text(Bin) when is_binary(Bin), byte_size(Bin) =< 128 ->
    lists:all(
        fun(C) -> C =:= $\n orelse C =:= $\r orelse C =:= $\t orelse
                  (C >= 32 andalso C =< 126) end,
        binary_to_list(Bin));
printable_text(_) ->
    false.

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
uefi_variable_semantic(_, _) ->
    #{}.

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

fmt_error(Err) ->
    iolist_to_binary(io_lib:format("~p", [Err])).
