# LapEE

LapEE, the Laptop Execution Environment, turns commodity hardware into a
single-purpose HyperBEAM appliance node. HyperBEAM is the AO-Core runtime:
it executes messages, produces signed results, and participates in AO's
distributed compute network. Boot LapEE from a USB stick and the machine
starts that runtime, shows a QR code for the node URL, and serves a signed
hardware measurement at:

```text
http://<node-ip>:8734/~measurement@1.0/boot
```

The point is simple: people should be able to contribute useful AO-Core
compute using commodity hardware they already own, while giving users
and other nodes something concrete to verify about the machine that is
doing the work.

Why this can work on commodity hardware: UEFI, TPM 2.0, Secure Boot,
measured boot, and newer hardware measurement engines already ship in
ordinary laptops and servers. LapEE uses those parts to bind a HyperBEAM
node to a measured boot and node message, instead of requiring every
worker to be hosted by one cloud TEE vendor.

LapEE is not a magic cloud TEE and does not make arbitrary multi-tenant
Linux safe. It takes a different trade-off: make the whole laptop one
auditable appliance OS/node, keep local inputs and writable runtime
storage out of the production path, and let AO-Core get tenancy by
distributing work across HyperBEAM workers. Single-tenant here means
one appliance OS/node; it is not a proof that arbitrary AO workloads are
safely isolated from each other by LapEE itself. The measurement device,
firmware event log, Secure Boot state, system report, and node identity
let a verifier ask, "what actually booted, and what key is speaking for
it?"

## Quick Start

Most operators should start from a signed runtime image supplied by a
release or by someone they trust for the current test. Building from
source is supported, but it is not the first thing a new hardware tester
needs to do. Run these commands from the repository root.

1. Download or receive a LapEE runtime USB image, usually named
   `lapee-usb.img`, plus its signed release note or hash.
2. Verify the supplied SHA-256 hash against the signed release note or a
   coordinator-provided hash obtained separately:

   ```sh
   printf '<expected-sha256>  /path/to/lapee-usb.img\n' | shasum -a 256 -c -
   ```

3. Put the image at the default repo path:

   ```sh
   mkdir -p build/images
   cp /path/to/lapee-usb.img build/images/lapee-usb.img
   ```

4. Add WiFi credentials if they were not already baked into the image.
   This uses the small Docker tooling container to edit the FAT ESP, so
   Docker Desktop should be running. This builds tooling only; it does
   not rebuild LapEE itself:

   ```sh
   make wifi-creds
   make operator-config-apply IMAGE=build/images/lapee-usb.img
   ```

   `wifi.conf` is plaintext and is copied into the image. After this
   step, both `wifi.conf` and `build/images/lapee-usb.img` contain the WiFi
   password; do not share them. Adding `wifi.conf` changes the disk
   image hash, but not the signed UKI on the ESP. If you also want
   public operator config, create `config.json` before running
   `make operator-config-apply`; see the next section.

5. Write the image to a USB stick. This destroys the selected disk. Use
   the removable whole disk from `diskutil list`, not `/dev/disk0` and
   not a partition like `diskNs1`:

   ```sh
   diskutil list
   make write-image DEV=/dev/diskN IMAGE=build/images/lapee-usb.img
   ```

6. If the firmware does not already trust the runtime image, disable
   Secure Boot or follow the Secure Boot section before booting. Then
   boot the laptop from the USB stick. When the blue splash reaches
   `Running at http://...`, scan the QR code or open the shown URL.

Framework 13 is the primary tested laptop. Other UEFI + TPM 2.0 laptops
may work, especially if their network hardware is supported by the
kernel and firmware set in this image. Runtime images normally require
CPU TME/SME capability. Test images can be built with the measured
`LAPEE_NO_TME=1` flag for hardware that lacks it; verifiers see that
flag in node evidence and can decide whether to accept the node.

## Operator Config

