# PermawebOS

> **alpha release notice:** PermawebOS is an unaudited alpha release. Use it at
> your own risk. Images, build scripts, devices, support paths, and documented
> behavior may break or change at any time. The maintainers make no warranties
> and accept no responsibility for failures, data loss, security issues, broken
> images, or lack of support. Do not use this release for production workloads,
> secrets, or value you cannot afford to lose.

Pretty good hardware-supported security for HyperBEAM execution on abundant
commodity hardware.

PermawebOS packages the HyperBEAM kernel into deployable operating
environments. HyperBEAM implements AO-Core: a computation protocol in which any
computable value has a unique address, and cryptographically identifiable
parties can attest to the correctness of the values they produce. That
primitive lets users, applications, and other nodes build many kinds of trust in
those identities. PermawebOS does not prescribe one universal hardware trust
story; it exposes measured evidence so callers can decide what they trust.

This repository contains:

- build tools for producing signed PermawebOS images,
- architecture wrappers for Linux laptops/servers, AMD SEV-SNP guests, and
  Android devices,
- common HyperBEAM device packages for measurement, system reporting, zones,
  TPM, SNP, and AndEE verification,
- provisioning and QEMU/remote validation harnesses.

HyperBEAM is the kernel. This repository is the operating-system distribution
around it.

## The Thesis

Hardware security is a spectrum, not a binary.

Decentralized compute systems often talk as if hardware attestation is either
"secure" or "not secure." Real systems have never worked that way. Every
hardware root of trust, secure enclave, cryptographic implementation, firmware
chain, and operating system is safe only within some threat model, until it is
not. The practical question is economic: how hard and expensive is it for a
rational attacker to subvert one node's computation or key material, and how
much could they gain by doing so?

PermawebOS makes that trade-off explicit. Instead of requiring every participant
to own the newest server TEE hardware, it turns several widely available
hardware patterns into verifiable execution environments for AO-Core work:

- current-generation TEEs such as AMD SEV-SNP,
- commodity x86 machines with total memory encryption,
- single-purpose laptop appliances whose RAM is practically difficult to
  interpose, especially LPDDR systems,
- Android devices with Verified Boot and hardware-backed app/key attestation.

None of these are perfect. Many are still useful. By exposing the evidence
clearly, PermawebOS lets zones, applications, and users set their own admission
policies for the value at risk.

## Execution Environments

PermawebOS currently supports these deployment families.

### SNP

The SNP architecture runs the Linux PermawebOS image inside an AMD SEV-SNP
guest. SNP provides hardware-backed guest memory confidentiality and integrity,
including protections against many classes of host memory remapping and replay
attacks inside the SEV-SNP threat model. It is the strongest currently
implemented server/VM environment in this repository and is suitable for
virtualized deployment.

### LapEE With TME

LapEE is the Laptop Execution Environment: a single-purpose Linux appliance
that boots HyperBEAM directly on commodity x86 hardware. On TME-capable
machines, Total Memory Encryption makes off-package DRAM contents encrypted.
TME does not provide the same integrity, replay, or guest/host isolation
properties as SNP, and it is not a safe way to run mutually distrusting host
programs beside HyperBEAM.

PermawebOS makes TME useful by making the machine locally inert. The production
image is not a desktop: it boots, measures itself, starts one HyperBEAM node,
shows an ornamental splash/QR display, and takes no intended local input during
operation. There are no user programs beside HyperBEAM in the protected runtime
space.

### LapEE Without TME

Some useful laptops do not expose TME/SME. For those, PermawebOS can build a
measured no-TME image. This is not equivalent to encrypted memory. Its value is
in combination with physical hardware facts and the single-purpose appliance
model.

The most interesting no-TME class is LPDDR hardware. LPDDR is usually attached
directly on the board and is much harder to interpose than socketed DIMM memory.
The Linux kernel and GPU/memory-controller drivers can expose controller-
observed DRAM type such as LPDDR4/LPDDR5. Zones can require those facts, plus
known models or other system evidence, when they want to admit LPDDR-style
machines. Zone creators should still be explicit: a small number of machines
may report LPDDR-like memory while not meeting the intended physical
inaccessibility bar.

### AndEE

