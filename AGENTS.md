# LapEE Agent Guide

LapEE is a TPM-attested HyperBEAM appliance OS for commodity laptops. The
repository owns the Buildroot/image tooling, the appliance init flow, and
LapEE-specific HyperBEAM devices staged through `hyperbeam-overlay/`.

## Work Native To HyperBEAM

- Treat upstream HyperBEAM as the substrate. Do not patch `~/src/hyperbeam`
  or a generated checkout to make this repo work.
- Generated HyperBEAM checkouts belong under `build/` and are disposable.
  Persistent LapEE behavior belongs in `hyperbeam-overlay/` or the
  Buildroot/image scripts that stage it.
- Prefer AO-Core messages, hashpaths, codecs, `accept` / `accept-bundle`,
  `hb_maps`, `hb_message`, `hb_cache`, `hb_store`, and existing device
  conventions. Avoid inventing parallel JSON protocols inside devices.
  Script harnesses may use JSON at their edges when that is the clearest
  operator interface.
- Use hyphenated binary keys in AO-Core messages and keep wire identifiers
  base64url, not hex.

## Keep The Security Model In View

- Production LapEE should boot, attest, serve HyperBEAM, and otherwise be
  locally inert. Avoid adding keyboard, mouse, shell, writeback, debug, or
  USB/runtime surfaces to production paths. Diagnostic, provisioning, and
  QEMU-only surfaces are acceptable only behind explicit measured modes that
  cannot leak into production mode.
- The boot USB is an input medium. Read only the intended boot-time inputs,
  then detach it before HyperBEAM starts.
- The node message, boot attestation, AK/EK proof, PCR replay, and loaded
  identities are one model. Changes around one of them usually need a
  verifier or QEMU acceptance check.
- Do not add arbitrary signing endpoints for protected identities. Use
  HyperBEAM identity selection and HTTP-signature mechanics where possible.
- Operator config is public configuration. It may shape the node message, but
  it must not bypass enforced LapEE config, TPM devices, or attestation hooks.

## Cut To Root Causes

- Keep patches surgical unless the task explicitly asks for a refactor.
- Do not layer compatibility shims or caches over a confused model. Delete or
  simplify the bad path when that is the real fix.
- Generated artefacts, private keys, WiFi credentials, USB images, and local
  HyperBEAM worktrees stay out of git.
- If a fix really belongs in upstream HyperBEAM, make that a separate HB
  change with its own justification instead of hiding it in this repo.

## Build And Verify Like Release Work

- Build output belongs under `build/`. Keep new scripts and targets within
  that convention.
- Saturate the machine for source builds:

  ```sh
  JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" make ...
  ```

- The public Makefile surface should stay operator/release oriented. Put
  mechanics in scripts or private/internal targets, and add public targets only
  for durable build, flash, provision, config, cleanup, or verification
  workflows.
- Done means maintainable and externally verified, not merely "the first
  happy path worked." For image/security changes, prefer QEMU+swtpm tests and
  real hardware validation when hardware is available.
- When touching green-zone, TPM, boot-attestation, operator config, or init,
  expect to run the relevant QEMU acceptance harness before declaring success.

## Documentation Standard

- README changes should help a fresh operator build, flash, boot, verify, and
  understand limitations. Do not document transient implementation quirks as
  permanent protocol facts.
- Module docs should explain protocol invariants and threat boundaries, not
  narrate historical accidents.
