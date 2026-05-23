# PermawebOS Device Sharing Decision

## Prompt

Normalize HandEE into the PermawebOS distribution branch, avoid drift between
Android and Linux protocol devices, build test infrastructure for mixed
architecture zones, and keep the launch risk low.

## Issue

The imported HandEE package carried its own `~measurement@1.0` and
`~zone@1.0` implementations. That is acceptable as an import checkpoint but
wrong as an operating-system architecture: Android, SNP, TPM, TME, and no-TME
nodes must share one zone and measurement protocol so admission, templates,
secret wrapping, and membership proofs do not diverge.

## Decision

Use `devices/common/` as the shared PermawebOS device package. Android keeps
only Android-specific devices and app/runtime code in `devices/android/`.
Android builds stage a merged device root from `devices/common/` plus
`devices/android/`, with Android files overlaying architecture-specific modules
such as `~system@1.0`.

`~measurement@1.0` remains one common protocol device. It selects measurement
engines by device name, with `auto` probing real available devices. Engines
such as `~tpm@2.0a`, `~snp@1.0`, and `~handee@1.0` implement the measurement
backend contract.

`~zone@1.0` remains one common protocol device. It will accept either a single
template or a list of admissible templates, and it admits a peer if exactly the
same peer boot measurement matches at least one admissible template.

## Trade-Offs

This keeps protocol semantics in one place, but Android packaging needs a small
staging step before compile/build. That is preferable to maintaining forked
zone/measurement modules whose security properties can silently diverge.