AndEE is the Android Execution Environment. It packages HyperBEAM as an Android
app/runtime and uses Android Verified Boot plus Android Keystore/StrongBox
attestation to produce PermawebOS measurements.

AndEE is a different point on the spectrum. It is software isolation provided
by the Android kernel and app sandbox, rooted in Android's hardware-backed
attestation chain. Breaking it generally means compromising the Android device
or kernel/app isolation model for that phone, not clipping a RAM bus. That is
not the same guarantee as SNP, but it can be appropriate for low-value or
high-replication work.

## Appliance Security

The Linux PermawebOS image is single purpose by design.

In production mode:

- the boot USB is treated as input media, read once, unmounted, and detached
  before HyperBEAM starts;
- keyboard, mouse, touchpad, HID, Bluetooth, sound, USB4/Thunderbolt, SysRq,
  debugfs, `/dev/mem`, kexec, hibernation, and suspend are removed from the
  production kernel/runtime surface where practical;
- HyperBEAM is the only intended userspace service;
- stdin/stdout/stderr are not operator interfaces;
- the local screen is ornament: a QR/address display, not a console.

This matters. TME does not isolate one process from another, and no-TME LPDDR
does not encrypt memory at all. PermawebOS gets useful security out of those
machines by ensuring that there should be no second local program with which an
operator can inspect or tamper with HyperBEAM memory. The remote interface is
the HyperBEAM HTTP API; the local machine is an appliance.

## Measurement

`~measurement@1.0` is the common protocol for hardware-backed measurements.
It builds a subject:

```erlang
#{
    <<"system">> => SystemReport,
    <<"node">> => SignedNodeMessage
}
```

The system report comes from `~system@1.0/all`. The node message comes from
`~meta@1.0/info`. The selected measurement engine then binds that subject to
hardware-rooted evidence:

- `~tpm@2.0a` for TPM-backed LapEE machines,
- `~snp@1.0` for AMD SEV-SNP guests,
- `~andee@1.0` for AndEE Android devices,
- future devices such as TDX by implementing the same engine contract.

The measurement message is signed by the node identity generated inside the
measured environment. A verifier checks the AO-Core message signatures, the
backend evidence, and the relationship between the measurement subject,
firmware/boot state, node configuration, and node address.

The device is policy neutral. It exposes facts: PCRs, Secure Boot state, UKI
identity, kernel command line, TPM/EK/AK evidence, SNP report fields, Android
attestation facts, memory-controller evidence, ACPI summaries, CPU/platform
facts, node config, and the node address. Callers and zones decide which facts
matter.

Live boot measurement:

```text
http://<node-ip>:8734/~measurement@1.0/boot
```

Fresh nonce-bound measurement:

```text
http://<node-ip>:8734/~measurement@1.0/fresh?nonce=<base64url-nonce>
```

## Zones

`~zone@1.0` creates mutually enforced security zones. A zone is a shared
identity and secret held only by nodes whose measurements match one of the
zone's admissible templates.

The admission flow is symmetric in spirit:

1. A candidate asks a current member to join a named zone.
2. Each side verifies the other's measurement through `~measurement@1.0`.
3. The current member checks that the candidate's boot measurement matches the
   zone policy.
4. The candidate checks the member's proof and authorization.
5. The zone secret and wallet are encrypted to the candidate using the
   candidate's measurement backend.
6. The candidate installs the zone identity and can later return a membership
   proof signed by that zone identity.

A recipient of a computation signed by a zone identity does not need to
personally verify every live machine. They know that either the computation was
signed by a node admitted under that zone policy, or the zone's security model
has been breached. This gives AO applications a compact way to depend on
transitive, policy-scoped hardware trust.

## Quick Start

Most operators should start from a signed release image. Building from source
is supported, but the first hardware test is usually: verify, inject operator
files, write, boot.

Run commands from the repository root.

1. Put the image at a local path:

   ```sh
   mkdir -p build/images
   cp /path/to/permawebos-no-tme-signed.img build/images/permawebos-no-tme-signed.img
   ```

2. Verify its supplied hash out of band:

   ```sh
   printf '<expected-sha256>  build/images/permawebos-no-tme-signed.img\n' | shasum -a 256 -c -
   ```

