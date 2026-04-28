# LapEE

LapEE, the Laptop Execution Environment, turns an ordinary UEFI +
TPM 2.0 laptop into a TPM-attested HyperBEAM appliance. Build one
USB image, boot a laptop from it, and the machine comes up as a
single-purpose HyperBEAM node with a QR boot screen and a live
attestation endpoint at:

```text
http://<node-ip>:8734/~tpm2@2.0a/attestation
```

The attestation envelope contains the TPM quote, EK/AK material,
firmware event log, runtime PCR-15 event log, node message, and
platform probes. The verifier turns that into a dashboard that says
what was actually observed, what chained cryptographically, and what
policy posture the machine reached.

This repo has two main pieces:

- `lapee-baremetal/`: the appliance build, USB image tooling, boot
  init, splash, QEMU harness, and verifier dashboard wrapper.
- `lapee-paper/`: the paper and design notes for the security model.

Start with [lapee-baremetal/README.md](lapee-baremetal/README.md) for
the operator guide.

## Current State

LapEE now uses Buildroot as the build owner for the guest userspace.
On a fresh build, Buildroot bootstraps the target cross-toolchain from
source, then compiles the x86_64 laptop image: Linux, glibc, busybox,
Erlang/OTP, OpenSSL, libtss2, wpa_supplicant, iproute2, iw, and the
custom HyperBEAM package.

The remaining prebuilt bytes in the shipped boot path are explicit:
the x64 UEFI stub from Debian's `systemd-boot-efi` package, used to
wrap the kernel/initramfs as a UKI, and vendor firmware blobs for WiFi
and common USB/Ethernet adapters. The target Linux userspace and
HyperBEAM release are built from source.

The default build runs Docker at the host architecture. On Apple
Silicon that means a native `linux/arm64` build container that
cross-compiles the x86_64 laptop target. `REFERENCE=1` forces
`linux/amd64` Docker everywhere for publishable/reproducible builds.

## Quick Build

```sh
cd lapee-baremetal

# macOS / Docker path, using all useful local cores.
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build

# Optional QEMU smoke test. Fetches a live attestation envelope from
# the booted guest over 127.0.0.1:18734.
make hb-usb-qemu

# Write to a USB stick. Pick the whole disk from `diskutil list`.
make hb-usb-write DEV=/dev/diskN
```

Boot the target laptop from the USB stick. When the splash reaches the
ready state, scan the QR code or open the shown URL. To produce the
dashboard:

```sh
make hb-fetch
./scripts/interpret-local-capture.sh \
  --url http://<node-ip>:8734 \
  --label "Framework 13"
```

## Secure Boot

The normal USB image is a UEFI fallback boot image at
`\EFI\Boot\BootX64.efi`. It can boot with Secure Boot disabled. With
Secure Boot enabled, either enroll operator-owned keys using
`lapee-baremetal/scripts/sb-setup.sh` or use firmware support for
trusting the produced UKI hash.

Secure Boot decides whether firmware will launch the UKI. It is
separate from the runtime TPM quote exposed by `~tpm2@2.0a`.

## Runtime Posture

The USB stick is treated as an input medium, not a writable runtime
store. Init mounts the ESP read-only just long enough to read optional
WiFi credentials, unmounts it, then detaches the parent block device
before networking and HyperBEAM startup. Production verification flows
use the network attestation endpoint rather than files written back to
the USB stick.

For debugging real hardware, `make hb-usb-debug-write DEV=/dev/diskN`
builds a measured debug-console image. The `lapee.debug=1` kernel
command-line token is visible in attestation, disables the splash, and
prints hardware/network/HyperBEAM startup stages on the laptop panel.

## Repo Conventions

- `wifi.conf`, `secureboot/`, `work/`, and `out/` are local/operator
  artefacts and are not committed.
- Collaborator operating notes live in
  [lapee-baremetal/CLAUDE.md](lapee-baremetal/CLAUDE.md).
- The paper source lives in [lapee-paper/main.tex](lapee-paper/main.tex).
