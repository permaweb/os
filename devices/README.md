# HyperBEAM Device Packages

PermawebOS behavior is packaged as normal HyperBEAM device packages.

- `permawebos/` is the Linux LapEE package: `measurement@1.0`,
  `system@1.0`, `tpm@2.0a`, `snp@1.0`, `zone@1.0`, native TPM/SNP helpers,
  and trusted TPM EK root material.
- `android/` is the Android HandEE package: Android measurement, encrypted
  app-private store support, HandEE metadata, zone logic, and the current
  Android bundler/payment devices imported from the HandEE branch.

Generated `_build/`, runtime caches, and local `rebar.lock` files are ignored.
Do not vendor generated HyperBEAM checkouts here.