3. Add WiFi and optional public operator config to the ESP:

   ```sh
   make wifi-creds
   make operator-config-apply IMAGE=build/images/permawebos-no-tme-signed.img
   ```

   `wifi.conf` is plaintext. Do not share it. Adding `wifi.conf` or
   `config.json` changes the disk image hash, but not the signed UKI.

4. Write the image to a USB stick. Use the whole removable disk from
   `diskutil list`, not `/dev/disk0` and not a partition such as
   `/dev/diskNs1`:

   ```sh
   diskutil list
   make write-image DEV=/dev/diskN IMAGE=build/images/permawebos-no-tme-signed.img
   ```

5. Boot the machine. When the splash reaches `Running at http://...`, scan the
   QR code or open the shown URL.

## Operator Config

`config.json` is optional public HyperBEAM configuration for the node. The
Linux appliance reads it once from the boot USB ESP, copies it into tmpfs as
`/tmp/config.json`, unmounts and detaches the USB, then starts HyperBEAM with:

```text
HB_CONFIG=/tmp/config.json,/etc/lapee/lapee.json
```

The measured PermawebOS config is last, so enforced measurement devices and
the boot measurement hook remain part of the node. Operator-controlled keys
such as `load-remote-devices` and `trusted-device-signers` are intentionally
not forced by the base config; deployments choose them and that choice appears
in measurement evidence.

Use HyperBEAM/AO-Core key spelling directly:

```json
{
  "zone-allow": 1,
  "load-remote-devices": true,
  "trusted-device-signers": [
    "WjnS-s03HWsDSdMnyTdzB1eHZB2QheUWP_FVRVYxkXk"
  ]
}
```

`zone-allow` controls local zone installation:

- `0` or `false`: disable zone joins.
- `1` or unset: allow exactly one zone during this node run.
- positive integer: allow up to that many zones.
- `true`: allow any number.
- list of zone IDs: allow only those named zones.
- map of `ZONE_ID => PEER_URL`: allow only those zones and auto-join each
  listed peer after the HTTP listener starts.

`zone-init-allow` controls whether the node may create a new zone locally.
It defaults to `true`; set it to `false`/`0` to disable initialization, or to a
list of zone IDs to restrict initialization to named zones.

Auto-join still performs normal peer verification. The joining node must
advertise a reachable `public-url` or `zone-self-url`.

## Secure Boot And Storage Provisioning

Generate operator Secure Boot material once:

```sh
make signing-keys
```

Keep `secureboot/*.key` private. Files under `secureboot/enrol/` are public
enrollment artifacts.

If firmware has a usable enrollment UI, enroll the public `db`, `KEK`, and
`PK` artifacts from `secureboot/enrol/`, or enroll the exact UKI hash. Secure
Boot admission is byte-for-byte specific to `\EFI\Boot\BootX64.efi`.

For firmware that exposes setup mode but not a usable enrollment UI,
PermawebOS builds a signed one-shot provisioner:

```sh
make provisioner-write DEV=/dev/diskN
```

Boot it while firmware is in Secure Boot setup mode. The provisioner shows a
red warning, requires the exact text `I UNDERSTAND.`, enrolls public Secure
Boot material, and can destructively prepare encrypted zone storage.

Storage provisioning prompt:

```text
Type SKIP or DESTROY N[ -> ID].
```

`DESTROY N` creates a `ZONE_PRIMARY` partition for the first joined zone.
`DESTROY N -> PREFIX` creates a `ZONE_PREFIX` partition for a zone whose ring
address starts with `PREFIX`. Runtime activation only formats a fresh
partition when the expected GPT partition name and PermawebOS provisioning
marker are both present. Existing LUKS volumes are opened, not reformatted.

## Build From Source

Requirements on macOS:

```sh
brew install qemu swtpm erlang rebar3 python@3
```

Docker Desktop is required for the default source build path and ESP editing.

Build all release artifacts except selected architectures:

```sh
make all EXCLUDE_ARCH=android,snp
```

Build individual artifacts:

```sh
make tme
make no-tme
make snp
make provisioner
make android
```

Outputs:

