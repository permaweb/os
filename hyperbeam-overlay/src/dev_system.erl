%%% @doc `~system@1.0' -- structured hardware/runtime evidence.
%%%
%%% The device returns a nested AO-Core message describing what this LapEE
%%% runtime observed about the host. It is deliberately neutral: it collects
%%% and parses facts from read-only kernel/userspace interfaces, but does not
%%% assert policy or trust.
-module(dev_system).
-export([info/1, info/3, all/3]).
-export([report_from_root/1]).
-include_lib("kernel/include/file.hrl").
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(EFI_GLOBAL_VARIABLE_GUID, "8be4df61-93ca-11d2-aa0d-00e098032b8c").
-define(MTL_MEM_SS_INFO_GLOBAL, 16#45700).
-define(MSR_BOOT_GUARD_SACM_INFO, 16#13a).
%%%============================================================================
%%% Device surface
%%%============================================================================

info(_) ->
    #{exports => [<<"info">>, <<"all">>]}.

info(_Base, _Req, _Opts) ->
    {ok, #{
        <<"status">> => 200,
        <<"body">> => #{
            <<"description">> =>
                <<"Structured system evidence device. Returns a live report "
                  "from generic read-only /proc and /sys interfaces.">>,
            <<"version">> => <<"1.0">>,
            <<"api">> => #{
                <<"all">> => #{
                    <<"description">> =>
                        <<"Return a nested machine report. Stable secrets "
                          "and operator identifiers are redacted; every probe "
                          "records source, method, status, raw values where "
                          "available, and parse errors without making "
                          "trust-policy claims.">>
                }
            }
        }
    }}.

all(_Base, _Req, _Opts) ->
    {ok, #{<<"status">> => 200, <<"body">> => report_from_root(root())}}.

%%%============================================================================
%%% Report assembly
%%%============================================================================

report_from_root(Root0) ->
    Root = normalise_root(Root0),
    BootGuard = boot_guard_report(Root),
    Edac = edac_report(Root),
    MemoryController = memory_controller_probe_report(Root, Edac),
    #{
        <<"device">> => <<"system@1.0">>,
        <<"schema">> => <<"lapee-system-report@1">>,
        <<"version">> => <<"1.0">>,
        <<"probed-at-unix">> => erlang:system_time(second),
        <<"evidence-model">> => evidence_model(),
        <<"boot">> => boot_report(Root),
        <<"kernel">> => kernel_report(Root),
        <<"cpu">> => cpu_report(Root),
        <<"memory">> => memory_report(Root, Edac, MemoryController),
        <<"firmware">> => firmware_report(Root, BootGuard),
        <<"hardware-probes">> => hardware_probes_report(BootGuard, MemoryController),
        <<"tpm">> => tpm_report(Root),
        <<"iommu">> => iommu_report(Root),
        <<"integrity">> => integrity_report(Root),
        <<"devices">> => devices_report(Root),
        <<"filesystems">> => filesystems_report(Root)
    }.

evidence_model() ->
    #{
        <<"purpose">> =>
            <<"collect-and-parse-evidence">>,
        <<"policy">> =>
            <<"No field in this report declares itself trusted. Consumers "
              "must apply their own policy to source, method, raw, decoded, "
              "and status fields.">>,
        <<"probe-families">> => [
            <<"cpu/cpuid-device">>,
            <<"firmware/boot-guard/msr">>,
            <<"firmware/acpi/sysfs-table-hashes">>,
            <<"memory-controller/intel-drm-kernel-dram-info/sysfs">>,
            <<"memory-controller/intel-mtl-mem-ss-info-global/resource0-read">>,
            <<"memory-controller/sysfs-edac">>,
            <<"generic-proc-sysfs">>
        ],
        <<"redactions">> => [
            <<"dmi/product-uuid">>,
            <<"dmi/product-serial">>,
            <<"dmi/board-serial">>,
            <<"dmi/chassis-serial">>,
            <<"network/hardware-address">>
        ]
    }.

boot_report(Root) ->
    #{
        <<"loaded-uki">> => loaded_uki_report(Root)
    }.

loaded_uki_report(Root) ->
    Source = <<"/run/lapee/boot-uki-sha256">>,
    case read_trim(Root, binary_to_list(Source)) of
        null ->
            #{
                <<"available">> => false,
                <<"source">> => Source,
                <<"sha256">> => null,
                <<"status">> => <<"unavailable">>
            };
        Hex ->
            case sha256_hex_to_id(Hex) of
                {ok, ID} ->
                    #{
                        <<"available">> => true,
                        <<"source">> => Source,
                        <<"sha256">> => ID,
                        <<"status">> => <<"observed">>
                    };
                error ->
                    #{
                        <<"available">> => false,
                        <<"source">> => Source,
                        <<"sha256">> => null,
                        <<"status">> => <<"invalid-source-value">>
                    }
            end
    end.

kernel_report(Root) ->
    #{
        <<"ostype">> => read_trim(Root, "/proc/sys/kernel/ostype"),
        <<"osrelease">> => read_trim(Root, "/proc/sys/kernel/osrelease"),
        <<"version">> => read_trim(Root, "/proc/version"),
        <<"hostname">> => read_trim(Root, "/proc/sys/kernel/hostname"),
        <<"cmdline">> => read_trim(Root, "/proc/cmdline"),
        <<"modules">> => modules_report(Root)
    }.

cpu_report(Root) ->
    CpuInfo = cpuinfo_report(Root),
    #{
        <<"cpuinfo">> => CpuInfo,
        <<"cpuid">> => cpuid_report(Root),
        <<"sysfs">> => #{
            <<"possible">> =>
                read_trim(Root, "/sys/devices/system/cpu/possible"),
            <<"present">> =>
                read_trim(Root, "/sys/devices/system/cpu/present"),
            <<"online">> =>
                read_trim(Root, "/sys/devices/system/cpu/online"),
            <<"offline">> =>
                read_trim(Root, "/sys/devices/system/cpu/offline"),
            <<"smt">> => #{
                <<"active">> =>
                    read_trim(Root, "/sys/devices/system/cpu/smt/active"),
                <<"control">> =>
                    read_trim(Root, "/sys/devices/system/cpu/smt/control")
            },
            <<"vulnerabilities">> => vulnerabilities_report(Root)
        }
    }.

memory_report(Root, Edac, ControllerProbes) ->
    #{
        <<"meminfo">> => meminfo_report(Root),
        <<"sysfs-memory">> => sysfs_memory_report(Root),
        <<"edac">> => Edac,
        <<"controller-probes">> => ControllerProbes,
        <<"topology">> => #{
            <<"generic-edac">> => Edac,
            <<"controller-probes">> => ControllerProbes,
            <<"notes">> =>
                <<"Generic EDAC/sysfs memory data is included for "
                  "observability. Consumers decide which source/method/status "
                  "tuples satisfy their policy.">>
        }
    }.

firmware_report(Root, BootGuard) ->
    #{
        <<"dmi">> => dmi_report(Root),
        <<"acpi">> => acpi_report(Root),
        <<"efi">> => efi_report(Root),
        <<"boot-guard">> => BootGuard
    }.

hardware_probes_report(BootGuard, MemoryController) ->
    #{
        <<"schema">> => <<"lapee-hardware-probes@1">>,
        <<"boot-guard">> => BootGuard,
        <<"memory-controller">> => MemoryController,
        <<"collection">> => #{
            <<"userspace-pcode-mailbox-writes">> => false,
            <<"notes">> =>
                <<"This report surfaces observations and explicit unavailable "
                  "or unsupported states. It preserves source/method/status "
                  "for policy engines rather than assigning trust locally.">>
        }
    }.

tpm_report(Root) ->
    Devices = tpm_devices(Root),
    #{
        <<"available">> => Devices =/= [],
        <<"devices">> => Devices
    }.

iommu_report(Root) ->
    Base = "/sys/kernel/iommu_groups",
    Groups = digit_dirs(Root, Base),
    #{
        <<"available">> => dir_exists(Root, Base),
        <<"group-count">> => length(Groups),
        <<"groups">> =>
            [#{
                <<"id">> => to_bin(G),
                <<"devices">> =>
                    [to_bin(D) ||
                        D <- sorted_list_dir(
                            Root, filename:join([Base, G, "devices"]))]
            } || G <- Groups]
    }.

integrity_report(Root) ->
    #{
        <<"lockdown">> =>
            read_trim(Root, "/sys/kernel/security/lockdown"),
        <<"ima">> => #{
            <<"runtime-measurements-count">> =>
                read_trim(
                    Root,
                    "/sys/kernel/security/integrity/ima/"
                    "runtime_measurements_count"),
            <<"policy-present">> =>
                file_exists(
                    Root,
                    "/sys/kernel/security/integrity/ima/policy")
        }
    }.

devices_report(Root) ->
    #{
        <<"pci">> => pci_report(Root),
        <<"drm">> => drm_report(Root),
        <<"block">> => block_report(Root),
        <<"network">> => network_report(Root)
    }.

filesystems_report(Root) ->
    Mounts = mountinfo_report(Root),
    #{
        <<"mounts">> => Mounts,
        <<"mount-count">> => length(Mounts),
        <<"filesystem-types">> =>
            lists:usort(
                [maps:get(<<"filesystem-type">>, M)
                 || M <- Mounts,
                    maps:get(<<"filesystem-type">>, M, null) =/= null])
    }.

%%%============================================================================
%%% Individual probes
%%%============================================================================

modules_report(Root) ->
    case read_file(Root, "/proc/modules") of
        {ok, Bin} ->
            Names =
                [Name ||
                    Line <- binary:split(Bin, <<"\n">>, [global]),
                    Line =/= <<>>,
                    [Name | _] <- [binary:split(Line, <<" ">>, [])]],
            #{
                <<"count">> => length(Names),
                <<"names">> => Names
            };
        error ->
            #{<<"count">> => null, <<"names">> => []}
    end.

cpuinfo_report(Root) ->
    case read_file(Root, "/proc/cpuinfo") of
        {ok, Bin} ->
            Stanzas = non_empty(binary:split(Bin, <<"\n\n">>, [global])),
            First =
                case Stanzas of
                    [S | _] -> cpuinfo_stanza(S);
                    [] -> #{}
                end,
            Flags = split_words(maps:get(<<"flags">>, First, <<>>)),
            Bugs = split_words(maps:get(<<"bugs">>, First, <<>>)),
            #{
                <<"available">> => true,
                <<"logical-processor-count">> =>
                    length([ok || S <- Stanzas,
                                  maps:is_key(<<"processor">>,
                                              cpuinfo_stanza(S))]),
                <<"first-processor">> => First,
                <<"flags">> => Flags,
                <<"bugs">> => Bugs
            };
        error ->
            #{
                <<"available">> => false,
                <<"logical-processor-count">> => null,
                <<"first-processor">> => #{},
                <<"flags">> => [],
                <<"bugs">> => []
            }
    end.

cpuinfo_stanza(Bin) ->
    lists:foldl(
        fun line_to_kv/2,
        #{},
        binary:split(Bin, <<"\n">>, [global])).

cpuid_report(Root) ->
    Path = "/dev/cpu/0/cpuid",
    Leaves = [
        {16#00000000, 0},
        {16#00000001, 0},
        {16#00000007, 0},
        {16#80000000, 0},
        {16#80000001, 0}
    ],
    case file_exists(Root, Path) of
        true ->
            Results = [cpuid_leaf_report(Root, Path, Leaf, Subleaf)
                       || {Leaf, Subleaf} <- Leaves],
            #{
                <<"available">> => true,
                <<"source">> => <<"dev-cpu-cpuid">>,
                <<"interface">> => to_bin(Path),
                <<"leaves">> => Results,
                <<"notes">> =>
                    <<"CPUID leaves read through /dev/cpu/0/cpuid. The lower "
                      "32 bits of the file offset are EAX; the upper 32 bits "
                      "are ECX.">>
            };
        false ->
            #{
                <<"available">> => false,
                <<"source">> => <<"dev-cpu-cpuid">>,
                <<"interface">> => to_bin(Path),
                <<"error">> => <<"enoent">>,
                <<"leaves">> => []
            }
    end.

cpuid_leaf_report(Root, Path, Leaf, Subleaf) ->
    Common = #{
        <<"leaf">> => u32_hex(Leaf),
        <<"subleaf">> => u32_hex(Subleaf)
    },
    case read_cpuid_leaf(Root, Path, Leaf, Subleaf) of
        {ok, #{eax := Eax, ebx := Ebx, ecx := Ecx, edx := Edx}} ->
            Common#{
                <<"available">> => true,
                <<"registers">> => #{
                    <<"eax">> => u32_hex(Eax),
                    <<"ebx">> => u32_hex(Ebx),
                    <<"ecx">> => u32_hex(Ecx),
                    <<"edx">> => u32_hex(Edx)
                }
            };
        {error, Reason} ->
            Common#{
                <<"available">> => false,
                <<"error">> => to_bin(Reason)
            }
    end.

meminfo_report(Root) ->
    case read_file(Root, "/proc/meminfo") of
        {ok, Bin} ->
            lists:foldl(
                fun meminfo_line/2,
                #{},
                binary:split(Bin, <<"\n">>, [global]));
        error ->
            #{}
    end.

meminfo_line(Line, Acc) ->
    case binary:split(Line, <<":">>, []) of
        [Key, Val0] ->
            Val = trim(Val0),
            Tokens = split_words(Val),
            Parsed =
                case Tokens of
                    [NBin, Unit | _] ->
                        case parse_int(NBin) of
                            null -> #{<<"raw">> => Val};
                            N -> #{<<"value">> => N, <<"unit">> => Unit}
                        end;
                    [NBin] ->
                        case parse_int(NBin) of
                            null -> #{<<"raw">> => Val};
                            N -> #{<<"value">> => N}
                        end;
                    [] ->
                        #{<<"raw">> => Val}
                end,
            Acc#{normalise_key(Key) => Parsed};
        _ ->
            Acc
    end.

sysfs_memory_report(Root) ->
    Base = "/sys/devices/system/memory",
    Blocks = [B || B <- sorted_list_dir(Root, Base),
                   string:prefix(B, "memory") =/= nomatch,
                   dir_exists(Root, filename:join(Base, B))],
    BlockReports =
        [#{
            <<"name">> => to_bin(B),
            <<"state">> =>
                read_trim(Root, filename:join([Base, B, "state"])),
            <<"online">> =>
                read_trim(Root, filename:join([Base, B, "online"])),
            <<"removable">> =>
                read_trim(Root, filename:join([Base, B, "removable"])),
            <<"valid-zones">> =>
                read_trim(Root, filename:join([Base, B, "valid_zones"]))
        } || B <- Blocks],
    #{
        <<"available">> => dir_exists(Root, Base),
        <<"block-size-bytes">> =>
            read_trim(Root, filename:join(Base, "block_size_bytes")),
        <<"block-count">> => length(BlockReports),
        <<"blocks">> => BlockReports
    }.

edac_report(Root) ->
    Base = "/sys/devices/system/edac/mc",
    Controllers = [C || C <- sorted_list_dir(Root, Base),
                        string:prefix(C, "mc") =/= nomatch,
                        dir_exists(Root, filename:join(Base, C))],
    Reports = [edac_controller_report(Root, Base, C) || C <- Controllers],
    #{
        <<"available">> => Reports =/= [],
        <<"source">> => <<"sysfs-edac">>,
        <<"controllers">> => Reports
    }.

edac_controller_report(Root, Base, Controller) ->
    Path = filename:join(Base, Controller),
    Dimms = [D || D <- sorted_list_dir(Root, Path),
                  string:prefix(D, "dimm") =/= nomatch,
                  dir_exists(Root, filename:join(Path, D))],
    #{
        <<"name">> => to_bin(Controller),
        <<"mc-name">> => read_trim(Root, filename:join(Path, "mc_name")),
        <<"size-mb">> => read_trim(Root, filename:join(Path, "size_mb")),
        <<"ce-count">> => read_trim(Root, filename:join(Path, "ce_count")),
        <<"ue-count">> => read_trim(Root, filename:join(Path, "ue_count")),
        <<"dimms">> => [edac_dimm_report(Root, Path, D) || D <- Dimms]
    }.

edac_dimm_report(Root, ControllerPath, Dimm) ->
    Path = filename:join(ControllerPath, Dimm),
    #{
        <<"name">> => to_bin(Dimm),
        <<"label">> => read_trim(Root, filename:join(Path, "dimm_label")),
        <<"location">> =>
            read_trim(Root, filename:join(Path, "dimm_location")),
        <<"memory-type">> =>
            read_trim(Root, filename:join(Path, "dimm_mem_type")),
        <<"device-type">> =>
            read_trim(Root, filename:join(Path, "dimm_dev_type")),
        <<"edac-mode">> =>
            read_trim(Root, filename:join(Path, "dimm_edac_mode")),
        <<"size">> => read_trim(Root, filename:join(Path, "size")),
        <<"rank">> => read_trim(Root, filename:join(Path, "rank"))
    }.

memory_controller_probe_report(Root, Edac) ->
    IntelDrm = intel_drm_memory_probe(Root),
    #{
        <<"intel-drm-controller">> => IntelDrm,
        <<"generic-edac">> => edac_memory_probe(Edac),
        <<"notes">> =>
            <<"The Intel DRM probe prefers the kernel's DRAM decode export. "
              "That export is populated by the same controller-backed driver "
              "logic used for display bandwidth decisions. If the kernel "
              "export is absent, the report may include the older read-only "
              "Meteor Lake MMIO fallback. Generic EDAC is included as "
              "additional parsed evidence.">>
    }.

intel_drm_memory_probe(Root) ->
    Cards = intel_drm_memory_cards(Root),
    #{
        <<"available">> => Cards =/= [],
        <<"source">> => <<"sysfs-drm-pci">>,
        <<"cards">> => Cards,
        <<"lpddr-class-observed">> => any_lpddr_card(Cards),
        <<"notes">> =>
            <<"The preferred path consumes read-only sysfs files exported by "
              "the active Intel DRM driver. That gives controller-decoded "
              "DRAM evidence without reproducing PCODE/MCU transactions in "
              "userspace.">>
    }.

intel_drm_memory_cards(Root) ->
    Base = "/sys/class/drm",
    [intel_drm_memory_card_probe(Root, Base, Card)
     || Card <- sorted_list_dir(Root, Base),
        is_drm_card_name(Card),
        intel_drm_intel_card(Root, Base, Card)].

intel_drm_intel_card(Root, Base, Card) ->
    read_trim(Root, filename:join([Base, Card, "device", "vendor"])) =:=
        <<"0x8086">>.

intel_drm_memory_card_probe(Root, Base, Card) ->
    DevicePath = filename:join([Base, Card, "device"]),
    Common = #{
        <<"card">> => to_bin(Card),
        <<"driver">> => read_link_basename(Root, filename:join(DevicePath, "driver")),
        <<"pci">> => read_attr_map(
            Root,
            DevicePath,
            ["vendor", "device", "class", "subsystem_vendor",
             "subsystem_device", "revision"])
    },
    case intel_drm_kernel_dram_card_probe(Root, DevicePath, Common) of
        {ok, Report} -> Report;
        unavailable -> intel_mtl_resource0_memory_card_probe(Root, DevicePath, Common)
    end.

intel_drm_kernel_dram_card_probe(Root, DevicePath, Common) ->
    Raw = intel_drm_kernel_dram_raw(Root, DevicePath),
    case maps:get(<<"dram-type">>, Raw, null) of
        null ->
            unavailable;
        _ ->
            Decoded = intel_drm_kernel_dram_decode(Raw),
            {ok, Common#{
                <<"available">> => true,
                <<"status">> => intel_drm_kernel_dram_status(Decoded),
                <<"source">> => <<"drm-device-sysfs">>,
                <<"method">> => <<"intel-drm-kernel-dram-info">>,
                <<"raw">> => Raw,
                <<"decoded">> => Decoded
            }}
    end.

intel_drm_kernel_dram_raw(Root, DevicePath) ->
    read_attr_map(
        Root,
        DevicePath,
        ["dram_type", "dram_lpddr_class", "dram_num_channels",
         "dram_num_qgv_points", "dram_num_psf_gv_points",
         "dram_mem_freq_khz", "dram_fsb_freq_khz"]).

intel_drm_kernel_dram_decode(Raw) ->
    Type = normalise_dram_type(maps:get(<<"dram-type">>, Raw, <<"unknown">>)),
    #{
        <<"dram-type">> => Type,
        <<"lpddr-class">> => intel_drm_kernel_lpddr_value(Raw, Type),
        <<"populated-channels">> =>
            parse_int(maps:get(<<"dram-num-channels">>, Raw, null)),
        <<"enabled-qgv-points">> =>
            parse_int(maps:get(<<"dram-num-qgv-points">>, Raw, null)),
        <<"enabled-psf-gv-points">> =>
            parse_int(maps:get(<<"dram-num-psf-gv-points">>, Raw, null)),
        <<"memory-frequency-khz">> =>
            parse_int(maps:get(<<"dram-mem-freq-khz">>, Raw, null)),
        <<"fsb-frequency-khz">> =>
            parse_int(maps:get(<<"dram-fsb-freq-khz">>, Raw, null))
    }.

intel_drm_kernel_dram_status(#{<<"dram-type">> := <<"unknown">>}) ->
    <<"unknown">>;
intel_drm_kernel_dram_status(_) ->
    <<"observed">>.

intel_drm_kernel_lpddr_value(_Raw, <<"unknown">>) ->
    null;
intel_drm_kernel_lpddr_value(Raw, Type) ->
    parse_bool_01(maps:get(<<"dram-lpddr-class">>, Raw, null),
                  lpddr_type(Type)).

intel_mtl_resource0_memory_card_probe(Root, DevicePath, Common) ->
    Resource0 = filename:join(DevicePath, "resource0"),
    Resource0Info = #{
        <<"method">> => <<"intel-mtl-mem-ss-info-global">>,
        <<"register">> => #{
            <<"name">> => <<"MTL_MEM_SS_INFO_GLOBAL">>,
            <<"offset">> => u32_hex(?MTL_MEM_SS_INFO_GLOBAL)
        }
    },
    case read_uint_le_at(Root, Resource0, ?MTL_MEM_SS_INFO_GLOBAL, 4) of
        {ok, Raw} ->
            Status = intel_mtl_dram_status(Raw),
            (maps:merge(Common, Resource0Info))#{
                <<"available">> => true,
                <<"status">> => Status,
                <<"source">> => <<"resource0-read">>,
                <<"raw-hex">> => u32_hex(Raw),
                <<"decoded">> => intel_mtl_dram_decode(Raw)
            };
        {error, Reason} ->
            (maps:merge(Common, Resource0Info))#{
                <<"available">> => false,
                <<"status">> => <<"unavailable">>,
                <<"source">> => <<"resource0-read">>,
                <<"error">> => to_bin(Reason)
            }
    end.

intel_mtl_dram_decode(Raw) ->
    TypeCode = Raw band 16#f,
    Type = intel_dram_type_from_mtl_code(TypeCode),
    #{
        <<"dram-type-code">> => TypeCode,
        <<"dram-type">> => Type,
        <<"lpddr-class">> => lpddr_type(Type),
        <<"populated-channels">> => (Raw bsr 4) band 16#f,
        <<"enabled-qgv-points">> => (Raw bsr 8) band 16#f,
        <<"ecc-impacting-display-bandwidth">> => bit_set(Raw, 12)
    }.

intel_mtl_dram_status(Raw) ->
    Decoded = intel_mtl_dram_decode(Raw),
    case {maps:get(<<"dram-type">>, Decoded),
          maps:get(<<"populated-channels">>, Decoded)} of
        {<<"unknown">>, _} -> <<"invalid-decode">>;
        {_, 0} -> <<"invalid-decode">>;
        _ -> <<"observed">>
    end.

intel_dram_type_from_mtl_code(0) -> <<"DDR4">>;
intel_dram_type_from_mtl_code(1) -> <<"DDR5">>;
intel_dram_type_from_mtl_code(2) -> <<"LPDDR5">>;
intel_dram_type_from_mtl_code(3) -> <<"LPDDR4">>;
intel_dram_type_from_mtl_code(4) -> <<"DDR3">>;
intel_dram_type_from_mtl_code(5) -> <<"LPDDR3">>;
intel_dram_type_from_mtl_code(8) -> <<"GDDR">>;
intel_dram_type_from_mtl_code(9) -> <<"GDDR-ECC">>;
intel_dram_type_from_mtl_code(_) -> <<"unknown">>.

normalise_dram_type(Type) when is_binary(Type) ->
    case string:uppercase(trim(Type)) of
        <<"UNKNOWN">> -> <<"unknown">>;
        Upper -> binary:replace(Upper, <<"_">>, <<"-">>, [global])
    end;
normalise_dram_type(_) ->
    <<"unknown">>.

lpddr_type(Type) when is_binary(Type) ->
    lists:member(normalise_dram_type(Type),
                 [<<"LPDDR3">>, <<"LPDDR4">>, <<"LPDDR5">>]);
lpddr_type(_) ->
    false.

any_lpddr_card([]) ->
    null;
any_lpddr_card(Cards) ->
    case [Value || Card <- Cards,
                   Value <- [card_lpddr_value(Card)],
                   Value =/= null] of
        [] -> null;
        Values -> lists:member(true, Values)
    end.

card_lpddr_value(Card) ->
    Decoded = maps:get(<<"decoded">>, Card, #{}),
    case {maps:get(<<"status">>, Card, <<"unavailable">>),
          maps:get(<<"lpddr-class">>, Decoded, null)} of
        {<<"observed">>, true} -> true;
        {<<"observed">>, false} -> false;
        _ -> null
    end.

edac_memory_probe(Edac) ->
    Types = edac_memory_types(Edac),
    #{
        <<"available">> => maps:get(<<"available">>, Edac, false),
        <<"source">> => <<"sysfs-edac">>,
        <<"memory-types">> => Types,
        <<"lpddr-class-observed">> => edac_lpddr_observed(Types),
        <<"notes">> =>
            <<"EDAC is kernel-observed memory-controller state where a driver "
              "is present. Consumers decide how to use its taxonomy.">>
    }.

edac_memory_types(Edac) ->
    lists:usort(
        [Type
         || Controller <- maps:get(<<"controllers">>, Edac, []),
            Dimm <- maps:get(<<"dimms">>, Controller, []),
            Type <- [maps:get(<<"memory-type">>, Dimm, null)],
            Type =/= null]).

edac_lpddr_observed([]) ->
    null;
edac_lpddr_observed(Types) ->
    lists:any(fun edac_lpddr_type/1, Types).

edac_lpddr_type(Type) when is_binary(Type) ->
    Normal = string:lowercase(Type),
    binary:match(Normal, <<"lpddr">>) =/= nomatch orelse
        binary:match(Normal, <<"low-power-ddr">>) =/= nomatch;
edac_lpddr_type(_) ->
    false.

dmi_report(Root) ->
    Base = "/sys/class/dmi/id",
    Fields = [
        "sys_vendor",
        "product_name",
        "product_version",
        "product_family",
        "board_vendor",
        "board_name",
        "board_version",
        "bios_vendor",
        "bios_version",
        "bios_date",
        "bios_release",
        "chassis_type",
        "chassis_vendor",
        "chassis_version"
    ],
    Values =
        maps:from_list(
            [{normalise_key(to_bin(F)),
              read_trim(Root, filename:join(Base, F))}
             || F <- Fields]),
    #{
        <<"available">> =>
            lists:any(fun(V) -> V =/= null end, maps:values(Values)),
        <<"source">> => <<"sysfs-dmi">>,
        <<"fields">> => Values,
        <<"redacted-fields">> => [
            <<"product-uuid">>,
            <<"product-serial">>,
            <<"board-serial">>,
            <<"chassis-serial">>
        ]
    }.

acpi_report(Root) ->
    Base = "/sys/firmware/acpi/tables",
    DynamicBase = filename:join(Base, "dynamic"),
    Tables = acpi_tables_map(Root, Base),
    DynamicTables = acpi_tables_map(Root, DynamicBase),
    #{
        <<"available">> => dir_exists(Root, Base),
        <<"source">> => <<"sysfs-acpi">>,
        <<"tables">> => acpi_tables_namespace(Tables, DynamicTables),
        <<"table-counts">> => #{
            <<"final">> => maps:size(Tables),
            <<"dynamic">> => maps:size(DynamicTables)
        },
        <<"dynamic-table-directory-present">> =>
            dir_exists(Root, DynamicBase),
        <<"override-provenance">> =>
            acpi_override_provenance(Root, DynamicTables),
        <<"notes">> =>
            <<"ACPI tables are firmware-supplied platform descriptions as "
              "observed by this measured runtime through Linux sysfs. This "
              "report carries final table bytes by digest and parsed headers; "
              "it does not treat OEM/header fields as policy by itself.">>
    }.

acpi_tables_map(Root, Base) ->
    Entries =
        [{Name,
          acpi_path_key_base(Name),
          acpi_table_report(Root, filename:join(Base, Name), Name)}
         || Name <- sorted_list_dir(Root, Base),
            Name =/= "dynamic",
            not dir_exists(Root, filename:join(Base, Name))],
    KeyCounts =
        lists:foldl(
            fun({_Name, Key, _Report}, Counts) ->
                maps:update_with(Key, fun(N) -> N + 1 end, 1, Counts)
            end,
            #{},
            Entries),
    maps:from_list(
        [{acpi_path_key(Name, Key, KeyCounts), Report}
         || {Name, Key, Report} <- Entries]).

acpi_tables_namespace(Tables, DynamicTables) ->
    #{
        <<"sys">> => #{
            <<"firmware">> => #{
                <<"acpi">> => #{
                    <<"tables">> => Tables#{
                        <<"dynamic">> => DynamicTables
                    }
                }
            }
        }
    }.

acpi_table_report(Root, Path, Name) ->
    case read_file(Root, Path) of
        {ok, Bin} ->
            Header = acpi_table_header(Name, Bin),
            Report0 = #{
                <<"source">> => <<"sysfs-acpi-table">>,
                <<"source-path">> => to_bin(Path),
                <<"sysfs-name">> => to_bin(Name),
                <<"length-bytes">> => byte_size(Bin),
                <<"table-sha256">> =>
                    hb_util:encode(crypto:hash(sha256, Bin)),
                <<"header">> => Header
            },
            maps:merge(
                Report0,
                acpi_table_validation(Header, Bin));
        error ->
            #{
                <<"source">> => <<"sysfs-acpi-table">>,
                <<"source-path">> => to_bin(Path),
                <<"sysfs-name">> => to_bin(Name),
                <<"status">> => <<"unreadable">>
            }
    end.

acpi_path_key(Name) ->
    acpi_path_key(Name, acpi_path_key_base(Name), #{acpi_path_key_base(Name) => 1}).

acpi_path_key(Name, Key, KeyCounts) ->
    case maps:get(Key, KeyCounts) of
        1 -> Key;
        _ -> <<Key/binary, "-b32-", (acpi_base32_key(Name))/binary>>
    end.

acpi_path_key_base(Name) ->
    Key = iolist_to_binary([acpi_key_byte(B) || <<B:8>> <= to_bin(Name)]),
    case Key of
        <<>> -> <<"empty">>;
        _ -> Key
    end.

acpi_key_byte(B) when B >= $A, B =< $Z -> B + 32;
acpi_key_byte(B) when B >= $a, B =< $z -> B;
acpi_key_byte(B) when B >= $0, B =< $9 -> B;
acpi_key_byte(B) -> [<<"-x">>, byte_hex(B)].

byte_hex(B) ->
    iolist_to_binary(io_lib:format("~2.16.0b", [B])).

acpi_base32_key(Name) ->
    string:lowercase(
        binary:replace(base32:encode(to_bin(Name)), <<"=">>, <<>>, [global])).

acpi_table_header("RSDP", Bin) ->
    dev_tpm_tcg:parse_acpi_rsdp(Bin);
acpi_table_header("FACS", _Bin) ->
    #{
        <<"table-signature">> => <<"FACS">>,
        <<"table-signature-name">> => <<"Firmware ACPI Control Structure">>,
        <<"note">> => <<"FACS does not use the common ACPI table header.">>
    };
acpi_table_header(_Name, Bin) ->
    dev_tpm_tcg:parse_acpi_table(Bin).

acpi_table_validation(Header, Bin) ->
    Length = maps:get(<<"length">>, Header, null),
    Matches = acpi_declared_length_matches(Length, Bin),
    Checksum = acpi_checksum_valid(Length, Bin),
    #{
        <<"declared-length-matches-file">> => Matches,
        <<"checksum-valid">> => Checksum,
        <<"status">> => acpi_table_status(Header, Matches, Checksum)
    }.

acpi_declared_length_matches(Length, Bin) when is_integer(Length) ->
    Length =:= byte_size(Bin);
acpi_declared_length_matches(_, _Bin) ->
    null.

acpi_checksum_valid(Length, Bin)
  when is_integer(Length), Length > 0, Length =< byte_size(Bin) ->
    (lists:sum(binary_to_list(binary:part(Bin, 0, Length))) band 16#ff) =:= 0;
acpi_checksum_valid(_, _Bin) ->
    null.

acpi_table_status(Header, _Matches, _Checksum)
  when is_map_key(<<"error">>, Header) ->
    <<"unparsed">>;
acpi_table_status(_Header, false, _Checksum) ->
    <<"length-mismatch">>;
acpi_table_status(_Header, _Matches, false) ->
    <<"checksum-invalid">>;
acpi_table_status(_Header, _Matches, _Checksum) ->
    <<"observed">>.

acpi_override_provenance(Root, DynamicTables) ->
    #{
        <<"dynamic-tables-present">> => maps:size(DynamicTables) > 0,
        <<"initrd-override-directory-present">> =>
            dir_exists(Root, "/kernel/firmware/acpi"),
        <<"initrd-override-files">> =>
            [to_bin(F) ||
                F <- sorted_list_dir(Root, "/kernel/firmware/acpi")],
        <<"kernel-config">> =>
            kernel_config_options(
                Root,
                ["CONFIG_ACPI_TABLE_UPGRADE",
                 "CONFIG_ACPI_TABLE_OVERRIDE_VIA_BUILTIN_INITRD",
                 "CONFIG_ACPI_CUSTOM_DSDT",
                 "CONFIG_ACPI_CUSTOM_DSDT_FILE"]),
        <<"notes">> =>
            <<"Linux can accept ACPI table upgrades from initrd when built "
              "for that path. LapEE policy should combine these fields with "
              "the measured UKI/initrd/cmdline and firmware PCR evidence.">>
    }.

efi_report(Root) ->
    #{
        <<"available">> => dir_exists(Root, "/sys/firmware/efi"),
        <<"efivars-mounted">> =>
            dir_exists(Root, "/sys/firmware/efi/efivars"),
        <<"global-variables">> => #{
            <<"secure-boot">> => efi_byte_var(Root, "SecureBoot"),
            <<"setup-mode">> => efi_byte_var(Root, "SetupMode"),
            <<"audit-mode">> => efi_byte_var(Root, "AuditMode"),
            <<"deployed-mode">> => efi_byte_var(Root, "DeployedMode"),
            <<"vendor-keys">> => efi_byte_var(Root, "VendorKeys")
        }
    }.

efi_byte_var(Root, Name) ->
    Path =
        "/sys/firmware/efi/efivars/" ++ Name ++ "-" ++
            ?EFI_GLOBAL_VARIABLE_GUID,
    case read_file(Root, Path) of
        {ok, <<_Attrs:4/binary, Byte:8, _/binary>>} ->
            #{
                <<"readable">> => true,
                <<"raw">> => Byte,
                <<"state">> => efi_byte_state(Name, Byte)
            };
        {ok, _} ->
            #{<<"readable">> => true,
              <<"raw">> => null,
              <<"state">> => <<"malformed">>};
        error ->
            #{<<"readable">> => false,
              <<"raw">> => null,
              <<"state">> => <<"not-readable">>}
    end.

efi_byte_state("SecureBoot", 1) -> <<"enabled">>;
efi_byte_state("SecureBoot", 0) -> <<"disabled">>;
efi_byte_state("SetupMode", 1) -> <<"setup">>;
efi_byte_state("SetupMode", 0) -> <<"user">>;
efi_byte_state("AuditMode", 1) -> <<"audit">>;
efi_byte_state("AuditMode", 0) -> <<"normal">>;
efi_byte_state("DeployedMode", 1) -> <<"deployed">>;
efi_byte_state("DeployedMode", 0) -> <<"not-deployed">>;
efi_byte_state("VendorKeys", 1) -> <<"factory">>;
efi_byte_state("VendorKeys", 0) -> <<"modified">>;
efi_byte_state(_, _) -> <<"unknown">>.

boot_guard_report(Root) ->
    Path = "/dev/cpu/0/msr",
    case read_uint_le_at(Root, Path, ?MSR_BOOT_GUARD_SACM_INFO, 8) of
        {ok, Raw} ->
            #{
                <<"available">> => true,
                <<"source">> => <<"dev-cpu-msr">>,
                <<"interface">> => to_bin(Path),
                <<"msr-offset">> => u64_hex(?MSR_BOOT_GUARD_SACM_INFO),
                <<"raw-hex">> => u64_hex(Raw),
                <<"decoded">> => boot_guard_decode(Raw),
                <<"notes">> => boot_guard_notes()
            };
        {error, Reason} ->
            boot_guard_unavailable(Reason)
    end.

boot_guard_unavailable(Reason) ->
    #{
        <<"available">> => false,
        <<"source">> => <<"dev-cpu-msr">>,
        <<"interface">> => <<"/dev/cpu/0/msr">>,
        <<"msr-offset">> => u64_hex(?MSR_BOOT_GUARD_SACM_INFO),
        <<"error">> => to_bin(Reason),
        <<"notes">> => boot_guard_notes()
    }.

boot_guard_notes() ->
    <<"This probe reads MSR_BOOT_GUARD_SACM_INFO through /dev/cpu/0/msr "
      "when the kernel exposes it. It is a neutral runtime observation of "
      "the S-ACM-exported status register; "
      "TPM/TCG event-log Boot Guard measurements remain separate firmware "
      "evidence.">>.

boot_guard_decode(Raw) ->
    #{
        <<"nem-enabled">> => bit_set(Raw, 0),
        <<"tpm-type-code">> => bit_range(Raw, 1, 2),
        <<"tpm-type">> => boot_guard_tpm_type(bit_range(Raw, 1, 2)),
        <<"tpm-success">> => bit_set(Raw, 3),
        <<"force-anchor-boot">> => bit_set(Raw, 4),
        <<"measured">> => bit_set(Raw, 5),
        <<"verified">> => bit_set(Raw, 6),
        <<"module-revoked">> => bit_set(Raw, 7),
        <<"boot-guard-capability">> => bit_set(Raw, 32),
        <<"server-txt-capability">> => bit_set(Raw, 34),
        <<"no-reset-secrets-protection">> => bit_set(Raw, 35)
    }.

boot_guard_tpm_type(0) -> <<"none">>;
boot_guard_tpm_type(1) -> <<"discrete">>;
boot_guard_tpm_type(2) -> <<"firmware">>;
boot_guard_tpm_type(3) -> <<"reserved">>;
boot_guard_tpm_type(_) -> <<"unknown">>.

bit_set(Raw, Bit) ->
    (Raw band (1 bsl Bit)) =/= 0.

tpm_devices(Root) ->
    Base = "/sys/class/tpm",
    [#{
        <<"name">> => to_bin(T),
        <<"version-major">> =>
            read_trim(Root, filename:join([Base, T, "tpm_version_major"])),
        <<"device-path">> =>
            read_link_basename(Root, filename:join([Base, T, "device"])),
        <<"description">> =>
            read_trim(Root, filename:join([Base, T, "device", "description"]))
    } || T <- sorted_list_dir(Root, Base),
         is_tpm_name(T)].

pci_report(Root) ->
    Base = "/sys/bus/pci/devices",
    Devices =
        [pci_device_report(Root, Base, D)
         || D <- sorted_list_dir(Root, Base),
            dir_exists(Root, filename:join(Base, D))],
    #{
        <<"available">> => Devices =/= [],
        <<"device-count">> => length(Devices),
        <<"devices">> => Devices
    }.

pci_device_report(Root, Base, Dev) ->
    Path = filename:join(Base, Dev),
    #{
        <<"bdf">> => to_bin(Dev),
        <<"class">> => read_trim(Root, filename:join(Path, "class")),
        <<"vendor">> => read_trim(Root, filename:join(Path, "vendor")),
        <<"device">> => read_trim(Root, filename:join(Path, "device")),
        <<"subsystem-vendor">> =>
            read_trim(Root, filename:join(Path, "subsystem_vendor")),
        <<"subsystem-device">> =>
            read_trim(Root, filename:join(Path, "subsystem_device")),
        <<"revision">> => read_trim(Root, filename:join(Path, "revision")),
        <<"driver">> => read_link_basename(Root, filename:join(Path, "driver")),
        <<"modalias">> => read_trim(Root, filename:join(Path, "modalias"))
    }.

drm_report(Root) ->
    Base = "/sys/class/drm",
    Cards =
        [C || C <- sorted_list_dir(Root, Base),
              is_drm_card_name(C),
              dir_exists(Root, filename:join(Base, C))],
    Reports = [drm_card_report(Root, Base, C) || C <- Cards],
    #{
        <<"available">> => Reports =/= [],
        <<"source">> => <<"sysfs-drm">>,
        <<"card-count">> => length(Reports),
        <<"cards">> => Reports
    }.

drm_card_report(Root, Base, Card) ->
    Path = filename:join(Base, Card),
    DevicePath = filename:join(Path, "device"),
    #{
        <<"name">> => to_bin(Card),
        <<"dev">> => read_trim(Root, filename:join(Path, "dev")),
        <<"device">> => read_link_basename(Root, filename:join(Path, "device")),
        <<"driver">> =>
            read_link_basename(Root, filename:join([Path, "device", "driver"])),
        <<"pci">> => read_attr_map(
            Root,
            DevicePath,
            ["class", "vendor", "device", "subsystem_vendor",
             "subsystem_device", "revision", "boot_vga", "modalias"]),
        <<"driver-sysfs">> => drm_driver_sysfs_report(Root, DevicePath),
        <<"connectors">> => drm_connectors_report(Root, Base, Card),
        <<"tiles">> => drm_tiles_report(Root, DevicePath)
    }.

drm_driver_sysfs_report(Root, DevicePath) ->
    #{
        <<"device-attributes">> => read_attr_map(
            Root,
            DevicePath,
            ["vram_d3cold_threshold", "lb_fan_control_version",
             "lb_voltage_regulator_version",
             "auto_link_downgrade_capable", "auto_link_downgrade_status"]),
        <<"notes">> =>
            <<"This is a conservative read-only snapshot of stable DRM sysfs "
              "files. Intel xe/i915 currently keep their decoded system DRAM "
              "type in driver memory for display bandwidth logic; this report "
              "records the exposed fields without assigning policy meaning.">>
    }.

drm_connectors_report(Root, Base, Card) ->
    Prefix = Card ++ "-",
    [drm_connector_report(Root, Base, Connector)
     || Connector <- sorted_list_dir(Root, Base),
        string:prefix(Connector, Prefix) =/= nomatch,
        dir_exists(Root, filename:join(Base, Connector))].

drm_connector_report(Root, Base, Connector) ->
    Path = filename:join(Base, Connector),
    #{
        <<"name">> => to_bin(Connector),
        <<"status">> => read_trim(Root, filename:join(Path, "status")),
        <<"enabled">> => read_trim(Root, filename:join(Path, "enabled")),
        <<"dpms">> => read_trim(Root, filename:join(Path, "dpms")),
        <<"modes">> => read_lines(Root, filename:join(Path, "modes"))
    }.

drm_tiles_report(Root, DevicePath) ->
    [drm_tile_report(Root, DevicePath, Tile)
     || Tile <- sorted_list_dir(Root, DevicePath),
        string:prefix(Tile, "tile") =/= nomatch,
        dir_exists(Root, filename:join(DevicePath, Tile))].

drm_tile_report(Root, DevicePath, Tile) ->
    Path = filename:join(DevicePath, Tile),
    #{
        <<"name">> => to_bin(Tile),
        <<"memory">> => #{
            <<"freq0">> =>
                read_attr_map(
                    Root,
                    filename:join([Path, "memory", "freq0"]),
                    ["min_freq", "max_freq"])
        },
        <<"gts">> =>
            [drm_gt_report(Root, Path, Gt)
             || Gt <- sorted_list_dir(Root, Path),
                string:prefix(Gt, "gt") =/= nomatch,
                dir_exists(Root, filename:join(Path, Gt))]
    }.

drm_gt_report(Root, TilePath, Gt) ->
    Path = filename:join(TilePath, Gt),
    #{
        <<"name">> => to_bin(Gt),
        <<"engines">> =>
            [to_bin(E)
             || E <- sorted_list_dir(Root, filename:join(Path, "engines")),
                dir_exists(Root, filename:join([Path, "engines", E]))]
    }.

block_report(Root) ->
    Base = "/sys/block",
    Devices =
        [block_device_report(Root, Base, D)
         || D <- sorted_list_dir(Root, Base),
            dir_exists(Root, filename:join(Base, D))],
    #{
        <<"available">> => Devices =/= [],
        <<"device-count">> => length(Devices),
        <<"devices">> => Devices
    }.

block_device_report(Root, Base, Dev) ->
    Path = filename:join(Base, Dev),
    Sectors = parse_int(read_trim(Root, filename:join(Path, "size"))),
    #{
        <<"name">> => to_bin(Dev),
        <<"dev">> => read_trim(Root, filename:join(Path, "dev")),
        <<"size-sectors">> => Sectors,
        <<"size-bytes">> => sectors_to_bytes(Sectors),
        <<"removable">> => read_trim(Root, filename:join(Path, "removable")),
        <<"read-only">> => read_trim(Root, filename:join(Path, "ro")),
        <<"model">> => read_trim(Root, filename:join([Path, "device", "model"])),
        <<"vendor">> =>
            read_trim(Root, filename:join([Path, "device", "vendor"])),
        <<"rotational">> =>
            read_trim(Root, filename:join([Path, "queue", "rotational"])),
        <<"driver">> =>
            read_link_basename(Root, filename:join([Path, "device", "driver"])),
        <<"partitions">> => block_partitions(Root, Path, Dev)
    }.

block_partitions(Root, Path, Dev) ->
    [#{
        <<"name">> => to_bin(P),
        <<"dev">> => read_trim(Root, filename:join([Path, P, "dev"])),
        <<"start">> => read_trim(Root, filename:join([Path, P, "start"])),
        <<"size-sectors">> =>
            parse_int(read_trim(Root, filename:join([Path, P, "size"]))),
        <<"read-only">> => read_trim(Root, filename:join([Path, P, "ro"]))
    } || P <- sorted_list_dir(Root, Path),
         string:prefix(P, Dev) =/= nomatch,
         file_exists(Root, filename:join([Path, P, "partition"]))].

network_report(Root) ->
    Base = "/sys/class/net",
    Interfaces =
        [network_interface_report(Root, Base, Iface)
         || Iface <- sorted_list_dir(Root, Base),
            dir_exists(Root, filename:join(Base, Iface))],
    #{
        <<"available">> => Interfaces =/= [],
        <<"interface-count">> => length(Interfaces),
        <<"interfaces">> => Interfaces
    }.

network_interface_report(Root, Base, Iface) ->
    Path = filename:join(Base, Iface),
    Address = read_trim(Root, filename:join(Path, "address")),
    #{
        <<"name">> => to_bin(Iface),
        <<"type">> => read_trim(Root, filename:join(Path, "type")),
        <<"operstate">> => read_trim(Root, filename:join(Path, "operstate")),
        <<"carrier">> => read_trim(Root, filename:join(Path, "carrier")),
        <<"mtu">> => read_trim(Root, filename:join(Path, "mtu")),
        <<"wireless">> => dir_exists(Root, filename:join(Path, "wireless")),
        <<"device">> => read_link_basename(Root, filename:join(Path, "device")),
        <<"driver">> =>
            read_link_basename(Root, filename:join([Path, "device", "driver"])),
        <<"hardware-address">> => redact(Address)
    }.

vulnerabilities_report(Root) ->
    Base = "/sys/devices/system/cpu/vulnerabilities",
    maps:from_list(
        [{normalise_key(to_bin(Name)),
          read_trim(Root, filename:join(Base, Name))}
         || Name <- sorted_list_dir(Root, Base)]).

mountinfo_report(Root) ->
    case read_file(Root, "/proc/self/mountinfo") of
        {ok, Bin} ->
            [M || Line <- binary:split(Bin, <<"\n">>, [global]),
                  Line =/= <<>>,
                  M <- [mountinfo_line(Line)],
                  M =/= null];
        error ->
            []
    end.

mountinfo_line(Line) ->
    case binary:split(Line, <<" - ">>, []) of
        [Before, After] ->
            BFields = binary:split(Before, <<" ">>, [global]),
            AFields = binary:split(After, <<" ">>, [global]),
            case {BFields, AFields} of
                {[Id, Parent, MajorMinor, Root, MountPoint, Options | _],
                 [FsType, Source, SuperOptions | _]} ->
                    #{
                        <<"id">> => Id,
                        <<"parent">> => Parent,
                        <<"major-minor">> => MajorMinor,
                        <<"root">> => Root,
                        <<"mount-point">> => MountPoint,
                        <<"options">> => Options,
                        <<"filesystem-type">> => FsType,
                        <<"source">> => Source,
                        <<"super-options">> => SuperOptions
                    };
                _ ->
                    null
            end;
        _ ->
            null
    end.

%%%============================================================================
%%% Small filesystem/parsing helpers
%%%============================================================================

root() ->
    case os:getenv("LAPEE_SYSTEM_ROOT") of
        false -> "/";
        "" -> "/";
        R -> R
    end.

normalise_root(Root) when is_binary(Root) ->
    normalise_root(binary_to_list(Root));
normalise_root([]) ->
    "/";
normalise_root(Root) ->
    Root.

root_path("/", Abs) ->
    Abs;
root_path(Root, Abs) ->
    filename:join(Root, relative_path(Abs)).

relative_path([$/ | Rest]) -> Rest;
relative_path(Path) -> Path.

read_file(Root, Abs) ->
    case file:read_file(root_path(Root, Abs)) of
        {ok, Bin} -> {ok, Bin};
        _ -> error
    end.

read_trim(Root, Abs) ->
    case read_file(Root, Abs) of
        {ok, Bin} -> trim(Bin);
        error -> null
    end.

read_lines(Root, Abs) ->
    case read_file(Root, Abs) of
        {ok, Bin} ->
            [Line || Line <- binary:split(Bin, <<"\n">>, [global]),
                     trim(Line) =/= <<>>];
        error ->
            []
    end.

read_kernel_config(Root) ->
    OsRelease = read_trim(Root, "/proc/sys/kernel/osrelease"),
    Paths0 = ["/proc/config.gz", "/boot/config"],
    Paths =
        case OsRelease of
            null ->
                Paths0;
            _ ->
                ["/proc/config.gz",
                 binary_to_list(<<"/boot/config-", OsRelease/binary>>),
                 binary_to_list(
                    <<"/lib/modules/", OsRelease/binary, "/config">>),
                 "/boot/config"]
        end,
    read_kernel_config_paths(Root, Paths).

read_kernel_config_paths(_Root, []) ->
    unavailable;
read_kernel_config_paths(Root, [Path | Rest]) ->
    case read_file(Root, Path) of
        {ok, Bin} ->
            {ok, to_bin(Path), maybe_gunzip(Path, Bin)};
        error ->
            read_kernel_config_paths(Root, Rest)
    end.

maybe_gunzip(Path, Bin) ->
    case filename:extension(Path) of
        ".gz" ->
            try zlib:gunzip(Bin)
            catch _:_ -> Bin
            end;
        _ ->
            Bin
    end.

kernel_config_options(Root, Names) ->
    case read_kernel_config(Root) of
        {ok, Source, Bin} ->
            #{
                <<"available">> => true,
                <<"source">> => Source,
                <<"options">> =>
                    [kernel_config_option(Bin, Name) || Name <- Names]
            };
        unavailable ->
            #{
                <<"available">> => false,
                <<"source">> => null,
                <<"options">> =>
                    [#{
                        <<"name">> => to_bin(Name),
                        <<"state">> => <<"unknown">>,
                        <<"value">> => null
                    } || Name <- Names]
            }
    end.

kernel_config_option(Bin, Name0) ->
    Name = to_bin(Name0),
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Prefix = <<Name/binary, "=">>,
    Disabled = <<"# ", Name/binary, " is not set">>,
    Match =
        lists:filter(
            fun(Line) ->
                Line =:= Disabled orelse binary_has_prefix(Line, Prefix)
            end,
            Lines),
    {State, Value} =
        case Match of
            [Disabled | _] ->
                {<<"disabled">>, null};
            [Line | _] ->
                ConfigValue = binary:part(
                    Line, byte_size(Prefix),
                    byte_size(Line) - byte_size(Prefix)),
                {kernel_config_value_state(ConfigValue), ConfigValue};
            [] ->
                {<<"unknown">>, null}
        end,
    #{
        <<"name">> => Name,
        <<"state">> => State,
        <<"value">> => Value
    }.

kernel_config_value_state(<<"y">>) -> <<"enabled">>;
kernel_config_value_state(<<"m">>) -> <<"module">>;
kernel_config_value_state(_) -> <<"value">>.

binary_has_prefix(Bin, Prefix) when byte_size(Bin) >= byte_size(Prefix) ->
    binary:part(Bin, 0, byte_size(Prefix)) =:= Prefix;
binary_has_prefix(_, _) ->
    false.

read_uint_le_at(Root, Abs, Offset, Bytes) ->
    Bits = Bytes * 8,
    case read_exact_at(Root, Abs, Offset, Bytes) of
        {ok, <<Value:Bits/little-unsigned-integer>>} -> {ok, Value};
        Error -> Error
    end.

read_exact_at(Root, Abs, Offset, Bytes) ->
    case file:open(root_path(Root, Abs), [read, raw, binary]) of
        {ok, Io} ->
            try
                case file:pread(Io, Offset, Bytes) of
                    {ok, Bin} when byte_size(Bin) =:= Bytes ->
                        {ok, Bin};
                    {ok, _} ->
                        {error, 'short-read'};
                    eof ->
                        {error, eof};
                    {error, Reason} ->
                        {error, Reason}
                end
            after
                file:close(Io)
            end;
        {error, Reason} ->
            {error, Reason}
    end.

read_cpuid_leaf(Root, Abs, Leaf, Subleaf) ->
    Offset = (Subleaf bsl 32) bor Leaf,
    case read_exact_at(Root, Abs, Offset, 16) of
        {ok, <<Eax:32/little-unsigned-integer,
               Ebx:32/little-unsigned-integer,
               Ecx:32/little-unsigned-integer,
               Edx:32/little-unsigned-integer>>} ->
            {ok, #{eax => Eax, ebx => Ebx, ecx => Ecx, edx => Edx}};
        Error ->
            Error
    end.

sha256_hex_to_id(Hex0) ->
    Hex = trim(to_bin(Hex0)),
    case byte_size(Hex) =:= 64 andalso hex_binary(Hex) of
        Bin when is_binary(Bin), byte_size(Bin) =:= 32 ->
            {ok, hb_util:human_id(Bin)};
        _ ->
            error
    end.

hex_binary(Hex) ->
    try
        << <<(hex_pair_to_int(A, B))>> ||
            <<A:8, B:8>> <= lowercase(Hex) >>
    catch
        _:_ -> error
    end.

hex_pair_to_int(A, B) ->
    (hex_digit(A) bsl 4) bor hex_digit(B).

hex_digit(C) when C >= $0, C =< $9 -> C - $0;
hex_digit(C) when C >= $a, C =< $f -> C - $a + 10;
hex_digit(_) -> error(invalid_hex_digit).

lowercase(Bin) ->
    << <<(lower_char(C))>> || <<C:8>> <= Bin >>.

lower_char(C) when C >= $A, C =< $Z -> C + 32;
lower_char(C) -> C.

read_attr_map(Root, Abs, Names) ->
    maps:from_list(
        [{normalise_key(to_bin(Name)), Value}
         || Name <- Names,
            Value <- [read_trim(Root, filename:join(Abs, Name))],
            Value =/= null]).

trim(Bin) when is_binary(Bin) ->
    string:trim(Bin, both, "\r\n \t").

sorted_list_dir(Root, Abs) ->
    case file:list_dir(root_path(Root, Abs)) of
        {ok, Entries} -> lists:sort(Entries);
        _ -> []
    end.

file_exists(Root, Abs) ->
    case file:read_file_info(root_path(Root, Abs)) of
        {ok, _} -> true;
        _ -> false
    end.

dir_exists(Root, Abs) ->
    case file:read_file_info(root_path(Root, Abs)) of
        {ok, #file_info{type = directory}} -> true;
        _ -> false
    end.

read_link_basename(Root, Abs) ->
    case file:read_link(root_path(Root, Abs)) of
        {ok, Target} -> to_bin(filename:basename(Target));
        _ -> null
    end.

digit_dirs(Root, Abs) ->
    [E || E <- sorted_list_dir(Root, Abs),
          is_digit_string(E),
          dir_exists(Root, filename:join(Abs, E))].

is_digit_string([]) -> false;
is_digit_string(S) ->
    lists:all(fun(C) -> C >= $0 andalso C =< $9 end, S).

is_tpm_name("tpm" ++ Rest) ->
    is_digit_string(Rest);
is_tpm_name(_) ->
    false.

is_drm_card_name("card" ++ Rest) ->
    is_digit_string(Rest);
is_drm_card_name(_) ->
    false.

line_to_kv(Line, Acc) ->
    case binary:split(Line, <<":">>, []) of
        [Key, Val] ->
            K = normalise_key(Key),
            case maps:is_key(K, Acc) of
                true -> Acc;
                false -> Acc#{K => trim(Val)}
            end;
        _ ->
            Acc
    end.

normalise_key(Bin0) ->
    Bin1 = string:lowercase(trim(Bin0)),
    Bin2 = binary:replace(Bin1, <<" ">>, <<"-">>, [global]),
    binary:replace(Bin2, <<"_">>, <<"-">>, [global]).

split_words(null) ->
    [];
split_words(Bin) when is_binary(Bin) ->
    Spacey = binary:replace(trim(Bin), <<"\t">>, <<" ">>, [global]),
    [W || W <- binary:split(Spacey, <<" ">>, [global]), W =/= <<>>].

parse_int(null) ->
    null;
parse_int(Bin) when is_binary(Bin) ->
    try binary_to_integer(Bin)
    catch _:_ -> null
    end.

parse_bool_01(<<"1">>, _Default) -> true;
parse_bool_01(<<"0">>, _Default) -> false;
parse_bool_01(_, Default) -> Default.

sectors_to_bytes(N) when is_integer(N) ->
    N * 512;
sectors_to_bytes(_) ->
    null.

u32_hex(N) when is_integer(N), N >= 0 ->
    hex(N, 8).

u64_hex(N) when is_integer(N), N >= 0 ->
    hex(N, 16).

hex(N, Width) ->
    Hex = string:uppercase(integer_to_binary(N, 16)),
    Padding = lists:duplicate(erlang:max(0, Width - byte_size(Hex)), $0),
    to_bin(["0x", Padding, Hex]).

bit_range(Raw, First, Last) ->
    (Raw bsr First) band ((1 bsl (Last - First + 1)) - 1).

redact(null) -> null;
redact(<<>>) -> null;
redact(_) -> <<"redacted">>.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(T) -> iolist_to_binary(io_lib:format("~p", [T])).

non_empty(Items) ->
    [I || I <- Items, trim(I) =/= <<>>].

%%%============================================================================
%%% Tests
%%%============================================================================

-ifdef(TEST).

report_empty_root_test() ->
    Root = make_tmp_root("empty"),
    try
        Report = report_from_root(Root),
        ?assertEqual(<<"system@1.0">>, maps:get(<<"device">>, Report)),
        ?assertEqual(false,
                     maps:get(<<"available">>,
                              maps:get(<<"dmi">>,
                                       maps:get(<<"firmware">>, Report)))),
        ?assertEqual(false,
                     maps:get(<<"available">>,
                              maps:get(<<"cpuinfo">>,
                                       maps:get(<<"cpu">>, Report))))
    after
        rm_rf(Root)
    end.

intel_drm_unknown_kernel_dram_is_indeterminate_test() ->
    Root = make_tmp_root("intel-drm-unknown"),
    try
        make_dir_p(Root, "/sys/class/drm/card0/device"),
        write_fixture(Root, "/sys/class/drm/card0/device/vendor",
            <<"0x8086\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_type",
            <<"UNKNOWN\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_lpddr_class",
            <<"0\n">>),
        IntelDram = intel_drm_memory_probe(Root),
        ?assertEqual(null,
                     maps:get(<<"lpddr-class-observed">>, IntelDram)),
        [Card] = maps:get(<<"cards">>, IntelDram),
        ?assertEqual(<<"unknown">>, maps:get(<<"status">>, Card)),
        Decoded = maps:get(<<"decoded">>, Card),
        ?assertEqual(<<"unknown">>, maps:get(<<"dram-type">>, Decoded)),
        ?assertEqual(null, maps:get(<<"lpddr-class">>, Decoded))
    after
        rm_rf(Root)
    end.

intel_drm_ddr_kernel_dram_is_non_lpddr_test() ->
    Root = make_tmp_root("intel-drm-ddr"),
    try
        make_dir_p(Root, "/sys/class/drm/card0/device"),
        write_fixture(Root, "/sys/class/drm/card0/device/vendor",
            <<"0x8086\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_type",
            <<"DDR5\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_lpddr_class",
            <<"0\n">>),
        IntelDram = intel_drm_memory_probe(Root),
        ?assertEqual(false,
                     maps:get(<<"lpddr-class-observed">>, IntelDram)),
        [Card] = maps:get(<<"cards">>, IntelDram),
        ?assertEqual(<<"observed">>, maps:get(<<"status">>, Card)),
        Decoded = maps:get(<<"decoded">>, Card),
        ?assertEqual(<<"DDR5">>, maps:get(<<"dram-type">>, Decoded)),
        ?assertEqual(false, maps:get(<<"lpddr-class">>, Decoded))
    after
        rm_rf(Root)
    end.

intel_drm_resource0_fallback_test() ->
    Root = make_tmp_root("intel-drm-resource0"),
    try
        make_dir_p(Root, "/sys/class/drm/card0/device"),
        write_fixture(Root, "/sys/class/drm/card0/device/vendor",
            <<"0x8086\n">>),
        write_uint_fixture(
            Root,
            "/sys/class/drm/card0/device/resource0",
            ?MTL_MEM_SS_INFO_GLOBAL,
            2 bor (8 bsl 4) bor (3 bsl 8),
            32),
        IntelDram = intel_drm_memory_probe(Root),
        ?assertEqual(true,
                     maps:get(<<"lpddr-class-observed">>, IntelDram)),
        [Card] = maps:get(<<"cards">>, IntelDram),
        ?assertEqual(<<"intel-mtl-mem-ss-info-global">>,
                     maps:get(<<"method">>, Card)),
        ?assertEqual(<<"observed">>, maps:get(<<"status">>, Card))
    after
        rm_rf(Root)
    end.

report_fixture_root_test() ->
    Root = make_tmp_root("fixture"),
    try
        write_fixture(Root, "/proc/cpuinfo",
            <<"processor\t: 0\nvendor_id\t: GenuineIntel\n"
              "model name\t: Test CPU\nflags\t\t: fpu tme aes\n"
              "bugs\t\t: spectre_v1\n\n">>),
        write_fixture(Root, "/proc/meminfo",
            <<"MemTotal:       16384 kB\nSwapTotal:          0 kB\n">>),
        write_fixture(Root, "/proc/cmdline",
            <<"quiet rdinit=/init">>),
        write_fixture(Root, "/proc/modules",
            <<"iwlwifi 1 0 - Live 0x0\nxe 2 0 - Live 0x0\n">>),
        BootHash = crypto:hash(sha256, <<"fixture-uki">>),
        BootHashHex = iolist_to_binary([
            io_lib:format("~2.16.0b", [B]) || <<B:8>> <= BootHash
        ]),
        write_fixture(Root, "/run/lapee/boot-uki-sha256", BootHashHex),
        write_fixture(Root, "/proc/self/mountinfo",
            <<"12 1 8:1 / / rw - ext4 /dev/sda1 rw\n">>),
        write_fixture(Root, "/sys/class/dmi/id/sys_vendor",
            <<"ACME\n">>),
        write_fixture(Root, "/sys/class/dmi/id/product_name",
            <<"LapEE Test Rig\n">>),
        write_fixture(Root, "/proc/config.gz",
            zlib:gzip(
                <<"CONFIG_ACPI_TABLE_UPGRADE=y\n"
                  "# CONFIG_ACPI_TABLE_OVERRIDE_VIA_BUILTIN_INITRD "
                  "is not set\n">>)),
        write_fixture(
            Root,
            "/sys/firmware/acpi/tables/DSDT",
            acpi_table_fixture(<<"DSDT">>, <<"ACME">>, <<"LAPEE">>)),
        write_fixture(
            Root,
            "/sys/firmware/acpi/tables/dynamic/SSDT1",
            acpi_table_fixture(<<"SSDT">>, <<"ACME">>, <<"DYNTEST">>)),
        write_fixture(Root,
            "/sys/kernel/security/integrity/ima/"
            "runtime_measurements_count",
            <<"42\n">>),
        write_fixture(Root, "/sys/kernel/security/lockdown",
            <<"[none] integrity confidentiality\n">>),
        make_dir_p(Root, "/sys/kernel/iommu_groups/7/devices"),
        make_dir_p(Root, "/sys/devices/system/edac/mc/mc0/dimm0"),
        write_fixture(Root,
            "/sys/devices/system/edac/mc/mc0/dimm0/dimm_mem_type",
            <<"LPDDR5\n">>),
        make_dir_p(Root, "/sys/class/drm/card0/device/tile0/gt0/engines/rcs0"),
        write_fixture(Root, "/sys/class/drm/card0/dev", <<"226:0\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/vendor",
            <<"0x8086\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/device",
            <<"0x7d45\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_type",
            <<"LPDDR5\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_lpddr_class",
            <<"1\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_num_channels",
            <<"8\n">>),
        write_fixture(Root, "/sys/class/drm/card0/device/dram_num_qgv_points",
            <<"3\n">>),
        write_fixture(Root,
            "/sys/class/drm/card0/device/dram_num_psf_gv_points",
            <<"2\n">>),
        write_uint_fixture(
            Root,
            "/sys/class/drm/card0/device/resource0",
            ?MTL_MEM_SS_INFO_GLOBAL,
            2 bor (8 bsl 4) bor (3 bsl 8),
            32),
        write_uint_fixture(
            Root,
            "/dev/cpu/0/msr",
            ?MSR_BOOT_GUARD_SACM_INFO,
            (1 bsl 32) bor (1 bsl 6) bor (1 bsl 5) bor
                (1 bsl 3) bor (2 bsl 1),
            64),
        make_dir_p(Root, "/sys/class/drm/card0-eDP-1"),
        write_fixture(Root, "/sys/class/drm/card0-eDP-1/status",
            <<"connected\n">>),
        write_fixture(Root, "/sys/class/drm/card0-eDP-1/modes",
            <<"2880x1800\n1920x1200\n">>),
        make_dir_p(Root, "/sys/class/net/wlan0/wireless"),
        write_fixture(Root, "/sys/class/net/wlan0/address",
            <<"aa:bb:cc:dd:ee:ff\n">>),
        write_fixture(Root, "/sys/class/net/wlan0/operstate", <<"up\n">>),
        Report = report_from_root(Root),
        Boot = maps:get(<<"boot">>, Report),
        LoadedUKI = maps:get(<<"loaded-uki">>, Boot),
        ?assertEqual(true, maps:get(<<"available">>, LoadedUKI)),
        ?assertEqual(<<"observed">>, maps:get(<<"status">>, LoadedUKI)),
        ?assertEqual(hb_util:human_id(BootHash),
                     maps:get(<<"sha256">>, LoadedUKI)),
        CpuInfo = maps:get(<<"cpuinfo">>, maps:get(<<"cpu">>, Report)),
        ?assertEqual(true, maps:get(<<"available">>, CpuInfo)),
        ?assert(lists:member(<<"tme">>, maps:get(<<"flags">>, CpuInfo))),
        Firmware = maps:get(<<"firmware">>, Report),
        Dmi = maps:get(<<"dmi">>, Firmware),
        ?assertEqual(<<"ACME">>,
                     maps:get(<<"sys-vendor">>,
                              maps:get(<<"fields">>, Dmi))),
        Acpi = maps:get(<<"acpi">>, Firmware),
        ?assertEqual(true, maps:get(<<"available">>, Acpi)),
        ?assertEqual(<<"asf-x21">>, acpi_path_key("ASF!")),
        TableCounts = maps:get(<<"table-counts">>, Acpi),
        ?assertEqual(1, maps:get(<<"final">>, TableCounts)),
        Tables =
            maps:get(
                <<"tables">>,
                maps:get(
                    <<"acpi">>,
                    maps:get(
                        <<"firmware">>,
                        maps:get(<<"sys">>, maps:get(<<"tables">>, Acpi))))),
        ?assert(maps:is_key(acpi_path_key("DSDT"), Tables)),
        ?assertNot(maps:is_key(<<"DSDT">>, Tables)),
        Dsdt = maps:get(acpi_path_key("DSDT"), Tables),
        ?assertEqual(<<"DSDT">>, maps:get(<<"sysfs-name">>, Dsdt)),
        ?assertEqual(<<"DSDT">>,
                     maps:get(<<"table-signature">>,
                              maps:get(<<"header">>, Dsdt))),
        ?assertEqual(<<"ACME">>,
                     maps:get(<<"oem-id">>,
                              maps:get(<<"header">>, Dsdt))),
        ?assertEqual(true,
                     maps:get(<<"declared-length-matches-file">>, Dsdt)),
        ?assertEqual(true, maps:get(<<"checksum-valid">>, Dsdt)),
        ?assert(maps:is_key(<<"table-sha256">>, Dsdt)),
        ?assertEqual(1, maps:get(<<"dynamic">>, TableCounts)),
        DynamicTables = maps:get(<<"dynamic">>, Tables),
        ?assert(maps:is_key(acpi_path_key("SSDT1"), DynamicTables)),
        Ssdt = maps:get(acpi_path_key("SSDT1"), DynamicTables),
        ?assertEqual(<<"SSDT1">>, maps:get(<<"sysfs-name">>, Ssdt)),
        ?assertEqual(<<"SSDT">>,
                     maps:get(<<"table-signature">>,
                              maps:get(<<"header">>, Ssdt))),
        AcpiProvenance = maps:get(<<"override-provenance">>, Acpi),
        ?assertEqual(true,
                     maps:get(<<"dynamic-tables-present">>,
                              AcpiProvenance)),
        AcpiConfig = maps:get(<<"kernel-config">>, AcpiProvenance),
        ?assertEqual(true, maps:get(<<"available">>, AcpiConfig)),
        [TableUpgrade | _] = maps:get(<<"options">>, AcpiConfig),
        ?assertEqual(<<"CONFIG_ACPI_TABLE_UPGRADE">>,
                     maps:get(<<"name">>, TableUpgrade)),
        ?assertEqual(<<"enabled">>, maps:get(<<"state">>, TableUpgrade)),
        BootGuard = maps:get(<<"boot-guard">>, Firmware),
        ?assertEqual(true, maps:get(<<"available">>, BootGuard)),
        ?assertEqual(<<"dev-cpu-msr">>, maps:get(<<"source">>, BootGuard)),
        ?assertEqual(<<"0x000000000000013A">>,
                     maps:get(<<"msr-offset">>, BootGuard)),
        BootGuardDecoded = maps:get(<<"decoded">>, BootGuard),
        ?assertEqual(true, maps:get(<<"measured">>, BootGuardDecoded)),
        ?assertEqual(true, maps:get(<<"verified">>, BootGuardDecoded)),
        ?assertEqual(<<"firmware">>,
                     maps:get(<<"tpm-type">>, BootGuardDecoded)),
        ?assertEqual(false, maps:is_key(<<"policy-usable">>, BootGuard)),
        Integrity = maps:get(<<"integrity">>, Report),
        ?assertEqual(<<"42">>,
                     maps:get(<<"runtime-measurements-count">>,
                              maps:get(<<"ima">>, Integrity))),
        Memory = maps:get(<<"memory">>, Report),
        [Mc0] = maps:get(<<"controllers">>, maps:get(<<"edac">>, Memory)),
        [Dimm0] = maps:get(<<"dimms">>, Mc0),
        ?assertEqual(<<"LPDDR5">>, maps:get(<<"memory-type">>, Dimm0)),
        HardwareProbes = maps:get(<<"hardware-probes">>, Report),
        MemProbe = maps:get(<<"memory-controller">>, HardwareProbes),
        IntelDram = maps:get(<<"intel-drm-controller">>, MemProbe),
        ?assertEqual(false, maps:is_key(<<"policy-usable">>, MemProbe)),
        ?assertEqual(false, maps:is_key(<<"policy-usable">>, IntelDram)),
        ?assertEqual(true,
                     maps:get(<<"lpddr-class-observed">>, IntelDram)),
        [IntelCard] = maps:get(<<"cards">>, IntelDram),
        ?assertEqual(<<"observed">>, maps:get(<<"status">>, IntelCard)),
        ?assertEqual(<<"intel-drm-kernel-dram-info">>,
                     maps:get(<<"method">>, IntelCard)),
        ?assertEqual(<<"drm-device-sysfs">>,
                     maps:get(<<"source">>, IntelCard)),
        ?assertEqual(false, maps:is_key(<<"policy-usable">>, IntelCard)),
        IntelDecoded = maps:get(<<"decoded">>, IntelCard),
        ?assertEqual(<<"LPDDR5">>,
                     maps:get(<<"dram-type">>, IntelDecoded)),
        ?assertEqual(8,
                     maps:get(<<"populated-channels">>, IntelDecoded)),
        ?assertEqual(3,
                     maps:get(<<"enabled-qgv-points">>, IntelDecoded)),
        ?assertEqual(2,
                     maps:get(<<"enabled-psf-gv-points">>, IntelDecoded)),
        Devices = maps:get(<<"devices">>, Report),
        [Card0] = maps:get(<<"cards">>, maps:get(<<"drm">>, Devices)),
        ?assertEqual(<<"226:0">>, maps:get(<<"dev">>, Card0)),
        ?assertEqual(<<"0x8086">>,
                     maps:get(<<"vendor">>, maps:get(<<"pci">>, Card0))),
        [Connector0] = maps:get(<<"connectors">>, Card0),
        ?assertEqual(<<"connected">>, maps:get(<<"status">>, Connector0)),
        ?assert(lists:member(<<"2880x1800">>,
                             maps:get(<<"modes">>, Connector0))),
        [Tile0] = maps:get(<<"tiles">>, Card0),
        [Gt0] = maps:get(<<"gts">>, Tile0),
        ?assertEqual([<<"rcs0">>], maps:get(<<"engines">>, Gt0)),
        [Wlan0] =
            maps:get(<<"interfaces">>,
                     maps:get(<<"network">>, Devices)),
        ?assertEqual(true, maps:get(<<"wireless">>, Wlan0)),
        ?assertEqual(<<"redacted">>,
                     maps:get(<<"hardware-address">>, Wlan0))
    after
        rm_rf(Root)
    end.

make_tmp_root(Name) ->
    Base = filename:join(
        [os:getenv("TMPDIR", "/tmp"), "lapee-system-tests"]),
    Root = filename:join(
        Base,
        Name ++ "-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Root, ".keep")),
    Root.

write_fixture(Root, Abs, Data) ->
    Path = root_path(Root, Abs),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, Data).

write_uint_fixture(Root, Abs, Offset, Value, Bits) ->
    Path = root_path(Root, Abs),
    ok = filelib:ensure_dir(Path),
    {ok, Io} = file:open(Path, [write, raw, binary]),
    try
        ok = file:pwrite(Io, Offset, <<Value:Bits/little-unsigned-integer>>)
    after
        file:close(Io)
    end.

acpi_table_fixture(Sig, OemId, OemTableId) ->
    Payload = <<"LapEE ACPI fixture">>,
    Length = 36 + byte_size(Payload),
    Header0 = <<Sig:4/binary, Length:32/little, 2:8, 0:8,
                (pad_acpi_field(OemId, 6)):6/binary,
                (pad_acpi_field(OemTableId, 8)):8/binary,
                1:32/little,
                (pad_acpi_field(<<"LAPE">>, 4)):4/binary,
                1:32/little>>,
    Checksum =
        (256 - (lists:sum(binary_to_list(<<Header0/binary, Payload/binary>>))
            band 16#ff)) band 16#ff,
    <<Sig:4/binary, Length:32/little, 2:8, Checksum:8,
      (pad_acpi_field(OemId, 6)):6/binary,
      (pad_acpi_field(OemTableId, 8)):8/binary,
      1:32/little,
      (pad_acpi_field(<<"LAPE">>, 4)):4/binary,
      1:32/little,
      Payload/binary>>.

pad_acpi_field(Bin, Size) ->
    binary:part(<<Bin/binary, (binary:copy(<<0>>, Size))/binary>>, 0, Size).

make_dir_p(Root, Abs) ->
    Path = root_path(Root, Abs),
    ok = filelib:ensure_dir(filename:join(Path, ".keep")),
    ok = ensure_dir(Path).

ensure_dir(Path) ->
    case file:make_dir(Path) of
        ok -> ok;
        {error, eexist} -> ok
    end.

rm_rf(Path) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = directory}} ->
            lists:foreach(
                fun(Entry) -> rm_rf(filename:join(Path, Entry)) end,
                filelib:wildcard("*", Path)),
            file:del_dir(Path);
        {ok, _} ->
            file:delete(Path);
        _ ->
            ok
    end.

-endif.