`config.json` is optional public HyperBEAM configuration for this node.
LapEE reads it once from the boot USB ESP, copies it into tmpfs as
`/tmp/config.json`, unmounts and detaches the USB, then starts HyperBEAM
with:

```text
HB_CONFIG=/tmp/config.json,/etc/lapee/lapee.json
```

The measured LapEE config is last, so enforced measurement devices and
the boot measurement hook remain part of the node. Operator-controlled
keys such as `load-remote-devices` and `trusted-device-signers` are not
set by the measured base config, so deployments can opt in explicitly
and have that choice included in boot measurement evidence. Do not put
secrets in `config.json`: it is public operator policy.

A small example:

```json
{
  "zone-allow": 1,
  "load-remote-devices": true,
  "trusted-device-signers": [
    "WjnS-s03HWsDSdMnyTdzB1eHZB2QheUWP_FVRVYxkXk"
  ]
}
```

Use HyperBEAM/AO-Core key spelling directly in `config.json`:
hyphenated keys such as `trusted-device-signers` and
`load-remote-devices`. Signer values are AO/Arweave-style base64url
addresses. Zone templates and external verifiers can match these node
message fields according to their deployment policy.

`zone-allow` controls whether this node may install zone identities. If
omitted, the node may initialize or join one zone during the current run. Use
`0` or `false` to disable zone joins, a positive integer to allow that many
zones, `true` for no count limit, a list of zone IDs to allow only those zones,
or a map of zone IDs to bootstrap peer URLs to auto-join those explicit zones
after HyperBEAM starts. Auto-join still uses normal peer verification, so the
node must also advertise a reachable `public-url` or `zone-self-url`.

## Verify A Running Node

From another machine on the same network. On macOS, install the local
verifier dependencies first:

```sh
brew install erlang rebar3 python@3
```

`git`, `curl`, and network access are also required. Then run:

```sh
make hb-fetch
curl -fsS http://<node-ip>:8734/~measurement@1.0/boot
```

The measurement endpoint returns the node's signed boot evidence.

```text
build/hyperbeam/src-edge/out/local-capture/<label-slug>/dashboard.html
```

Useful live endpoints:

```text
http://<node-ip>:8734/~tpm@2.0a/info
http://<node-ip>:8734/~measurement@1.0/info
http://<node-ip>:8734/~measurement@1.0/boot
http://<node-ip>:8734/~system@1.0/all
http://<node-ip>:8734/~zone@1.0/status
http://<node-ip>:8734/~hyperbuddy@1.0/index
```

## What The Dashboard Checks

The attestation dashboard reports cryptographic checks and policy
posture separately. A real machine can be useful while still carrying
warnings that should be understood.

It checks:

- Measurement envelope signatures and device-specific evidence.
- TPM EK and AK material, when the measurement backend is TPM and the
  firmware provisions EK certificates.
- TPM quote signature, nonce, selected PCR values, and PCR digest
  consistency. A valid quote proves the reported PCR values came from
  the quoted AK/TPM; accepting those PCRs still requires verifier policy
  and known-good baselines.
- SEV-SNP report signatures and report-data binding, when the measurement
  backend is SNP.
- Firmware TCG event log replay where firmware exposes the log.
- AK `authPolicy` over the quoted boot PCRs, including PCR 15, plus
  runtime PCR-15 replay tying the HyperBEAM boot subject to the AK.
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
  `wifi.conf` and `config.json`, unmounts it, marks/detaches the parent
  block device, and then starts network and HyperBEAM.
- HyperBEAM runs with stdin/stdout/stderr on `/dev/null`; the splash is
  the only intended local output.
- Verification happens over the network measurement endpoint, not by
  writing logs back to the USB stick.

This does not protect against every physical attack, malicious firmware,
or all bugs in HyperBEAM, Linux, drivers, or the TPM stack. It is a
practical appliance posture for commodity laptops: minimize local
interaction, make the boot/runtime identity observable, and let AO-Core
schedule work at the protocol layer.

