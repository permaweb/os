# LapEE bare-metal — build orchestration.
#
# Goal: one UEFI-bootable USB image that boots a real laptop and
# serves a TPM-attested HyperBEAM node.
#
# ============================================================
# Three execution paths:
#
#   make build              — default. Per-step Docker containers at
#                             host arch (linux/arm64 on Apple Silicon,
#                             linux/amd64 on x86_64 hosts). Fast on
#                             every host. Bytes are not guaranteed
#                             reproducible across host architectures.
#
#   make build REFERENCE=1  — reference / publishable build. Forces
#                             linux/amd64 in every Docker invocation
#                             regardless of host. On Apple Silicon
#                             this means Rosetta-emulated containers
#                             — slower but bit-identical output on
#                             every host. CI / publishing uses this
#                             path; the SHA-256 hashes documented in
#                             the README are produced by it.
#
#   make native-build       — Linux only, skips Docker entirely. Not
#                             yet wired through every script
#                             (transitional state); errors clearly
#                             when invoked. Will become functional
#                             once the userspace migrates into
#                             Buildroot proper.
#
# Other targets:
#
#   make help               — print this list.
#   make toolchain          — pull pinned upstream bases + build the
#                             lapee-build / lapee-hyperbeam-builder
#                             images for the selected mode.
#   make hb-usb-write DEV=  — flash work/lapee-usb.img to a USB.
#   make hb-usb-qemu        — boot work/lapee-usb.img under
#                             QEMU+OVMF+swtpm (smoke test).
#   make hb-usb-qemu-gui    — same with a Cocoa window so the operator
#                             can watch the splash.
#   make hb-wifi-apply      — inject host-side wifi.conf into the ESP.
#   make hb-sb-apply        — inject Secure Boot enrolment bundle.
#   make hb-fetch           — populate build-hyperbeam/src-edge from a
#                             local HB checkout (HB_SRC=path) or a
#                             pinned origin commit (HB_COMMIT).
#   make clean              — remove generated work/ files.
#
# ============================================================

LAPEE_ROOT := $(shell pwd)
export LAPEE_ROOT

HOST_ARCH := $(shell uname -m)
HOST_OS   := $(shell uname -s)

# ----- pinned upstream Docker bases ---------------------------
# Bumping = update these lines. Both digests captured 2026-04-26.
DEBIAN_BASE := debian:12-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252
ERLANG_BASE := erlang:27.3.4.10@sha256:e4c06a8660e95c807b8f52768a65781fa8efcb74f5e978a8b596938055d8cf7a
export DEBIAN_BASE ERLANG_BASE

# ----- mode-dependent platform + image tags -------------------
# REFERENCE=1 forces linux/amd64 everywhere. Otherwise we leave
# --platform unset so Docker pulls the host's native arch.
ifeq ($(REFERENCE),1)
DOCKER_PLATFORM := --platform=linux/amd64
BUILD_IMAGE     ?= lapee-build:amd64
HB_IMAGE        ?= lapee-hyperbeam-builder:amd64
BUILD_MODE      := reference
else
DOCKER_PLATFORM :=
BUILD_IMAGE     ?= lapee-build:local
HB_IMAGE        ?= lapee-hyperbeam-builder:local
BUILD_MODE      := fast
endif
export DOCKER_PLATFORM BUILD_IMAGE HB_IMAGE BUILD_MODE

# ----- HyperBEAM source provisioning --------------------------
HB_REPO    ?= https://github.com/permaweb/HyperBEAM.git
HB_COMMIT  ?= edge
HB_SRC_DIR  = build-hyperbeam/src-edge
export HB_REPO HB_COMMIT HB_SRC_DIR

# ----- artefact paths -----------------------------------------
KERNEL    ?= build-kernel/vmlinuz-lapee
INITRAMFS ?= work/initramfs-hb.cpio.gz
SIZE_MIB  ?= 1024
OUT       ?= work/lapee-usb.img

CMDLINE   ?= console=ttyS0 console=tty0 earlyprintk=efi,keep keep_bootcon \
             fbcon=nodefer loglevel=7 panic=10 rdinit=/init \
             LAPEE_WRITEBACK=1 lapee.wifi=enabled

.PHONY: help all build native-build toolchain hb-fetch \
        kernel buildroot buildroot-shell buildroot-clean \
        hb-release hb-initramfs hb-usb-image hb-usb-write \
        hb-usb-qemu hb-usb-qemu-gui hb-wifi-apply hb-sb-apply \
        clean

help:
	@awk '/^# =+$$/{flag=!flag;if(!flag)exit;next} \
	      flag{sub(/^# ?/,"");print}' $(firstword $(MAKEFILE_LIST))

# ------------------------------------------------------------
# Top-level build orchestration.
# ------------------------------------------------------------

# `make build' walks the existing 4-step chain. Each step uses
# Docker internally (kernel + image-assembly via $(BUILD_IMAGE);
# HB release + initramfs assembly via $(HB_IMAGE)). Setting
# REFERENCE=1 makes every Docker invocation force linux/amd64
# uniformly; otherwise each container runs at host arch.
build: toolchain hb-fetch
	@echo ">> $(BUILD_MODE) build (host=$(HOST_ARCH); REFERENCE=$(if $(filter 1,$(REFERENCE)),1,0))"
	$(MAKE) kernel
	$(MAKE) hb-release
	$(MAKE) hb-initramfs
	$(MAKE) hb-usb-image
	@echo ">> done. work/lapee-usb.img is the bootable artefact."

# Convenience alias for parity with the top-level Makefile.
all: build

