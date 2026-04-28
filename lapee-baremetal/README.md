# lapee-baremetal

**LapEE** (Laptop Execution Environment) is an attested-appliance
reference implementation for HyperBEAM. You write one 1 GB image to
a USB stick, plug the stick into a commodity TPM2 laptop, and the
laptop boots as a measured + signed HyperBEAM node: the TPM
endorses its own identity in silicon, the firmware event log is
extended with every measurement from UEFI handoff through UKI
load, and HyperBEAM emerges as PID 2 serving a full attestation
envelope at `/~tpm2@2.0a/attestation`. A verifier parses the
envelope into an auditable dashboard. Paper-committed machine-
identifying fields (CPU, TPM, TME/SME, Secure Boot, IOMMU) are
all surfaced with tiered evidence. Zero synthesized values
anywhere in the runtime path -- every field comes from a live
hardware signal or is recorded as explicitly absent.

Full spec: [`../lapee-paper/main.tex`](../lapee-paper/main.tex).

## Quick start

Prerequisites (one-time install on the verifier Mac):

```bash
brew install erlang rebar3 docker swtpm qemu python@3
# Start Docker Desktop. Docker runs amd64 images natively on
# Linux x86_64 hosts and via Rosetta on Apple Silicon — the
# Makefile detects host arch and only adds --platform=linux/amd64
# when needed.
```

