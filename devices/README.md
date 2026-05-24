# HyperBEAM Device Packages

PermawebOS behavior is packaged as normal HyperBEAM Forge device packages.
These are distribution devices, not kernel patches.

- `common/` is the shared package: `measurement@1.0`, `system@1.0`,
  `tpm@2.0a`, `snp@1.0`, `andee@1.0` (AndEE), `zone@1.0`, native TPM/SNP
  helpers, and trusted measurement root material. Linux images use it
  directly. Other architectures stage it with their architecture-specific
  package before compiling. Architecture-specific measurement devices live here
  when their verification path is portable; unsupported local generation fails
  softly while peer verification remains available.
- `android/` is the Android package overlay: app-private encrypted store
  support, AndEE metadata, and Android service/payment devices. It intentionally
  does not fork `measurement@1.0`, `andee@1.0`, or `zone@1.0`.

Generated `_build/`, runtime caches, and local `rebar.lock` files are ignored.
Do not vendor generated HyperBEAM checkouts here.
