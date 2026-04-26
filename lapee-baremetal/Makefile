# LapEE bare-metal — build orchestration.
#
# Goal: one UEFI-bootable USB image that boots a real laptop
# (Framework 13 validated; other UEFI+TPM2 machines expected to
# work) and serves a TPM-attested HyperBEAM node.
#
# Toolchain story: Bootlin's pre-built x86_64 musl stable
# cross-toolchain is fetched automatically by Buildroot on first
# `make kernel'. Three thin Docker images wrap it (Linux/amd64;
# native on x86_64 hosts, Rosetta on Apple Silicon). All Docker
# bases are pinned by digest -- no floating tags.
#
# ============================================================
# Usage (each step caches results from the last).
#
#   make toolchain      one-time: pulls the pinned upstream
#                       Docker bases (debian:12-slim, erlang:27)
#                       and builds three thin images on top of
#                       them. ~3 min cold.
#
#   make hb-fetch       one-time: clones HyperBEAM at HB_COMMIT
#                       into build-hyperbeam/src-edge/. Override
#                       with HB_REPO=... HB_COMMIT=... or set
#                       HB_SRC=path/to/local/checkout to copy a
#                       sibling tree instead of cloning.
#
#   make kernel         build the LapEE kernel via Buildroot in a
#                       cached docker volume. ~15-30 min first
#                       time, ~3 min incremental. Artefact:
#                         build-kernel/vmlinuz-lapee
#
#   make hb-release     compile the HyperBEAM release with the
#                       dev_tpm2 NIF. ~3-5 min incremental.
#
#   make hb-initramfs   assemble the guest initramfs (HB release
#                       + busybox + WiFi userspace + lapee init
#                       + the BEAM boot splash). ~30 s.
#                       Artefact: work/initramfs-hb.cpio.gz
#
#   make hb-usb-image   wrap kernel + initramfs + cmdline into
#                       a UEFI-bootable .img (UKI at /EFI/Boot/
#                       BootX64.efi, FAT32 ESP, 1 GB).
#                       Artefact: work/lapee-usb.img
#
#   make hb-usb-write DEV=/dev/diskN
#                       dd the .img to a USB stick. Prompts for
#                       confirmation before writing.
#
# Optional:
#
#   make hb-usb-qemu        smoke-boot the just-built lapee-usb.img
#                           under QEMU + OVMF + swtpm.
#
#   make hb-usb-qemu-gui    same, with a Cocoa window so the
#                           operator can watch the splash.
#
#   make hb-wifi-apply      inject host-side wifi.conf (SSID/PSK,
#                           two lines) into the ESP of the
#                           currently-built work/lapee-usb.img,
#                           without re-signing the UKI.
#
#   make hb-sb-apply        inject the operator's Secure Boot
#                           enrolment bundle (secureboot/enrol/*.
#                           {cer,auth}) into the ESP root of the
#                           current image.
#
#   make clean              remove generated work/ + out/ files.
#                           Kernel artefact is kept; run
#                           buildroot-clean to wipe that.
#
# ============================================================

LAPEE_ROOT := $(shell pwd)
export LAPEE_ROOT

# ----- pinned upstream Docker bases ---------------------------
# Bumping a base = updating one line. Both digests captured on
# 2026-04-26 against amd64 manifests.
ERLANG_BASE := erlang:27.3.4.10@sha256:e4c06a8660e95c807b8f52768a65781fa8efcb74f5e978a8b596938055d8cf7a
DEBIAN_BASE := debian:12-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252
export ERLANG_BASE DEBIAN_BASE

# ----- local image tags ---------------------------------------
# Thin layers on the pinned upstream bases. Built by `make toolchain'.
BUILDER_IMAGE   ?= lapee-builder:local
HB_IMAGE        ?= lapee-hyperbeam-builder:local
TOOLS_IMAGE     ?= lapee-tools:local
export BUILDER_IMAGE HB_IMAGE TOOLS_IMAGE

# ----- host-arch detection ------------------------------------
# Build output is always x86_64 Linux. On non-x86 hosts we run
# the amd64 images via Rosetta / qemu-user; on x86_64 hosts we
# run them natively (skip the --platform flag, save the emulation
# overhead).
HOST_ARCH := $(shell uname -m)
ifeq ($(HOST_ARCH),x86_64)
DOCKER_PLATFORM :=
else
DOCKER_PLATFORM := --platform=linux/amd64
endif
export DOCKER_PLATFORM

