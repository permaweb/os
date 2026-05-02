# LapEE

LapEE, the Laptop Execution Environment, turns an ordinary UEFI laptop
with a TPM 2.0 into a single-purpose HyperBEAM node. HyperBEAM is the
AO-Core runtime: it executes messages, produces signed results, and
participates in AO's distributed compute network. Boot LapEE from a USB
stick and the laptop starts that runtime, shows a QR code for the node
URL, and serves a TPM-backed boot attestation at:

```text
http://<node-ip>:8734/~tpm@2.0a/boot-attestation
```

The point is simple: people should be able to contribute useful AO-Core
compute using commodity hardware they already own, while giving users
and other nodes something concrete to verify about the machine that is
doing the work.

Why this can work on commodity hardware: UEFI, TPM 2.0, Secure Boot,
and measured boot already ship in ordinary laptops. LapEE uses those
parts to bind an operator-owned HyperBEAM node to a measured boot,
instead of requiring a cloud TEE vendor to host the worker.

LapEE is not a magic cloud TEE and does not make arbitrary multi-tenant
Linux safe. It takes a different trade-off: make the whole laptop one
auditable appliance OS/node, keep local inputs and writable runtime
storage out of the production path, and let AO-Core get tenancy by
distributing work across HyperBEAM workers. Single-tenant here means
one appliance OS/node; it is not a proof that arbitrary AO workloads are
safely isolated from each other by LapEE itself. The TPM quote,
firmware event log, PCR-15 HyperBEAM start events, Secure Boot state,
and node identity let a verifier ask, "what actually booted, and what
key is speaking for it?"

## Quick Start

Most operators should start from a pre-built image supplied by a release
or by someone they trust for the current test. Building from source is
supported, but it is not the first thing a new hardware tester needs to
do. Run these commands from the repository root.

1. Download or receive a LapEE USB image, usually named
   `lapee-usb.img`.
2. Put it at the default repo path:

   ```sh
   mkdir -p build/images
   cp /path/to/lapee-usb.img build/images/lapee-usb.img
   ```

3. Verify the supplied SHA-256 hash against a signed release note or a
   coordinator-provided hash obtained separately:

   ```sh
   printf '<expected-sha256>  build/images/lapee-usb.img\n' | shasum -a 256 -c -
   ```

4. Add WiFi credentials if they were not already baked into the image.
   This uses the small Docker tooling container to edit the FAT ESP, so
   Docker Desktop should be running. This builds tooling only; it does
   not rebuild LapEE itself:

   ```sh
   make gather-wifi-creds
   make hb-wifi-apply
   ```

   `wifi.conf` is plaintext and is copied into the image. After this
   step, both `wifi.conf` and `build/images/lapee-usb.img` contain the WiFi
   password; do not share them. Adding `wifi.conf` changes the disk
   image hash, but not the UKI hash used by Secure Boot hash enrollment.

5. Write the image to a USB stick. This destroys the selected disk. Use
   the removable whole disk from `diskutil list`, not `/dev/disk0` and
   not a partition like `diskNs1`:

   ```sh
   diskutil list
   make hb-image-write DEV=/dev/diskN
   ```

6. If Secure Boot is enabled, disable it or follow the Secure Boot
   section before booting. Then boot the laptop from the USB stick.
   When the blue splash reaches
   `Running at http://...`, scan the QR code or open the shown URL.

Framework 13 is the primary tested laptop. Other UEFI + TPM 2.0 laptops
may work, especially if their network hardware is supported by the
kernel and firmware set in this image. Physical production boots
currently require CPU TME/SME capability; unsupported physical machines
halt early. TME/SME activation state is reported for verifier policy
rather than treated as an unconditional guarantee.

## Verify A Running Node

From another machine on the same network. On macOS, install the local
verifier dependencies first:

```sh
brew install erlang rebar3 python@3
```

`git`, `curl`, and network access are also required. Then run:

```sh
make hb-fetch
./scripts/interpret-local-capture.sh \
  --url http://<node-ip>:8734 \
  --label "Framework 13"
```

