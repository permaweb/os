# Decision: Read-Oriented Probe Surface

## Prompt

Work through the probe-surface correction TODO unattended and leave a validated
LapEE build ready for hardware testing.

## Issue

The previous pass over-tightened the kernel config by explicitly disabling
`X86_MSR` and `X86_CPUID`. That improves a narrow "less visible surface" metric
but conflicts with the architecture Sam steered toward: neutral, on-demand
hardware evidence gathered through the simplest maintainable kernel/userspace
interfaces.

## Options

1. Keep `X86_MSR` and `X86_CPUID` disabled.

   This minimizes observability but makes Boot Guard and raw CPUID evidence
   unavailable without custom kernel work. It pushes us toward bespoke helpers
   earlier than necessary.

2. Enable `X86_CPUID` and `X86_MSR`, then keep `~system@1.0` read-only by use.

   This creates `/dev/cpu/*/cpuid` and `/dev/cpu/*/msr`. CPUID is read-only.
   MSR is a broader interface, but LapEE can open it read-only and report only
   narrow, named reads. This avoids custom kernel patches while preserving
   provenance.

3. Add a custom kernel helper for Boot Guard immediately.

   This gives the narrowest production ABI but increases long-term maintenance
   surface before proving that the generic VFS path is insufficient.

## Decision

Choose option 2 for this pass.

Keep local input/output hardening separate. Keyboard, mouse, HID, debug console,
and boot-media writeback controls remain locked down. Read-oriented CPU evidence
interfaces are restored because they are the simplest maintainable way to expose
machine facts without editing the kernel.

If `/dev/cpu/0/msr` is absent or a read fails, `~system@1.0` will report that
failure neutrally and continue. A custom kernel helper remains a later option if
the MSR interface proves too broad for production policy.