# ----- HyperBEAM source provisioning --------------------------
# `make hb-fetch' clones HB at HB_COMMIT into HB_SRC_DIR. Set
# HB_SRC=path to rsync from an existing local checkout instead.
#
# HB_COMMIT pin: a specific 40-char SHA so a fresh build six
# months from now produces the same release as today's. Leaving
# this on a branch ref (e.g. `edge') reintroduces the floating-
# tag class of failure this repo was set up to avoid. Bump the
# pin deliberately; never leave it auto-tracking a branch.
HB_REPO    ?= https://github.com/permaweb/HyperBEAM.git
HB_COMMIT  ?= edge
HB_SRC_DIR  = build-hyperbeam/src-edge
export HB_REPO HB_COMMIT HB_SRC_DIR

.PHONY: help all toolchain builders hb-fetch \
        kernel buildroot buildroot-shell buildroot-clean \
        hb-release hb-initramfs hb-usb-image hb-usb-write \
        hb-usb-qemu hb-usb-qemu-gui hb-wifi-apply hb-sb-apply \
        clean

help:
	@awk '/^# =+$$/{flag=!flag;if(!flag)exit;next} \
	      flag{sub(/^# ?/,"");print}' $(firstword $(MAKEFILE_LIST))

# `make all' walks the full production chain, in the order the
# README documents. Each step caches its result, so re-running is
# fast unless an upstream dependency actually changed.
all: toolchain hb-fetch kernel hb-release hb-initramfs hb-usb-image
	@echo ">> work/lapee-usb.img is the bootable artefact."

# ------------------------------------------------------------
# Toolchain — pulls pinned upstream Docker bases + builds the
# three thin LapEE images on top. One-time; safe to re-run.
# ------------------------------------------------------------

toolchain: builders
	@echo ">> toolchain ready (host=$(HOST_ARCH))"
	@echo "   Bootlin x86_64 musl stable will be fetched by"
	@echo "   Buildroot on first 'make kernel' (~60 MB)."

builders:
	docker pull $(DOCKER_PLATFORM) $(ERLANG_BASE)
	docker pull $(DOCKER_PLATFORM) $(DEBIAN_BASE)
	docker build $(DOCKER_PLATFORM) -t $(BUILDER_IMAGE) \
	    -f docker/Dockerfile.builder       docker/
	docker build $(DOCKER_PLATFORM) -t $(HB_IMAGE) \
	    -f docker/Dockerfile.hyperbeam     docker/
	docker build $(DOCKER_PLATFORM) -t $(TOOLS_IMAGE) \
	    -f docker/Dockerfile.tools         docker/

# ------------------------------------------------------------
# HyperBEAM source provisioning. Clones HB at the pinned commit
# unless HB_SRC=path/to/local is set, in which case rsync from
# that path. Idempotent — skips if HB_SRC_DIR is already a clone.
# ------------------------------------------------------------

hb-fetch:
	./scripts/fetch-hyperbeam.sh

# ------------------------------------------------------------
# Kernel build via Buildroot (cached in a Docker volume).
# ------------------------------------------------------------

kernel: buildroot

buildroot:
	./scripts/build-buildroot.sh

buildroot-shell:
	docker run --rm -it $(DOCKER_PLATFORM) \
	  -v lapee-buildroot:/build \
	  -v $(LAPEE_ROOT)/buildroot-external:/src-external:ro \
	  $(BUILDER_IMAGE) bash

buildroot-clean:
	docker run --rm $(DOCKER_PLATFORM) -v lapee-buildroot:/build \
	  $(BUILDER_IMAGE) bash -c "rm -rf /build/out /build/buildroot-external"

# ------------------------------------------------------------
# HyperBEAM release + initramfs + USB image.
# ------------------------------------------------------------

hb-release:
	./scripts/build-hb-release.sh

hb-initramfs:
	./scripts/build-initramfs-hb.sh

# Defaults. Override on the command line for alternate kernels,
# custom cmdlines, image sizes, or output paths.
KERNEL     ?= build-kernel/vmlinuz-lapee
INITRAMFS  ?= work/initramfs-hb.cpio.gz
SIZE_MIB   ?= 1024
OUT        ?= work/lapee-usb.img

# Default cmdline. `console=' ordering matters: the kernel writes
# every console output to ALL `console=' parameters but
# /dev/console resolves to the LAST one — so we put `console=tty0'
# last so init's stdio + the splash + HB log echoes land on the
# laptop screen. Serial still gets the same output for headless
# capture. `loglevel=7' surfaces full kernel debug. `panic=10'
# auto-reboots ten seconds after a kernel panic. `lapee.wifi=
# enabled' is the PUBLIC capability gate measured into PCR 4 via
# the UKI; the PSK never touches the cmdline (read from a
# strictly-validated wifi.conf on the ESP).
CMDLINE    ?= console=ttyS0 console=tty0 earlyprintk=efi,keep keep_bootcon \
              fbcon=nodefer loglevel=7 panic=10 rdinit=/init \
              LAPEE_WRITEBACK=1 lapee.wifi=enabled

