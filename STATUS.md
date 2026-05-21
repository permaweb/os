# LapEE Packaged Devices Status

Branch: `IMPR/packaged-devices`

Mission: update LapEE to latest HyperBEAM `edge` and make the repo an OS image
wrapper around a stock HyperBEAM kernel. LapEE-owned devices live under
`hyperbeam-devices/` and are consumed through HyperBEAM Forge device packaging
instead of being staged into the HyperBEAM source tree.

## Current State

- HyperBEAM pin: `8c19c6adb45fc658e1ac06e6555efd916fd305e5`.
- The old overlay tree is now `hyperbeam-devices/`.
- The old staging script and `lapee` rebar profile fragment are gone.
- LapEE helper modules are Forge `lib_*` libraries:
  `lib_hb_db_tpm`, `lib_lapee_aia`, `lib_lapee_nonvolatile`,
  `lib_lapee_peer_http`, and `lib_lapee_tpm_tcg`.
- LapEE's SNP implementation is packaged from `dev_lapee_snp` while still
  implementing the public `snp@1.0` device name, avoiding a collision with
  HyperBEAM's built-in `dev_snp`.
- Native TPM/SNP wrappers stay stable as `lapee_tpm_nif` and
  `lapee_snp_nif`; Buildroot compiles their target BEAM/SO files into each
  relevant device's packaged `priv` payload before running
  `rebar3 device preload`.
- Init exports `HB_PRELOADED_STORE` and `HB_PRELOADED_DEVICES_INDEX` from the
  installed preloaded-store/index file, so runtime resolution uses the
  LapEE-packaged store even though the HyperBEAM release itself is stock.
- TPM/SNP NIF wrapper modules are stored as package `priv` resources and
  explicitly loaded by stable module name from each device archive's
  implementation directory, while the release remains in embedded-code mode.

## Validation

- `make hb-fetch`: pass. Checkout is stock HyperBEAM at
  `8c19c6adb45fc658e1ac06e6555efd916fd305e5`.
- Host Forge smoke:
  `rebar3 device preload --device-src src/preloaded,<repo>/hyperbeam-devices/src`
  generated a preloaded store containing `measurement@1.0`, `system@1.0`,
  `tpm@2.0a`, `snp@1.0`, and `zone@1.0`.
- `make verify-config-invariants`: pass.
- `bash -n scripts/build-buildroot.sh`: pass.
- `sh -n buildroot-external/board/lapee/rootfs-overlay/init`: pass.
- `git diff --check`: pass.
- `make runtime-image TME=0`: pass; generated
  `build/images/lapee-runtime-no-tme-signed.img`.
  - Image SHA-256:
    `f100e021823612b824f8fbe497ff4e6675609d7cee44c4e22366752d13ab6ca1`.
  - Boot-attested UKI SHA-256:
    `7ELlW3w4f2mA_DuQjSDN0wpzD_Ph8fqwxEKnvG7NNnY`.
- `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass;
  `/info`, `~measurement@1.0/boot`, and `~system@1.0/all` answered.
- `make qemu-zone IMG=build/images/lapee-runtime-no-tme-signed.img`: pass;
  three TPM/swtpm nodes admitted, fourth node rejected.
- `make qemu-zone-nonvolatile IMG=build/images/lapee-runtime-no-tme-signed.img`:
  pass; encrypted zone store survives reboot and refreshes current boot
  measurement paths after rejoin.
- `make qemu-operator-config IMG=build/images/lapee-runtime-no-tme-signed.img`:
  pass; operator config appears in node info, boot measurement evidence, and
  PCR15 replay, and only the configured node can initialize a signer-required
  zone.
- `make provisioner-image`: pass; generated signed Secure Boot provisioner
  image at `build/images/lapee-sb-provisioner.img`.
  - Image SHA-256:
    `86d9efe226e2060e9890c6c158e00738c68a5ca859930b5707202b4eaa1ece44`.
- `make qemu-provisioner-nonvolatile`: pass; provisioner finds and labels the
  non-volatile zone partition path.
- `make qemu-measurement-remote` against `hb@dev-1.forward.computer`: pass;
  a real SEV-SNP guest boots the same image and exposes SNP measurement
  evidence through `~measurement@1.0`.
- `make qemu-zone-remote-snp` against `hb@dev-1.forward.computer`: pass;
  four real SEV-SNP guests booted, three admitted, one rejected, and all
  admitted nodes produced ring-signed membership proofs.
