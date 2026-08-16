# HyperBEAM Device Packages

PermawebOS behavior is packaged as normal HyperBEAM Forge device packages.
These are distribution devices, not kernel patches.

- `common/` is the shared package: `measurement@1.0`, `system@1.0`,
  `tpm@2.0a`, `snp@1.0`, `andee@1.0` (AndEE), `zone@1.0`, native TPM/SNP
  helpers, and trusted measurement root material. Linux images use it
  directly. Other architectures stage it with their architecture-specific
  package before compiling. Architecture-specific measurement devices live here
  when their verification path is portable; unsupported local generation fails
  softly while peer verification remains available. Security modules live in
  `common/src/security/`; the backend-neutral Unix sandbox contract shared by
  Andock and Docker lives in `common/src/sandbox/`.
- `android/` is the Android package overlay: app-private encrypted store
  support, AndEE metadata, Android service/payment devices, and the generic
  `andock@1.0` isolated-process Linux execution device. Andock owns its private
  Android transport here, consumes the neutral contract from `common/`, and
  builds without an application checkout. The overlay intentionally does not
  fork `measurement@1.0`, `andee@1.0`, or `zone@1.0`.

Generated `_build/`, runtime caches, and local `rebar.lock` files are ignored.
Do not vendor generated HyperBEAM checkouts here.
