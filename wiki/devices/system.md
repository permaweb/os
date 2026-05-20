# `~system@1.0` Device Specification

`~system@1.0` returns policy-neutral evidence about the current machine and
runtime. It does not verify, score, or decide trust.

## Exports

- `info`: version and description.
- `all`: full system report.
- `report`: alias of `all`.

## Required Report Keys

- `device`: `<<"system@1.0">>`.
- `version`: `<<"1.0">>`.
- `collected-at-unix`: timestamp.
- `runtime`: kernel command line, LapEE mode, UKI/build metadata when present.
- `cpu`: CPUID-derived and sysfs CPU facts.
- `memory`: memory block, EDAC, Intel DRM DRAM, and memory-encryption facts.
- `firmware`: UEFI/Secure Boot/Boot Guard-observed facts where available.
- `acpi`: ACPI table summaries, table provenance, and override-support state.
- `tpm`: TPM device presence and public capability facts.
- `devices`: PCI/network/block/IOMMU summaries.
- `network`: observed interface/address facts.

All binary fields use base64url. Human-readable magic strings such as ACPI
table signatures are lowercase keys or values, never HTTP-signature fields.

## Constraints

The implementation may read Linux VFS surfaces and small read-only files. It
must not open debug-only write surfaces, mutate kernel state, or run arbitrary
shell pipelines.
