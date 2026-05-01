# LapEE Unattended Probe/Attestation Pass

## Mission

Finish the correction pass from `docs/probe-surface-correction-todo.md` and
leave a fully rebuilt, verifier-tested LapEE image ready for real hardware.

Acceptance means:

- Neutral `~system@1.0` remains in place.
- Useful read-oriented probe interfaces are not disabled just to reduce
  observability.
- Boot Guard reports a real MSR-backed observation when `/dev/cpu/0/msr` is
  present, otherwise a precise unavailable reason.
- The build picks up the corrected `dev_system.erl` source.
- Standard and no-TME images rebuild.
- QEMU boots the no-TME image and serves `~tpm@2.0a/boot-attestation` and
  `~system@1.0/all`.
- The interpreter/verifier dashboard runs against the QEMU capture.
- Local commits record stable checkpoints.

## Discipline

Unattended mode is active. Chat is only for blocking questions. Progress and
pivots go here. No pushes unless explicitly requested.

## Log

- Started from branch `agent/probe-boot-capture` at `0e78476`.
- Current dirty tree already contained the new boot-attestation shape,
  `~system@1.0`, EDAC additions, the TODO doc, and verifier/script updates.
- Live `.210` node answered, but reported old DRM offset `0x01053400`; current
  source is `0x45700`, so rebuild validation must confirm the packaged image is
  using the current overlay.
- Wrote decision note:
  `docs/decisions/read-oriented-probe-surface.md`.
- Implemented first correction pass:
  - `CONFIG_X86_MSR=y`
  - `CONFIG_X86_CPUID=y`
  - `~system@1.0` now reads Boot Guard MSR `0x13a` from `/dev/cpu/0/msr` when
    available and decodes the pcr0tool/coreboot-compatible fields.
  - `~system@1.0` now reports selected `/dev/cpu/0/cpuid` leaves when available.
  - The interpreter policy surface now exposes `tme-operator-override` so
    no-TME boots do not look like an accidental "TME unknown" only.
- Corrected probe hex rendering to emit actual uppercase hexadecimal strings
  (`0x00045700`, `0x000000000000013A`) instead of decimal strings with a
  `0x` prefix.
- `rebar3 as test compile` passed in the staged HyperBEAM checkout.
- `rebar3 as test eunit --module=dev_system` passed. A parallel attempt to run
  multiple EUnit modules collided on HyperBEAM's default test listener port;
  rerunning remaining modules serially with isolated ports.
- Serial EUnit with `HB_PORT=0` passed:
  - `dev_tpm_interpret`: 116 tests.
  - `dev_tpm2`: 22 tests.
