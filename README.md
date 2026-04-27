# LapEE

**LapEE** (Laptop Execution Environment) is an attested-appliance
reference implementation for HyperBEAM. You write one ~1 GB image
to a USB stick, plug the stick into a commodity TPM2 laptop, and
the laptop boots as a measured + signed HyperBEAM node: the TPM
endorses its own identity in silicon, the firmware event log
records every measurement from UEFI handoff through UKI load, and
HyperBEAM emerges as PID 2 serving a TPM-quoted attestation
envelope at `/~tpm2@2.0a/attestation`. A verifier parses the
envelope into an auditable dashboard. Zero synthesised values
anywhere in the runtime path — every field comes from a live
hardware signal or is recorded as explicitly absent.

This repo is two pieces:

- **`lapee-paper/`** — the paper plus companion design notes:
  - [`main.tex`](lapee-paper/main.tex) — spec + threat model +
    architecture + worked example.
  - [`beam-tagged-mac.tex`](lapee-paper/beam-tagged-mac.tex) —
    design note for the next-generation TME-replay defence
    (tagged-pointer MACs in BEAM). Future work; documented now
    so the design isn't lost.
- **`lapee-baremetal/`** — the appliance build. Kernel,
  HyperBEAM release, init, splash, USB image, and the offline
  verifier. Quick start in
  [`lapee-baremetal/README.md`](lapee-baremetal/README.md).

## Build

Three execution paths, two user-facing concepts:

```bash
# Default. Per-step Docker containers at the host's native arch
# (linux/arm64 on Apple Silicon, linux/amd64 on x86 hosts). Fast on
# every host. Output bytes not guaranteed reproducible across hosts.
cd lapee-baremetal && make build

# Reference / publishable build. Forces linux/amd64 in every
# Docker invocation regardless of host (Rosetta on Apple Silicon
# — slower, but bit-identical output on every host). CI uses
# this; the SHA-256 hashes published alongside this README are
# produced by it.
cd lapee-baremetal && make build REFERENCE=1

# Linux only, no Docker. Currently a transitional stub; goes
# functional with the Buildroot-owns-everything migration
# (next phase — see Roadmap below).
cd lapee-baremetal && make native-build
```

## Toolchain

