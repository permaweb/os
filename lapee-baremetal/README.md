# lapee-baremetal

`lapee-baremetal` builds a bootable LapEE USB image. The image turns a
UEFI + TPM 2.0 laptop into a single-purpose HyperBEAM node that serves
a TPM-attested envelope at:

```text
http://<node-ip>:8734/~tpm2@2.0a/attestation
```

The boot screen shows HyperBEAM's greeter, a QR code for the node URL,
and the spinning laptop splash. The verifier consumes the live
attestation endpoint and writes an HTML dashboard.

## What Gets Built

The target is an x86_64 laptop image:

- Linux 6.6.51 with EFI stub, TPM, lockdown, WiFi, framebuffer, and
  common laptop networking support.
- A Buildroot-generated initramfs with busybox, glibc, Erlang/OTP 27,
  OpenSSL, libtss2, wpa_supplicant, iproute2, iw, zstd, and HyperBEAM.
- A custom Buildroot `hyperbeam` package that fetches the pinned
  HyperBEAM source, applies LapEE package patches, builds Erlang code,
  and cross-compiles the TPM NIF against Buildroot's libtss2.
- A UEFI Unified Kernel Image placed at the fallback path
  `\EFI\Boot\BootX64.efi` on a single FAT32 ESP.

The build now uses a Buildroot-built target toolchain
(`BR2_TOOLCHAIN_BUILDROOT=y`). On a fresh build, gcc, binutils, glibc,
the kernel, target userspace, and HyperBEAM are compiled from source.

The remaining prebuilt bytes in the shipped boot path are explicit:
the x64 UEFI stub from Debian's `systemd-boot-efi` package, used to
wrap the kernel/initramfs as a UKI, and vendor firmware blobs for WiFi
and common USB/Ethernet adapters. The target Linux userspace and
HyperBEAM release are built from source.

## Requirements

On macOS:

```sh
brew install qemu swtpm erlang rebar3 python@3
```

Docker Desktop must be running for the default build path. QEMU and
swtpm are only required for `make hb-usb-qemu`; Erlang/rebar3/Python
are required by the local attestation dashboard wrapper.

On Linux, Docker works the same way. `make native-build` skips Docker
and runs Buildroot directly; install the commands listed by
`make native-build` if anything is missing.

The target laptop needs UEFI boot and TPM 2.0. Framework 13 is the
primary tested machine.

## Build An Image

Default fast build:

```sh
cd /path/to/lapee/lapee-baremetal
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build
```

The default build lets Docker use the host architecture. On Apple
Silicon this is a native `linux/arm64` build container that
cross-compiles the x86_64 laptop target. This is the normal developer
path.

Reference build:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make build REFERENCE=1
```

`REFERENCE=1` forces `linux/amd64` Docker for every step. On Apple
Silicon this uses Rosetta. Use it for publishable hashes and CI-style
reproducibility checks.

Linux native build:

```sh
make native-build
```

That path runs Buildroot directly on a Linux host without Docker.

Useful incremental targets:

```sh
make toolchain       # build the local Docker build image
make kernel          # Buildroot kernel + initramfs + HyperBEAM package
make hb-usb-image    # wrap kernel/initramfs into work/lapee-usb.img
make hb-usb-qemu     # headless QEMU+OVMF+swtpm boot and attestation fetch
make hb-usb-qemu-gui # open QEMU's framebuffer window
```

## WiFi Credentials

For real laptop WiFi, create `wifi.conf` in this directory:

```text
SSID
PASSWORD
```

Two lines only. The helper prompts safely and validates the file:

```sh
make gather-wifi-creds
```

`make hb-usb-write` runs the same helper automatically if `wifi.conf`
is missing and `WIFI` is not `0`.

To build a wired/no-credentials image:

```sh
make hb-usb-image WIFI=0
```

## Write A USB Stick

On macOS:

```sh
diskutil list
make hb-usb-write DEV=/dev/diskN
```

Use the whole disk, not a partition. The write rule confirms the
target, unmounts it, writes via the raw device, and ejects it.

For a measured debug-console image:

```sh
make hb-usb-debug-write DEV=/dev/diskN
```

Debug mode adds `lapee.debug=1` to the measured kernel command line,
disables the splash, and prints hardware, network, DHCP, WiFi, and
HyperBEAM startup stages on the laptop display.

## Run On A Laptop

1. Insert the USB stick.
2. Boot the firmware menu and choose the USB device.
3. Wait for the blue LapEE splash to reach `Running at http://...`.
4. Scan the QR code or open the displayed node URL.

