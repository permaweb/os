# HyperBEAM Device Packages

PermawebOS behavior is packaged as normal HyperBEAM device packages.

- `common/` is the shared package: `measurement@1.0`, `system@1.0`,
  `tpm@2.0a`, `snp@1.0`, `handee@1.0`, `zone@1.0`, native TPM/SNP helpers,
  and trusted measurement root material. Linux images use it directly. Other
  architectures stage it with their architecture-specific package before
  compiling. Architecture-specific measurement devices still live here when
  their verification path is portable; unsupported local generation fails
  softly while peer verification remains available.
- `android/` is the Android package overlay: app-private encrypted store
  support, HandEE metadata, and the Android bundler/payment devices imported
  from the HandEE branch. It intentionally does not fork `measurement@1.0`,
  `handee@1.0`, or `zone@1.0`.

Generated `_build/`, runtime caches, and local `rebar.lock` files are ignored.
Do not vendor generated HyperBEAM checkouts here.