# `make native-build' — placeholder. The migration of all scripts
# to a no-Docker code path lands with the Buildroot-owns-everything
# work; until then, point operators at `make build'.
native-build:
	@if [ "$(HOST_OS)" != "Linux" ]; then \
	    echo "native-build requires a Linux host (Buildroot doesn't run on $(HOST_OS))." >&2; \
	    echo "Use 'make build' instead." >&2; \
	    exit 1; \
	fi
	@echo "native-build is not yet wired through every script in this commit." >&2
	@echo "Currently the scripts (build-buildroot.sh / build-hb-release.sh /" >&2
	@echo "build-initramfs-hb.sh / build-usb-image.sh) all use Docker"        >&2
	@echo "internally. The full no-Docker path lands with the Buildroot-"     >&2
	@echo "owns-everything migration."                                        >&2
	@echo ""                                                                  >&2
	@echo "For now: 'make build' works on Linux too (Docker overhead is"      >&2
	@echo "minimal when the container runs at the host's native arch)."       >&2
	@exit 1

# ------------------------------------------------------------
# Toolchain — pulls pinned upstream bases + builds local images.
# ------------------------------------------------------------

toolchain:
	docker pull $(DOCKER_PLATFORM) $(DEBIAN_BASE)
	docker pull $(DOCKER_PLATFORM) $(ERLANG_BASE)
	docker build $(DOCKER_PLATFORM) -t $(BUILD_IMAGE) \
	    -f docker/Dockerfile docker/
	docker build $(DOCKER_PLATFORM) -t $(HB_IMAGE) \
	    -f docker/Dockerfile.hyperbeam docker/

# ------------------------------------------------------------
# HyperBEAM source fetch.
# ------------------------------------------------------------

hb-fetch:
	./scripts/fetch-hyperbeam.sh

# ------------------------------------------------------------
# Kernel build via Buildroot.
# ------------------------------------------------------------

kernel: buildroot

buildroot:
	./scripts/build-buildroot.sh

buildroot-shell:
	docker run --rm -it $(DOCKER_PLATFORM) \
	    -v lapee-buildroot:/build \
	    -v $(LAPEE_ROOT)/buildroot-external:/src-external:ro \
	    $(BUILD_IMAGE) bash

buildroot-clean:
	docker run --rm $(DOCKER_PLATFORM) -v lapee-buildroot:/build \
	    $(BUILD_IMAGE) bash -c "rm -rf /build/out /build/buildroot-external"

# ------------------------------------------------------------
# HyperBEAM release + initramfs (transitional — to be subsumed
# by Buildroot's own rootfs in the next phase).
# ------------------------------------------------------------

hb-release:
	./scripts/build-hb-release.sh

hb-initramfs:
	./scripts/build-initramfs-hb.sh

# ------------------------------------------------------------
# UKI + USB image assembly.
# ------------------------------------------------------------

hb-usb-image:
	./scripts/build-usb-image.sh \
	    --kernel    "$(KERNEL)" \
	    --initramfs "$(INITRAMFS)" \
	    --cmdline   "$(CMDLINE)" \
	    --size      "$(SIZE_MIB)" \
	    --image     "$(OUT)"

hb-usb-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-write DEV=/dev/diskN"; exit 1; }
	./scripts/build-usb-image.sh \
	    --kernel    "$(KERNEL)" \
	    --initramfs "$(INITRAMFS)" \
	    --cmdline   "$(CMDLINE)" \
	    --size      "$(SIZE_MIB)" \
	    --device    "$(DEV)"

hb-usb-qemu:
	./scripts/boot-usb-image.sh

hb-usb-qemu-gui:
	./scripts/boot-usb-image.sh --gui

# ------------------------------------------------------------
# ESP injection helpers (operator-side, no UKI re-sign).
# ------------------------------------------------------------

hb-wifi-apply:
	@test -f wifi.conf || { \
	    echo "wifi.conf missing. Create it with EXACTLY two lines:"; \
	    echo "  <SSID>"; echo "  <PSK>"; \
	    echo "(and nothing else). See README.md."; exit 1; }
	@test -f work/lapee-usb.img || { \
	    echo "work/lapee-usb.img missing. Run: make build"; \
	    exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(BUILD_IMAGE) \
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
	            conv=notrunc status=none'
	@echo ">> wifi.conf applied to work/lapee-usb.img"

hb-sb-apply:
	@test -d secureboot/enrol || { \
	    echo "secureboot/enrol/ missing. Run: ./scripts/sb-setup.sh enrol"; \
	    exit 1; }
	@test -f work/lapee-usb.img || { \
	    echo "work/lapee-usb.img missing. Run: make build"; \
	    exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(BUILD_IMAGE) \
	    bash -euo pipefail -c '\
	        START=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$2); print \$$2}"); \
	        SECT=$$(parted --script --machine /w/work/lapee-usb.img \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$4); print \$$4}"); \
	        dd if=/w/work/lapee-usb.img of=/tmp/esp.img \
	            bs=512 skip=$$START count=$$SECT status=none; \
	        for f in PK.cer KEK.cer db.cer PK.auth KEK.auth db.auth; do \
	            if [[ -f /w/secureboot/enrol/$$f ]]; then \
	                mcopy -i /tmp/esp.img -o /w/secureboot/enrol/$$f ::/$$f; \
	            fi; \
	        done; \
	        dd if=/tmp/esp.img of=/w/work/lapee-usb.img \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none'
	@echo ">> SB enrolment bundle applied to work/lapee-usb.img"

# ------------------------------------------------------------
# Cleanup.
# ------------------------------------------------------------

clean:
	rm -rf work/lapee-usb.img work/lapee-usb-last.img \
	       work/initramfs-hb.cpio.* work/usb-build/ out/local-capture/
	@echo "cleaned. Buildroot volume preserved (run 'make buildroot-clean' to wipe)."