This is not a hardware USB firewall. Firmware and early kernel boot
still consume the boot USB/ESP before init deauthorizes USB devices.

## Limitations And Non-Goals

Measurement is evidence, not a TEE guarantee. It does not make firmware
honest, does not prove HyperBEAM or Linux bug-free, and does not isolate
mutually distrustful workloads inside the same OS process/kernel
boundary.

LapEE currently depends on local WiFi credentials or pre-provisioned
networking, and production USB tethering is intentionally not expected.
Network hardware coverage is broad but not universal. Secure Boot
policy is operator/firmware-specific, and verifier acceptance still
depends on policy and baselines rather than on "TPM present" alone.

## Secure Boot

The runtime image boots a UEFI Unified Kernel Image at
`\EFI\Boot\BootX64.efi`. A signed release image is intended to be used
with Secure Boot once the firmware trusts either the signing key or the
exact UKI hash.

Secure Boot admission is byte-for-byte specific to the UKI. Locally
adding `wifi.conf` or `config.json` changes the disk image hash, but it
does not change `\EFI\Boot\BootX64.efi` and therefore does not change
the UKI signature or enrolled hash. Prefer the firmware's "Enroll EFI
image/hash" UI by browsing to `BootX64.efi`; do not assume a plain
`shasum -a 256` file hash is the exact format every firmware UI expects.

For an operator-owned Secure Boot chain, create local keys and keep the
private half private:

```sh
make signing-keys
```

If the firmware has a usable enrollment UI, enroll the public `db`,
`KEK`, and `PK` artifacts from `secureboot/enrol/`, or enroll the exact
runtime UKI hash. The signed runtime image and any no-TME test variant
must be admitted separately, because their measured UKI bytes differ.

On Framework firmware, Secure Boot controls usually require setting a
supervisor/admin password. Enroll `db`, then `KEK`, then `PK`; enrolling
`PK` exits setup mode. Entering setup mode clears factory Microsoft keys
and may affect booting other operating systems until factory keys are
restored.

Some firmware exposes Secure Boot Setup Mode but does not expose a useful
UI for enrolling keys or image hashes. For those machines, LapEE can build
a one-shot provisioning image. This image contains only public enrollment
artifacts on the ESP and enrolls the operator `db`, `KEK`, then `PK` while
the firmware is already in Setup Mode. The image selects LapEE's provisioning
flow by itself, but entering firmware Setup Mode is still a firmware-owner
operation and usually has to be done from the firmware setup UI:

```sh
make provisioner-write DEV=/dev/diskN
```

Boot that USB once with firmware in Secure Boot Setup Mode. After the
`I UNDERSTAND.` confirmation, the provisioner lists writable non-boot disks.
To prepare one for encrypted zone storage, type `DESTROY N` for the
listed disk number; to leave persistent storage unconfigured, type `SKIP`.
`DESTROY N` creates a `ZONE_PRIMARY` GPT partition, which binds to the
first zone the node successfully joins. To pre-bind the disk to a
specific zone, type `DESTROY N -> PREFIX`, where `PREFIX` is the first
characters of that zone's ring address; the partition will be named
`ZONE_PREFIX`, truncated to fit GPT's partition-name limit.

Either form destroys the selected disk's partition table and writes a LapEE
provisioning marker at the start of the new partition. It is not a secure
erase; the runtime will overwrite the selected partition with LUKS2 before
use. The runtime image will only first-format a non-LUKS partition when both
the expected GPT partition name and the LapEE marker are present. The
provisioner excludes the boot disk and obvious pseudo block devices, then
rechecks that the selected disk is still a writable non-boot block device
immediately before modifying it.

The provisioner should then print the enrollment progress and stop. Some
firmware still reports `SetupMode=1` until the next power cycle even after
accepting `PK`. Power off, enable Secure Boot if the firmware did not do so
automatically, then flash and boot a signed runtime image:

```sh
make runtime-write DEV=/dev/diskN
```