Prerequisites on the target laptop (the TPM2 laptop you're attesting):

- UEFI firmware + discrete or fTPM 2.0.
- Secure Boot posture: the default USB image is unsigned (boot
  with SB off). The operator-provisioned signed-UKI workflow via
  `scripts/sb-setup.sh` is validated on iron.
- USB-A or USB-C port able to boot from external media.

Build, write, boot, verify:

```bash
git clone <lapee-repo>          # this repo
cd lapee/lapee-baremetal

make toolchain           # one-time; pulls pinned upstream Docker
                         #   bases (debian:12-slim,
                         #   erlang:27.3.4.10) by SHA-256 digest
                         #   and builds three thin amd64 toolchain
                         #   images on top.
make hb-fetch            # one-time; clones HyperBEAM at HB_COMMIT
                         #   into build-hyperbeam/src-edge/. Use
                         #   `HB_SRC=path/to/local make hb-fetch'
                         #   to rsync from a sibling worktree.
make kernel              # build LapEE kernel via Buildroot. The
                         #   Bootlin pre-built x86_64 musl stable
                         #   cross-toolchain is fetched by Buildroot
                         #   on first run and cached in the docker
                         #   volume. First build ~30 min on Rosetta;
                         #   incremental ~3 min.
                         #   Artefact: build-kernel/vmlinuz-lapee.
make hb-release          # HyperBEAM release with dev_tpm2 NIF.
                         #   ~3 min incremental.
make hb-initramfs        # packs the release + busybox + WiFi
                         #   firmware + init script into
                         #   work/initramfs-hb.cpio.gz
make hb-usb-image        # wraps kernel + initramfs into a UEFI-
                         #   bootable USB image at work/lapee-usb.img

# Write to a physical USB. Use `diskutil list' (macOS) to find diskN.
# The write target gathers WiFi credentials first if wifi.conf is absent;
# use WIFI=0 to skip that prompt.
make hb-usb-write DEV=/dev/diskN

# To diagnose boot/network failures on a real laptop, use a measured
# debug-console image. This adds `lapee.debug=1' to the UKI cmdline,
# disables the splash, prints hardware/network/init stages on the
# laptop panel, and routes HyperBEAM startup output to the console.
make hb-usb-debug-write DEV=/dev/diskN

# Optional: gather or replace WiFi credentials before building/writing.
make gather-wifi-creds

# WiFi credential format on the ESP is EXACTLY:
#
#     SSID
#     PASSWORD
#
#   (two lines, nothing else). The default Makefile cmdline already
#   includes `lapee.wifi=enabled'; use WIFI=0 on hb-usb-write to build
#   a stick without gathering/staging wifi.conf.

# Plug the USB into the target laptop. Power on. Select USB boot from
# the firmware menu (F2 / F12 / Esc depending on vendor). The boot
# splash spins a 3D wireframe laptop with a status line beneath:
#   "starting LapEE..." -> "network up; starting HyperBEAM..." ->
#   "starting HyperBEAM... <IP> (Ns)" -> "Running at http://<IP>:8734/"
# The measured cmdline selector `lapee.splash=' chooses the layout.
# The Makefile default is `SPLASH=blue`; override it for experiments:
#   qr      right-side HyperBEAM console + QR-style node mark
#   max     full-frame green laptop
#   deck    magenta boot-deck telemetry rail
#   sigil   public-key-inspired machine sigil and constellation field
#   blue    friendly blue-screen boot receipt
#   orbit   orbital proof field around the laptop
#   matrix  green measured-boot stream
#   plaque  bookshelf/display-object identity card
#   classic original centered wireframe laptop
#
# The USB stick is input-only at runtime. Init mounts the ESP
# read-only just long enough to read optional wifi.conf, unmounts it,
# then detaches the parent block device before network/HB startup
# where the kernel exposes a delete hook. The attestation path is
# over the network:

./scripts/interpret-local-capture.sh --url http://<node-ip>:8734 \
    --label 'my laptop'

# A browser tab opens with the dashboard. verdict=trusted means
# every paper-committed property resolved cleanly; =warnings means
# at least one property is disabled at the user / firmware level
# (e.g. Secure Boot off is a warning, not a critical); =untrusted
# means at least one critical failure (e.g. EK chain-valid=false).
```

Pre-flight firmware notes by vendor:

- **Framework 13 / 16** (tested end-to-end): Insyde H2O requires
  a Supervisor Password to be set BEFORE the Secure Boot toggle
  appears in the UI. This is the one firmware-settings gotcha.
- **Any other UEFI+TPM2 laptop** (not yet tested on iron): the
  USB image uses the UEFI fallback path `\EFI\Boot\BootX64.efi`
  so no NVRAM BootOrder entry is needed. Report firmware-side
  gotchas as issues.

## What this proves

The verifier's dashboard resolves the following paper-committed
properties, each with tiered evidence chaining up to the TPM's
Endorsement Key:

- **EK cert** read from real TPM NV storage (`0x01C00002` and
  adjacent `0x01C00003` for intermediate CA), chain-validated
  against 51 vendor root CAs shipped under
  `priv/tpm-interpret/root-cas/` (Infineon / Intel PTT / Nuvoton /
  STMicro / GlobalSign / Alibaba / Nationz). TCG-specific EKU +
  specInfo extensions whitelisted via a `verify_fun' so real EK
  certs don't trip OTP's default path validator.
- **TPM quote** (`TPM2_Quote`): signature valid under the AK
  pubkey; PCR digest re-computed byte-for-byte matches the
  quoted digest; nonce matches the caller's challenge.
- **Event-log replay** re-folds every measurement into the
  quoted PCR values (0, 1, 7, 11, 14 on the Framework baseline).
- **AK identity + node-message ID** bound into PCR 15 via
  `~tpm2@2.0a/extend` at node start.
- **Firmware CRTM** matches a fingerprint in
  `priv/tpm-interpret/firmware-versions/*.json` (Framework's
  `IFR30` prefix is already in the corpus; add more vendors
  as you test them).
- **Kernel / UKI hash** in PCR 11 matches a known-good under
  `priv/tpm-interpret/uki-measurements/`.
- **Runtime platform probes** straight from the live kernel:
  `/proc/cpuinfo` (CPU vendor + model), SMBIOS DMI fields,
  `/sys/kernel/security/lockdown`, `/sys/kernel/iommu_groups`,
  `/sys/firmware/efi/efivars/SecureBoot-...`,
  `/sys/class/tpm/tpm0/tpm_version_major`.
- **TPM identity** from `TPM2_GetCapability` (manufacturer,
  vendor-string, spec version, firmware version) independently
  of the EK cert.

## Cross-node verification

Once the target laptop is booted and reachable on the network,
any HyperBEAM node can attest it with a fresh nonce challenge:

```bash
curl 'http://your-mac:8734/~tpm-interpret@1.0/verify-peer?peer=http://target-laptop:8734'
```

The peer-verify path generates a random 32-byte nonce, includes
it in the peer `/attestation` call, rejects with
`nonce_freshness: mismatch` BEFORE any crypto if the response's
quote nonce doesn't match. This is what makes an attestation
envelope un-replayable.