The verifier fetches the node's attestation evidence, interprets it,
and writes an HTML dashboard under:

```text
build/hyperbeam/src-edge/out/local-capture/<label-slug>/dashboard.html
```

Useful live endpoints:

```text
http://<node-ip>:8734/~tpm@2.0a/info
http://<node-ip>:8734/~tpm@2.0a/pcr-read&pcr=0
http://<node-ip>:8734/~tpm@2.0a/boot-attestation
http://<node-ip>:8734/~system@1.0/all
http://<node-ip>:8734/~hyperbuddy@1.0/index
```

## What The Dashboard Checks

The attestation dashboard reports cryptographic checks and policy
posture separately. A real machine can be useful while still carrying
warnings that should be understood.

It checks:

- TPM EK and AK material, when the firmware provisions EK certificates.
- TPM quote signature, nonce, selected PCR values, and PCR digest
  consistency. A valid quote proves the reported PCR values came from
  the quoted AK/TPM; accepting those PCRs still requires verifier policy
  and known-good baselines.
- Firmware TCG event log replay where firmware exposes the log.
- Runtime PCR-15 events emitted by the LapEE HyperBEAM start hook,
  tying the HyperBEAM node identity to the boot.
- Secure Boot state, kernel lockdown, IOMMU/TME hints, CPU/DMI/TPM
  identity, and measured kernel command line.

Secure Boot off or hash-only admission may be a warning or policy
limitation. A failed quote signature, missing required TPM proof, or
PCR/event-log inconsistency is much more serious.

## Security Model

LapEE narrows the machine instead of trying to make a general-purpose
desktop safe.

In production:

- The laptop is intended to be single-purpose and single-tenant at the
  OS level.
- Keyboard, mouse, touchpad, HID, Bluetooth, sound, USB4/Thunderbolt,
  SysRq, debugfs, `/dev/mem`, kexec, hibernation, and suspend support
  are disabled in the production kernel profile.
- The boot USB is treated as an input medium, not a writable runtime
  store. Init mounts the ESP read-only just long enough to read optional
  `wifi.conf`, unmounts it, marks/detaches the parent block device, and
  then starts network and HyperBEAM.
- HyperBEAM runs with stdin/stdout/stderr on `/dev/null`; the splash is
  the only intended local output.
- Verification happens over the network attestation endpoint, not by
  writing logs back to the USB stick.

This does not protect against every physical attack, malicious firmware,
or all bugs in HyperBEAM, Linux, drivers, or the TPM stack. It is a
practical appliance posture for commodity laptops: minimize local
interaction, make the boot/runtime identity observable, and let AO-Core
schedule work at the protocol layer.

This is not a hardware USB firewall. Firmware and early kernel boot
still consume the boot USB/ESP before init deauthorizes USB devices.

## Limitations And Non-Goals

Attestation is evidence, not a TEE guarantee. It does not make firmware
honest, does not prove HyperBEAM or Linux bug-free, and does not isolate
mutually distrustful workloads inside the same OS process/kernel
boundary.

LapEE currently depends on local WiFi credentials or pre-provisioned
networking, and production USB tethering is intentionally not expected.
Network hardware coverage is broad but not universal. Secure Boot
policy is operator/firmware-specific, and verifier acceptance still
depends on policy and baselines rather than on "TPM present" alone.

## Secure Boot

The default image is an unsigned UKI at the UEFI fallback path
`\EFI\Boot\BootX64.efi`.

For testing, the simplest path is usually:

- Disable Secure Boot, or
- Use firmware support to trust/enroll the exact UKI hash.

Hash enrollment is byte-for-byte specific to the UKI. Rebuilding the
image changes the UKI and requires enrolling the new image hash.
Locally adding `wifi.conf` changes the disk image hash, but it does not
change `\EFI\Boot\BootX64.efi` and therefore does not change the UKI
hash. Prefer the firmware's "Enroll EFI image/hash" UI by browsing to
`BootX64.efi`; do not assume a plain `shasum -a 256` file hash is the
exact format every firmware UI expects.