Keep `secureboot/*.key` private. They are operator keys and are ignored by
git. The files under `secureboot/enrol/` are public enrollment artifacts.

Secure Boot controls firmware admission of the UKI. It is related to,
but separate from, the runtime measurement served by the node.

## Build From Source

The default developer build uses Docker and the host architecture. On
Apple Silicon, that means a native `linux/arm64` build container that
cross-compiles the x86_64 laptop target. The operator-facing Makefile
surface is intentionally small: build or write a signed runtime image,
optionally build the runtime with the measured no-TME flag for test
hardware, build the Secure Boot provisioner, apply WiFi/operator config,
and run QEMU acceptance tests.

Requirements by task on macOS:

```sh
brew install qemu swtpm erlang rebar3 python@3
```

Docker Desktop must be running for the default source-build path and
for ESP-edit helpers such as `operator-config-apply`. QEMU and swtpm are needed
for the acceptance harnesses. Erlang/rebar3/Python are needed by the
attestation dashboard wrapper.

Generate signing keys once, then build with all useful local cores:

```sh
make signing-keys
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make runtime-image
```

The build produces:

```text
build/images/lapee-runtime-tme-signed.img
```

With `TME=0`, the signed output is:

```text
build/images/lapee-runtime-no-tme-signed.img
```

By default the USB image is auto-sized from the generated UKI and the
small files staged into the ESP. It is not fixed at 1 GiB. It still
includes GPT, FAT32 metadata, and a little compatibility margin around
the payload, so it will be larger than `BootX64.efi` itself. Override
with `SIZE_MIB=...` only when you deliberately want a larger image.