The node listens on port `8734`. Useful endpoints:

```text
/~tpm2@2.0a/info
/~tpm2@2.0a/pcr-read&pcr=0
/~tpm2@2.0a/attestation
```

The splash status line moves through network and HyperBEAM startup
states. If it reaches HyperBEAM but no network address appears, write
the debug image and inspect the visible DHCP/WiFi stages.

## Verify A Live Machine

The dashboard wrapper needs a local HyperBEAM source checkout for the
`~tpm-interpret@1.0` parser. Populate it once:

```sh
make hb-fetch
```

Then fetch and interpret the live attestation envelope:

```sh
./scripts/interpret-local-capture.sh \
  --url http://<node-ip>:8734 \
  --label "Framework 13"
```

The script writes:

```text
build-hyperbeam/src-edge/out/local-capture/<label-slug>/dashboard.html
```

and opens it in the browser. Prefer `--url` for live machines; it
captures the full network attestation envelope with a fresh timestamp
instead of parsing an old local file.

To inspect the current QEMU test envelope:

```sh
./scripts/interpret-local-capture.sh \
  --label "QEMU USB image self-test" \
  out/qemu-network-test/attestation.json
```

## What The Attestation Proves

The envelope and dashboard cover:

- EK certificate material from TPM NV storage when provisioned.
- TPM manufacturer, vendor string, spec version, and firmware version
  from `TPM2_GetCapability`.
- AK public key and TPM quote over the selected PCRs.
- Quote signature, nonce, PCR digest, and PCR value consistency.
- Runtime PCR-15 event replay for the HyperBEAM node identity.
- Firmware TCG event log presence and replay where firmware exposes it.
- Platform probes for CPU, DMI, Secure Boot state, lockdown, IOMMU, TME,
  TPM class, and kernel command line.

The verifier reports critical failures, warnings, and informational
findings separately. For example, Secure Boot off is a policy warning;
an invalid quote signature or missing required TPM proof is critical.

## Runtime Storage Posture

The USB stick is not a writeback store. Init mounts the ESP read-only
long enough to read optional `wifi.conf`, unmounts it, and then detaches
the parent block device before network and HyperBEAM startup. Production
verification is over the network attestation endpoint.

This is intentional: if HyperBEAM were compromised at runtime, it
should not inherit a writable USB path for exfiltrating keys or logs.

## Secure Boot

The default image is an unsigned UKI. It boots with Secure Boot
disabled, and it can also boot on firmware where you explicitly trust
the produced UKI hash.

For operator-owned Secure Boot keys:

```sh
./scripts/sb-setup.sh keys
./scripts/sb-setup.sh enrol
./scripts/sb-setup.sh sign
make hb-sb-apply
make hb-usb-write DEV=/dev/diskN
```

Framework firmware requires a supervisor password before the Secure
Boot controls appear. Enroll `db`, then `KEK`, then `PK`; enrolling
`PK` exits setup mode.

Secure Boot controls firmware admission of the UKI. It is separate
from the runtime TPM quote, which is what `/~tpm2@2.0a/attestation`
serves to verifiers.

## Troubleshooting

- `make hb-usb-qemu` passes but laptop WiFi does not: use
  `make hb-usb-debug-write DEV=/dev/diskN` and inspect the visible
  `wlan0`, `wpa_supplicant`, and `udhcpc` stages.
- `/attestation` fails but `/pcr-read&pcr=0` works: the TPM is alive;
  the failure is likely in quote/key policy, EK material, or verifier
  policy, not basic TPM discovery.
- `interpret-local-capture.sh` says no HyperBEAM checkout: run
  `make hb-fetch`, or set `REPO=/path/to/hyperbeam`.
- macOS asks for a password while writing: the write path uses `sudo dd`
  against `/dev/rdiskN`.

## Important Paths

```text
Makefile
docker/Dockerfile
buildroot-external/configs/lapee_defconfig
buildroot-external/package/hyperbeam/
buildroot-external/board/lapee/rootfs-overlay/init
buildroot-external/board/lapee/files/lapee_splash.erl
scripts/build-buildroot.sh
scripts/build-usb-image.sh
scripts/boot-usb-image.sh
scripts/interpret-local-capture.sh
secondary-external-verifier/verifier_hb.py
```