For an operator-owned Secure Boot chain on an image you build locally,
start from a completed source build:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build
./scripts/sb-setup.sh keys
./scripts/sb-setup.sh enrol
./scripts/sb-setup.sh sign
make hb-sb-apply
make hb-image-write DEV=/dev/diskN
```

For the no-TME test/runtime image, use the signed no-TME wrapper target:

```sh
make hb-sb-keys
make hb-usb-no-tme-signed-write DEV=/dev/diskN
```

On Framework firmware, Secure Boot controls usually require setting a
supervisor/admin password. Enroll `db`, then `KEK`, then `PK`; enrolling
`PK` exits setup mode. Entering setup mode clears factory Microsoft keys
and may affect booting other operating systems until factory keys are
restored.

Some firmware exposes Secure Boot Setup Mode but does not expose a useful
UI for enrolling keys or image hashes. For those machines, LapEE can build
a one-shot provisioning image. This image contains only public enrollment
artifacts on the ESP and enrolls the operator `db`, `KEK`, then `PK` while
the firmware is already in Setup Mode:

```sh
make hb-sb-keys
make hb-sb-provisioner-write DEV=/dev/diskN
```

Boot that USB once with firmware in Secure Boot Setup Mode. It should print
the enrollment progress and then stop. Power off, enable Secure Boot if the
firmware did not do so automatically, then flash and boot the signed runtime
image:

```sh
make hb-usb-no-tme-signed-write DEV=/dev/diskN
```

Keep `secureboot/*.key` private. They are operator keys and are ignored by
git. The files under `secureboot/enrol/` are public enrollment artifacts.

A downloaded `.img` alone is not enough for the `sb-setup.sh sign`
workflow unless the release also provides the UKI or a signed-image
workflow. For a pre-built unsigned test image, hash enrollment or Secure
Boot-off is the simpler path.

Secure Boot controls firmware admission of the UKI. It is related to,
but separate from, the runtime TPM quote served by the node.

## Build From Source

The default developer build uses Docker and the host architecture. On
Apple Silicon, that means a native `linux/arm64` build container that
cross-compiles the x86_64 laptop target.

Requirements by task on macOS:

```sh
brew install qemu swtpm erlang rebar3 python@3
```

Docker Desktop must be running for the default source-build path and
for ESP-edit helpers such as `hb-wifi-apply`. QEMU and swtpm are needed
for `make hb-usb-qemu` and the four-node green-zone acceptance harness;
Erlang/rebar3/Python are needed by the attestation dashboard wrapper.

Build with all useful local cores:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build
```

The build produces:

```text
build/images/lapee-usb.img
```

By default the USB image is auto-sized from the generated UKI and the
small files staged into the ESP. It is not fixed at 1 GiB. It still
includes GPT, FAT32 metadata, and a little compatibility margin around
the payload, so it will be larger than `BootX64.efi` itself. Override
with `SIZE_MIB=...` only when you deliberately want a larger image.

Smoke-test the image in QEMU:

```sh
make hb-usb-qemu
```

Run the TPM-backed green-zone acceptance gate:

```sh
make qemu-green-zone-cluster
```

That boots four QEMU+swtpm nodes. Three nodes share the measured
configuration and must join the green-zone and sign with the same ring
wallet; the fourth carries a different measured command line and must
fail admission with `template-mismatch` and fail to sign as the ring.

Write a freshly built image directly to USB:

```sh
make hb-usb-write DEV=/dev/diskN
```

`hb-usb-write` rebuilds/wraps the current kernel and initramfs before
writing. To write an existing pre-built image without rebuilding, use
`make hb-image-write DEV=/dev/diskN`.

Reference build:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build REFERENCE=1
```

`REFERENCE=1` forces `linux/amd64` Docker for every step. On Apple
Silicon this uses Rosetta. Use it for publishable hashes and
reproducibility checks.

Linux native build:

```sh
make native-build
```

That path runs Buildroot directly on a Linux host without Docker.

Useful incremental targets:

```sh
make toolchain
make kernel
make hb-usb-image
make hb-usb-qemu
make hb-usb-qemu-gui
make qemu-green-zone-cluster
make gather-wifi-creds
make hb-wifi-apply
make hb-usb-debug-write DEV=/dev/diskN
```

Debug mode adds `lapee.debug=1` to the measured kernel command line,
disables the splash, and prints hardware, WiFi, DHCP, and HyperBEAM
startup stages on the laptop display. It intentionally keeps more local
diagnostic surface than production.

## What Gets Built

The image contains:

- Linux 6.19.12 with EFI stub, TPM, lockdown, WiFi, framebuffer, and
  common laptop networking support.
- A Buildroot-generated initramfs with busybox, glibc, Erlang/OTP 27,
  OpenSSL, libtss2, wpa_supplicant, iproute2, iw, zstd, and HyperBEAM.
- A custom Buildroot `hyperbeam` package that fetches pinned upstream
  HyperBEAM `edge`, stages LapEE-owned TPM devices from
  `hyperbeam-overlay/`, builds Erlang code, and cross-compiles the TPM
  NIF against Buildroot's libtss2.
- A UEFI Unified Kernel Image placed at `\EFI\Boot\BootX64.efi` on a
  single FAT32 ESP.

The build uses a Buildroot-built target toolchain
(`BR2_TOOLCHAIN_BUILDROOT=y`). On a fresh build, gcc, binutils, glibc,
the kernel, target userspace, and HyperBEAM are compiled from source.

The remaining prebuilt bytes in the shipped boot path are explicit: the
x64 UEFI stub from Debian's `systemd-boot-efi` package, used to wrap the
kernel/initramfs as a UKI, and vendor firmware blobs for WiFi and common
USB/Ethernet adapters. The target Linux userspace and HyperBEAM release
are built from source.

## Troubleshooting

- QEMU passes but laptop WiFi does not: if you built from source or have
  release debug artefacts, write a debug image with
  `make hb-usb-debug-write DEV=/dev/diskN` and inspect the visible
  `wlan0`, `wpa_supplicant`, and `udhcpc` stages.
- `/attestation` fails but `/pcr-read&pcr=0` works: the TPM is alive;
  the failure is likely in quote/key policy, EK material, or verifier
  policy, not basic TPM discovery.
- `interpret-local-capture.sh` says no HyperBEAM checkout: run
  `make hb-fetch`, or set `REPO=/path/to/HyperBEAM`.
- macOS asks for a password while writing: the write path uses `sudo dd`
  against `/dev/rdiskN`.
- USB tethering is not expected in production builds because production
  disables local USB device/input surface after the boot ESP read.

## Repo Layout

- `Makefile` - operator and build entry points.
- `buildroot-external/board/lapee/rootfs-overlay/init` - appliance init,
  production hardening, WiFi, splash, TPM/HyperBEAM startup.
- `buildroot-external/board/lapee/linux-m1-fragment.config` - kernel
  config fragment for TPM, networking, framebuffer, and production
  input-surface reduction.
- `buildroot-external/package/hyperbeam/` - Buildroot package for the
  pinned HyperBEAM release.
- `hyperbeam-overlay/` - LapEE-owned HyperBEAM device modules, TPM NIF
  sources, verifier catalogues, and the `lapee` rebar profile fragment
  staged into the temporary HyperBEAM checkout during builds.
- `scripts/` - image assembly, QEMU boot, verifier capture, WiFi and
  Secure Boot helpers.
- `secondary-external-verifier/` - standalone Python verifier for
  reviewers and CI-style checks.
- `paper/` - research paper and design notes.

`build/`, `wifi.conf`, and `secureboot/` are local/operator artefacts
and are intentionally ignored by git. `build/` contains generated
images, initramfses, QEMU scratch state, splash captures, the local
HyperBEAM verifier checkout, and attestation dashboards.