For release hashes and reproducibility checks, force the reference
builder:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make runtime-image REFERENCE=1
```

`REFERENCE=1` forces `linux/amd64` Docker for every step. On Apple
Silicon this uses Rosetta.

For hardware that cannot satisfy TME/SME policy, build a signed no-TME
test image:

```sh
make runtime-image TME=0
```

The measured `LAPEE_NO_TME=1` flag is part of that image's node
evidence.

Smoke-test the runtime image in QEMU:

```sh
make qemu TME=0
```

Smoke-test outbound HTTPS relay/oracle behavior, including the target CA
bundle and the node signature on the returned response:

```sh
make qemu-oracle TME=0
```

Run the measurement-backed multi-node acceptance gate:

```sh
make qemu-zone
```

That boots four QEMU+swtpm nodes from the same image. Node 1 initializes
a named zone from its measured system report. Nodes 2 and 3 join
that named zone and install the same zone identity; node 4 carries
a different boot-attested DMI product and must fail admission with
`template-mismatch` and remain outside the zone.

Run the same gate with encrypted non-volatile disks:

```sh
make qemu-zone-nonvolatile
```

That adds a second virtio disk per node, pre-provisioned with the
`ZONE_PRIMARY` GPT partition name. Admitted nodes initialize or open
the disk using the zone secret, mount it as their primary HyperBEAM
store, copy the boot LMDB into it, refresh current-boot pseudo-paths such as
`~measurement@1.0/boot`, then reboot one node with changed boot evidence
to prove the existing encrypted volume is reopened rather than reformatted and
cannot shadow the current boot's measurement.

Run the provisioner storage-selection smoke test:

```sh
make qemu-provisioner-nonvolatile
```

That boots the provisioner image with a sacrificial disk, types the real
`I UNDERSTAND.` and `DESTROY 1 -> test-zone` prompts through QEMU, and
verifies that the extra disk receives a GPT partition named
`ZONE_test-zone` and contains the LapEE provisioning marker. The OVMF
firmware in this test is not expected to complete Secure Boot enrollment; the
test is only asserting the non-volatile disk preparation path.

Run the operator `config.json` attestation gate:

```sh
make qemu-operator-config
```

That boots QEMU+swtpm nodes from signed runtime images and checks that
operator config appears in `/~meta@1.0/info`, boot measurement node
evidence, and PCR15 replay.

Write a freshly built image directly to USB:

```sh
make runtime-write DEV=/dev/diskN
```

`runtime-write` rebuilds and signs the runtime image before writing. To
write an existing pre-built image without rebuilding, use
`make write-image DEV=/dev/diskN IMAGE=build/images/lapee-usb.img`.

## What Gets Built

The image contains:

- Linux 6.19.12 with EFI stub, TPM, lockdown, WiFi, framebuffer, and
  common laptop networking support.
- A Buildroot-generated initramfs with busybox, glibc, Erlang/OTP 27,
  OpenSSL, libtss2, wpa_supplicant, iproute2, iw, zstd, cryptsetup,
  e2fsprogs, parted, and HyperBEAM.
- A custom Buildroot `hyperbeam` package that fetches pinned upstream
  HyperBEAM `edge`, builds stock HyperBEAM, packages LapEE-owned
  measurement, TPM, SNP, zone, and system devices from
  `hyperbeam-devices/` with the HyperBEAM Forge, and bakes them into the
  preloaded device store.
- A UEFI Unified Kernel Image placed at `\EFI\Boot\BootX64.efi` on a
  single FAT32 ESP.

If a disk was provisioned with a `ZONE_<ring-address-prefix>` partition,
the runtime tries that partition first after joining the matching zone.
If no zone-specific partition exists, it falls back to `ZONE_PRIMARY`.
Fresh partitions are formatted as LUKS2 plus ext4 with a key derived from the
zone name, ring address, and zone secret, and the fresh-format path requires
the LapEE provisioning marker written by the provisioner. Existing encrypted
volumes are opened and mounted; normal runtime activation never reformats an
existing LUKS volume. Because the disk key is derived from the zone
secret, a rebooted node must be able to rejoin a live holder of that same zone
secret before it can reopen the store.

Before an opened non-volatile LMDB becomes the first HyperBEAM store, LapEE
rewrites current-boot pseudo-paths such as `~measurement@1.0/boot` into that
store from the fresh volatile cache. Activation fails closed if those links
cannot be refreshed, so stale persistent boot evidence cannot shadow the current
boot after a zone is joined.

The build uses a Buildroot-built target toolchain
(`BR2_TOOLCHAIN_BUILDROOT=y`). On a fresh build, gcc, binutils, glibc,
the kernel, target userspace, and HyperBEAM are compiled from source.

The remaining prebuilt bytes in the shipped boot path are explicit: the
x64 UEFI stub from Debian's `systemd-boot-efi` package, used to wrap the
kernel/initramfs as a UKI, and vendor firmware blobs for WiFi and common
USB/Ethernet adapters. The target Linux userspace and HyperBEAM release
are built from source.

## Troubleshooting

- QEMU passes but laptop WiFi does not: recreate `wifi.conf` with
  `make wifi-creds`, re-apply it with
  `make operator-config-apply IMAGE=build/images/lapee-usb.img`, and
  confirm the laptop's wireless hardware is covered by the release
  firmware set.
- `~measurement@1.0/boot` fails: inspect `~measurement@1.0/info` and
  `~system@1.0/all` to confirm backend selection and hardware discovery, then
  check quote/key policy, EK material, and verifier policy.
- Use `~measurement@1.0/boot` for live measurement inspection. The old
  TPM interpretation helper is not part of the v1 runtime surface.
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
- `hyperbeam-devices/` - LapEE-owned HyperBEAM device package: AO-Core
  device modules, Forge libraries, native TPM/SNP helpers, and measured
  TPM EK roots baked into the preloaded device store.
- `scripts/` - image assembly, QEMU boot and zone flows, WiFi and
  Secure Boot helpers.
- `paper/` - research paper and design notes.

`build/`, `wifi.conf`, `config.json`, and `secureboot/` are
local/operator artefacts and are intentionally ignored by git. `build/`
contains generated images, initramfses, QEMU scratch state, splash
captures, the local HyperBEAM verifier checkout, and attestation
dashboards.