```text
build/images/permawebos-tme-signed.img
build/images/permawebos-no-tme-signed.img
build/images/permawebos-snp-signed.img
build/images/lapee-sb-provisioner.img
arch/android/android/app/build/outputs/apk/...
```

The lower-level runtime target remains available:

```sh
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" \
  make runtime-image TME=0
```

`runtime-write` rebuilds before writing:

```sh
make runtime-write DEV=/dev/diskN TME=0
```

To write an existing image without rebuilding:

```sh
make write-image DEV=/dev/diskN IMAGE=build/images/permawebos-no-tme-signed.img
```

## Verification And Tests

Useful live endpoints:

```text
http://<node-ip>:8734/~measurement@1.0/info
http://<node-ip>:8734/~measurement@1.0/boot
http://<node-ip>:8734/~system@1.0/all
http://<node-ip>:8734/~zone@1.0/status
http://<node-ip>:8734/~meta@1.0/info
http://<node-ip>:8734/~hyperbuddy@1.0/index
```

Local checks:

```sh
make verify-config-invariants
make qemu TME=0
make qemu-oracle TME=0
make qemu-zone
make qemu-zone-nonvolatile
make qemu-provisioner-nonvolatile
make qemu-operator-config
```

Remote SNP checks:

```sh
make qemu-measurement-remote TARGET=ssh://hb@dev-1.forward.computer
make qemu-zone-remote-snp TARGET=ssh://hb@dev-1.forward.computer
```

Android/AndEE checks:

```sh
make android
make android-check
```

## What Gets Built

The Linux image contains:

- Linux 6.19.12 with EFI stub, TPM, lockdown, WiFi, framebuffer, common laptop
  networking, and the PermawebOS memory-probe patch;
- a Buildroot initramfs with busybox, glibc, Erlang/OTP, OpenSSL, libtss2,
  wpa_supplicant, iproute2, iw, zstd, cryptsetup, e2fsprogs, parted, and
  HyperBEAM;
- stock pinned HyperBEAM built as the kernel runtime;
- preloaded PermawebOS device packages from `devices/common/`;
- a signed UEFI Unified Kernel Image at `\EFI\Boot\BootX64.efi`.

The Android image contains:

- an Android app/runtime wrapper for HyperBEAM,
- common PermawebOS devices from `devices/common/`,
- AndEE-specific Android store, metadata, and service devices from
  `devices/android/`,
- Android Keystore/StrongBox measurement support.

The remaining prebuilt bytes in the Linux boot path are explicit: Debian's x64
UEFI stub and vendor firmware blobs for WiFi/common USB/Ethernet adapters. The
target userspace and HyperBEAM release are built from source.

## Limitations

Measurement is evidence, not magic. PermawebOS does not prove firmware honest,
does not prove Linux or HyperBEAM bug-free, and does not make every hardware
class equivalent to a full TEE.

TME lacks memory integrity and rollback protection. No-TME LPDDR deployments
depend on the physical difficulty of memory interposition and on the
single-purpose appliance model. AndEE depends on Android's Verified Boot,
Keystore/StrongBox, and app/kernel isolation. SNP depends on AMD SEV-SNP
hardware, firmware, and host configuration.

The point is not perfection. The point is measured, explicit, economically
meaningful security for more hardware than the narrow set traditionally treated
as "TEE capable."

## Repo Layout

- `Makefile` - operator and build entry points.
- `arch/` - architecture packaging for Linux, SNP, TME/no-TME, and AndEE.
- `arch/common/linux/` - shared Buildroot Linux appliance.
- `arch/android/` - AndEE Android app/runtime packaging and emulator harnesses.
- `devices/common/` - shared HyperBEAM device package: measurement, system,
  TPM, SNP, AndEE verification, zones, native helpers, and trust roots.
- `devices/android/` - Android-specific store, metadata, service, and payment
  devices.
- `scripts/` - image assembly, QEMU/remote validation, WiFi, and Secure Boot
  helpers.
- `wiki/` - feature, device, protocol, and test contracts.

`build/`, `wifi.conf`, `config.json`, `secureboot/`, generated images, private
keys, local Android SDK files, and runtime caches are local/operator artifacts
and are intentionally ignored by git.