Pinned upstream Docker bases (by SHA-256 digest) wrap a Bootlin
pre-built x86_64 musl cross-toolchain that Buildroot fetches
automatically on first build. The kernel is compiled from
[kernel.org](https://kernel.org/) source; HyperBEAM is built
from `github.com/permaweb/HyperBEAM.git` source. The remaining
upstream binaries in the chain are documented honestly in
[`lapee-baremetal/README.md`](lapee-baremetal/README.md) under
"Where binaries come from"; the Roadmap below is the path to
"every binary in the boot chain is fresh from source".

The previous LapEE generation lost a working build because an
unpinned `erlang:27` floated to a newer glibc than the bundled
erts had linked against. Pinning every base by digest is what
stops that class of failure recurring.

## Address-randomisation hardening

The kernel is built with every address-randomisation knob the
upstream defconfig exposes:

- `RANDOMIZE_BASE` / `RANDOMIZE_MEMORY` — kASLR + heap zone offset
- `RANDOMIZE_KSTACK_OFFSET` — per-syscall kernel-stack offset
- `SHUFFLE_PAGE_ALLOCATOR` — randomise free-list page order so
  freed-and-reallocated pages land at fresh physical addresses
- `INIT_ON_ALLOC_DEFAULT_ON` / `INIT_ON_FREE_DEFAULT_ON` — zero
  on alloc and free, so any DRAM ciphertext captured by an
  attacker decrypts to zeros outside the program's holding window
- `SLAB_FREELIST_HARDENED` / `SLAB_FREELIST_RANDOM`

These are the *built-in* mitigations against the TME-replay
attack model. The first-class defence (BEAM tagged-pointer MACs
that detect replay against the userspace heap graph) is
documented in [`lapee-paper/beam-tagged-mac.tex`](lapee-paper/beam-tagged-mac.tex)
and listed in the Roadmap below.

## Roadmap

Three pieces of substantive work are designed but not yet
implemented in this repo. They land as separate commits.

### 1. Buildroot owns the entire userspace from source

Today, the kernel is from-source via Buildroot, but the BEAM VM
(`beam.smp`), libtss2, OpenSSL, glibc, busybox, and wpa_supplicant
all come from a Debian-bookworm Docker image as upstream binaries.
The plan to close this:

- Switch the toolchain knob from `BR2_TOOLCHAIN_EXTERNAL_BOOTLIN`
  to `BR2_TOOLCHAIN_BUILDROOT=y` + `BR2_TOOLCHAIN_BUILDROOT_GLIBC=y`.
  The cross-compiler itself becomes from-source on every build.
- Add `BR2_PACKAGE_ERLANG=y`, `BR2_PACKAGE_OPENSSL=y`,
  `BR2_PACKAGE_TPM2_TSS=y`, `BR2_PACKAGE_WPA_SUPPLICANT=y`,
  `BR2_PACKAGE_IPROUTE2=y`, `BR2_PACKAGE_LINUX_FIRMWARE=y`.
- Resurrect `buildroot-external/package/hyperbeam/` — a custom
  Buildroot package that pulls HB at a pinned commit and
  cross-compiles the relx release (Erlang code + `lapee_tpm_nif`)
  inside Buildroot, against Buildroot's own OTP and libtss2.
- The `lapee-hyperbeam-builder` Docker image goes away;
  `build-hb-release.sh` / `build-initramfs-hb.sh` /
  `fetch-hyperbeam.sh` go away. The initramfs becomes Buildroot's
  own `rootfs.cpio.zst` directly. Output: identical artefact
  shape (kernel + initramfs + UKI + USB image), every byte from
  source.
- WiFi firmware (Intel iwlwifi, MediaTek MT7922) remains the
  only upstream binary in the chain — vendor-only, no source
  release exists. Their hashes get measured into PCR 9 so a
  verifier can refuse-or-accept against a known-good list.

This is multi-day work — Erlang/OTP cross-compilation has known
rough edges, and the HB Buildroot package will need iteration to
get the relx release to thread the right erts/lib paths.

### 2. Reproducibility wiring

`BR2_REPRODUCIBLE=y` is already on; the missing pieces are:
- A fixed `SOURCE_DATE_EPOCH` (e.g. the LapEE v1.0 release
  timestamp) so timestamps embedded in compiled binaries are
  deterministic.
- A pinned kernel module signing key (currently ephemeral per
  build), so PCR 11 doesn't drift across reproducible builds.

With these, `make build REFERENCE=1` produces bit-identical
`vmlinuz-lapee` + `lapee-usb.img` on any host, and we publish
the expected SHA-256 hashes here. CI asserts them.

### 3. BEAM tagged-pointer MAC defence against TME-replay

Designed in
[`lapee-paper/beam-tagged-mac.tex`](lapee-paper/beam-tagged-mac.tex).
TL;DR: store a per-pointer truncated MAC of the pointed-to bytes
in the unused high bits of every term-bearing pointer; recompute
on dereference; mismatch = replay detected = signed fault
attestation. The graph-rooting argument collapses the
attack surface to process-control-block roots; keeping those
cache-resident closes the residual gap. 2–4 engineer-months for
a production-quality patch, ~3 weeks for a measured prototype.

## Where things came from

The appliance source originates from two HyperBEAM worktrees
(`agent/lapee` and `agent-/sharp-lichterman`), curated to drop
older Docker custom-builder artefacts and dead Buildroot
packages. The HyperBEAM source itself is fetched separately by
`make -C lapee-baremetal hb-fetch` (clones from
`https://github.com/permaweb/HyperBEAM.git`, or rsyncs a local
checkout when `HB_SRC=path` is set).

## Repo conventions

- Operating notes for collaborators (including AI assistants)
  live in [`lapee-baremetal/CLAUDE.md`](lapee-baremetal/CLAUDE.md).
  Two failure modes — reward-hacking and time-anchoring — recur
  on this project; the doc is the antidote.
- `secureboot/` and `wifi.conf` (operator-private) are
  gitignored; never commit them.
- The paper PDF in `lapee-paper/main.pdf` and the design note
  PDF in `lapee-paper/beam-tagged-mac.pdf` are both committed so
  a fresh clone has readable artefacts without a TeX install.