hb-usb-image:
	./scripts/build-usb-image.sh \
	    --kernel     "$(KERNEL)" \
	    --initramfs  "$(INITRAMFS)" \
	    --cmdline    "$(CMDLINE)" \
	    --size       "$(SIZE_MIB)" \
	    --image      "$(OUT)"

hb-usb-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-write DEV=/dev/diskN"; exit 1; }
	./scripts/build-usb-image.sh \
	    --kernel     "$(KERNEL)" \
	    --initramfs  "$(INITRAMFS)" \
	    --cmdline    "$(CMDLINE)" \
	    --size       "$(SIZE_MIB)" \
	    --device     "$(DEV)"

# ------------------------------------------------------------
# QEMU smoke-boot of the USB image.
# ------------------------------------------------------------

hb-usb-qemu:
	./scripts/boot-usb-image.sh

# Same boot, Cocoa window so the operator can watch the splash.
hb-usb-qemu-gui:
	./scripts/boot-usb-image.sh --gui

# ------------------------------------------------------------
# Inject host-side wifi.conf into the ESP of the current image.
# Fast: ~5 s. UKI stays the same — only the ESP data changes.
# ------------------------------------------------------------

hb-wifi-apply:
	@test -f wifi.conf || { \
	    echo "wifi.conf missing. Create it with EXACTLY two lines:"; \
	    echo "  <SSID>"; echo "  <PSK>"; \
	    echo "(and nothing else). See README.md."; exit 1; }
	@test -f work/lapee-usb.img || { \
	    echo "work/lapee-usb.img missing. Run: make hb-usb-image"; \
	    exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(TOOLS_IMAGE) \
	    bash -euo pipefail -c '\
	        START=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$2); print \$$2}"); \
	        SECT=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$4); print \$$4}"); \
	        dd if=/w/work/lapee-usb.img of=/tmp/esp.img \
	            bs=512 skip=$$START count=$$SECT status=none; \
	        mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true; \
	        mcopy -i /tmp/esp.img -o /w/wifi.conf ::/EFI/boot/wifi.conf; \
	        dd if=/tmp/esp.img of=/w/work/lapee-usb.img \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none; \
	        echo ">> ESP /EFI/boot/ after apply:"; \
	        mdir -i /tmp/esp.img ::/EFI/boot/ | tail -n +3'
	@echo ">> wifi.conf applied to work/lapee-usb.img"
	@echo "   flash with: make hb-usb-write DEV=/dev/diskN"

# ------------------------------------------------------------
# Inject operator SB enrolment bundle into an already-built
# image, without touching the signed UKI.
# ------------------------------------------------------------

hb-sb-apply:
	@test -d secureboot/enrol || { \
	    echo "secureboot/enrol/ missing. Run: ./scripts/sb-setup.sh enrol"; \
	    exit 1; }
	@test -f work/lapee-usb.img || { \
	    echo "work/lapee-usb.img missing. Run: make hb-usb-image"; \
	    exit 1; }
	@count=0; for f in secureboot/enrol/PK.cer secureboot/enrol/KEK.cer \
	                   secureboot/enrol/db.cer secureboot/enrol/PK.auth \
	                   secureboot/enrol/KEK.auth secureboot/enrol/db.auth; do \
	    test -f "$$f" && count=$$((count + 1)); done; \
	test $$count -gt 0 || { \
	    echo "no .cer / .auth files in secureboot/enrol/"; exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(TOOLS_IMAGE) \
	    bash -euo pipefail -c '\
	        START=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$2); print \$$2}"); \
	        SECT=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$4); print \$$4}"); \
	        dd if=/w/work/lapee-usb.img of=/tmp/esp.img \
	            bs=512 skip=$$START count=$$SECT status=none; \
	        for f in PK.cer KEK.cer db.cer PK.auth KEK.auth db.auth; do \
	            if [[ -f /w/secureboot/enrol/$$f ]]; then \
	                mcopy -i /tmp/esp.img -o \
	                    /w/secureboot/enrol/$$f ::/$$f; \
	            fi; \
	        done; \
	        dd if=/tmp/esp.img of=/w/work/lapee-usb.img \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none; \
	        echo ">> ESP root after apply:"; \
	        mdir -i /tmp/esp.img :: | tail -n +3'
	@echo ">> SB enrolment bundle applied to work/lapee-usb.img"
	@echo "   flash with: make hb-usb-write DEV=/dev/diskN"

# ------------------------------------------------------------
# Cleanup.
# ------------------------------------------------------------

clean:
	rm -rf work/lapee-usb.img work/lapee-usb-last.img \
	       work/initramfs-hb.cpio.gz work/initramfs-hb.cpio.zst \
	       work/usb-build/ out/local-capture/
	@echo "cleaned. Kernel artefact at build-kernel/vmlinuz-lapee preserved;"
	@echo "run 'make buildroot-clean' to wipe that too."
