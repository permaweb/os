# LapEE bare-metal — build orchestration.
#
# Goal: one UEFI-bootable USB image that boots a real laptop and
# serves a TPM-attested HyperBEAM node. Buildroot bootstraps gcc /
# glibc / binutils, then cross-compiles the kernel, target
# userspace, and the LapEE custom HyperBEAM package. The UKI uses
# Debian's x64 systemd EFI stub, and vendor firmware blobs remain
# prebuilt where no source release exists.
#
# ============================================================
# Three execution paths:
#
#   make build              — default. Per-step Docker containers
#                             at host arch (linux/arm64 on Apple
#                             Silicon, linux/amd64 on x86_64
#                             hosts). Fast on every host. Bytes
#                             not guaranteed reproducible across
#                             host architectures.
#
#   make build REFERENCE=1  — reference / publishable build.
#                             Forces linux/amd64 in every Docker
#                             invocation regardless of host. On
#                             Apple Silicon this means Rosetta —
#                             slower but bit-identical output on
#                             every host. CI / publishing uses
#                             this path; the SHA-256 hashes
#                             documented in README.md are produced
#                             by it.
#
#   make native-build       — Linux only. Skips Docker entirely.
#                             Buildroot bootstrap + build runs
#                             directly on the host. Errors clearly
#                             on macOS (Buildroot doesn't run on
#                             non-Linux hosts).
#
# Other targets:
#
#   make help               — print this list.
#   make toolchain          — pull the pinned upstream Debian base
#                             + build the lapee-build image for
#                             the selected mode.
#   make hb-usb-write DEV=  — flash build/images/lapee-usb.img to a USB.
#   make hb-image-write DEV=
#                           — flash an existing build/images/lapee-usb.img
#                             without rebuilding it first.
#   make hb-usb-debug-write DEV=
#                           — flash a measured debug-console image
#                             with lapee.debug=1 on the cmdline.
#   make hb-usb-no-tme-write DEV=
#                           — flash a production image with
#                             LAPEE_NO_TME=1 on the cmdline.
#   make hb-usb-no-tme-debug-write DEV=
#                           — flash a debug-console image with
#                             LAPEE_NO_TME=1 on the cmdline.
#   make hb-usb-no-tme-signed-write DEV=
#                           — flash a no-TME image signed by the
#                             operator Secure Boot db key.
#   make hb-sb-provisioner-write DEV=
#                           — flash a one-shot Setup Mode key
#                             enrollment image for firmware with no
#                             Secure Boot enrollment UI.
#   make hb-usb-no-tme-verify DEV=
#                           — byte-compare the no-TME image against
#                             the beginning of the USB device.
#   make gather-wifi-creds  — prompt locally for wifi.conf.
#   make hb-usb-qemu        — boot build/images/lapee-usb.img under
#                             QEMU+OVMF+swtpm and fetch attestation
#                             over the forwarded network port.
#   make hb-usb-qemu-gui    — same with a Cocoa window so the
#                             operator can watch the splash.
#   make hb-fetch           — populate build/hyperbeam/src-edge
#                             with the pinned verifier source.
#   make hb-wifi-apply      — inject host-side wifi.conf into the
#                             ESP without re-signing.
#   make hb-sb-apply        — inject Secure Boot enrolment bundle.
#   make paper              — build the paper PDF.
#   make buildroot-shell    — drop into the Buildroot volume in a
#                             shell, for debugging.
#   make buildroot-clean    — wipe the Buildroot volume entirely.
#   make clean              — remove generated build/ files only.
#
# ============================================================

LAPEE_ROOT := $(shell pwd)
export LAPEE_ROOT

HOST_ARCH := $(shell uname -m)
HOST_OS   := $(shell uname -s)
HOME_DIR  := $(shell printf '%s' "$$HOME")

# ----- pinned upstream Docker base ----------------------------
# Bumping = update this line. Same digest in docker/Dockerfile.
DEBIAN_BASE := debian:12-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252
export DEBIAN_BASE

# ----- mode-dependent platform + image tag --------------------
# REFERENCE=1 forces linux/amd64 everywhere. Otherwise we leave
# --platform unset so Docker pulls the host's native arch.
ifeq ($(REFERENCE),1)
DOCKER_PLATFORM := --platform=linux/amd64
BUILD_IMAGE     ?= lapee-build:amd64
BUILD_MODE      := reference
else
DOCKER_PLATFORM :=
BUILD_IMAGE     ?= lapee-build:local
BUILD_MODE      := fast
endif
export DOCKER_PLATFORM BUILD_IMAGE BUILD_MODE

# ----- artefact paths -----------------------------------------
BUILD_DIR ?= build
LAPEE_BUILD_DIR := $(abspath $(BUILD_DIR))
export LAPEE_BUILD_DIR
KERNEL    ?= $(BUILD_DIR)/kernel/vmlinuz-lapee
INITRAMFS ?= $(BUILD_DIR)/initramfs/initramfs-lapee.cpio.zst
SIZE_MIB  ?= auto
OUT       ?= $(BUILD_DIR)/images/lapee-usb.img
WIFI      ?= 1
SPLASH    ?= blue
DEBUG     ?= 0
BUILDROOT_VOLUME ?= lapee-buildroot
KERNEL_EXTRA_FRAGMENT ?=
DEFCONFIG_EXTRA_SNIPPET ?=
LENOVO_INTEL_BUILD_DIR ?= build/intel-gfx
LENOVO_INTEL_OUT = build/images/lapee-usb-lenovo-intel-debug.img
LENOVO_INTEL_KERNEL = $(LENOVO_INTEL_BUILD_DIR)/kernel/vmlinuz-lapee
LENOVO_INTEL_INITRAMFS = $(LENOVO_INTEL_BUILD_DIR)/initramfs/initramfs-lapee.cpio.zst
LENOVO_INTEL_CMDLINE = $(DEBUG_CMDLINE) LAPEE_NO_TME=1 i915.force_probe=*
NO_TME_OUT = $(BUILD_DIR)/images/lapee-usb-no-tme.img
NO_TME_CMDLINE = $(PROD_CMDLINE) LAPEE_NO_TME=1
NO_TME_DEBUG_OUT = $(BUILD_DIR)/images/lapee-usb-wifi-debug-no-tme.img
NO_TME_DEBUG_CMDLINE = $(DEBUG_CMDLINE) LAPEE_NO_TME=1
NO_TME_SIGNED_OUT = $(BUILD_DIR)/images/lapee-usb-no-tme-signed.img
NO_TME_SIGNED_UKI = $(BUILD_DIR)/images/lapee-no-tme.signed.efi
SB_PROVISION_BUILD_DIR ?= build/sb-provisioner
SB_PROVISION_OUT = $(BUILD_DIR)/images/lapee-sb-provisioner.img
SB_PROVISION_KERNEL = $(SB_PROVISION_BUILD_DIR)/kernel/vmlinuz-lapee
SB_PROVISION_INITRAMFS = $(SB_PROVISION_BUILD_DIR)/initramfs/initramfs-lapee.cpio.zst
SB_PROVISION_CMDLINE = console=ttyS0 console=tty0 fbcon=nodefer \
                       loglevel=7 panic=10 rdinit=/init \
                       lapee.mode=sb-provision
HYPERBEAM_REPO ?= https://github.com/permaweb/hyperbeam
HYPERBEAM_VERSION ?= $(shell awk -F'\\?= ' '/^HYPERBEAM_VERSION/ {print $$2; exit}' buildroot-external/package/hyperbeam/hyperbeam.mk)
HYPERBEAM_SRC ?= $(BUILD_DIR)/hyperbeam/src-edge
HYPERBEAM_ALLOW_CLEAN ?= 0
LAPEE_HB_OVERLAY_DIR ?= $(LAPEE_ROOT)/hyperbeam-overlay
PROD_CMDLINE  = console=tty0 quiet loglevel=0 vt.global_cursor_default=0 \
                rdinit=/init lapee.mode=prod lapee.wifi=enabled \
                lapee.splash=$(SPLASH)
DEBUG_CMDLINE = console=ttyS0 console=tty0 earlyprintk=efi,keep keep_bootcon \
                fbcon=nodefer loglevel=7 panic=10 rdinit=/init \
                lapee.mode=debug lapee.debug=1 lapee.wifi=enabled \
                lapee.splash=$(SPLASH)

CMDLINE   ?= $(if $(filter 1,$(DEBUG)),$(DEBUG_CMDLINE),$(PROD_CMDLINE))
export BUILDROOT_VOLUME KERNEL_EXTRA_FRAGMENT DEFCONFIG_EXTRA_SNIPPET

.PHONY: help all build native-build toolchain \
        kernel buildroot buildroot-shell buildroot-clean \
        hb-usb-image hb-usb-write hb-image-write hb-usb-debug-image hb-usb-debug-write \
        hb-usb-no-tme-image hb-usb-no-tme-write hb-usb-no-tme-verify \
        hb-usb-no-tme-debug-image hb-usb-no-tme-debug-write hb-usb-no-tme-debug-verify \
        hb-usb-no-tme-signed-image hb-usb-no-tme-signed-write \
        hb-sb-keys hb-sb-provisioner-image hb-sb-provisioner-write \
        hb-usb-lenovo-intel-debug-image hb-usb-lenovo-intel-debug-write \
        hb-usb-qemu hb-usb-qemu-gui hb-fetch gather-wifi-creds hb-wifi-apply hb-sb-apply \
        paper clean

help:
	@awk '/^# =+$$/{flag=!flag;if(!flag)exit;next} \
	      flag{sub(/^# ?/,"");print}' $(firstword $(MAKEFILE_LIST))

# ------------------------------------------------------------
# Top-level build orchestration.
#
# `build' = toolchain (Docker images) + kernel/rootfs (Buildroot
# inside the build image) + USB image (UKI + GPT/ESP, also inside
# the build image). Three steps, all Docker-internal under the
# hood; Buildroot owns the entire userspace including HyperBEAM.
# ------------------------------------------------------------

build: toolchain
	@echo ">> $(BUILD_MODE) build (host=$(HOST_ARCH); REFERENCE=$(if $(filter 1,$(REFERENCE)),1,0))"
	$(MAKE) kernel
	$(MAKE) hb-usb-image
	@echo ">> done. $(OUT) is the bootable artefact."

all: build

paper:
	$(MAKE) -C paper

native-build:
	@if [ "$(HOST_OS)" != "Linux" ]; then \
	    echo "native-build requires a Linux host (Buildroot doesn't run on $(HOST_OS))." >&2; \
	    echo "Use 'make build' instead." >&2; \
	    exit 1; \
	fi
	@$(MAKE) _check-native-deps
	NATIVE_BUILD=1 $(MAKE) kernel
	NATIVE_BUILD=1 $(MAKE) hb-usb-image
	@echo ">> done. $(OUT) is the bootable artefact."

# Precondition check for native-build: required host packages
# must be on PATH. Errors with the exact apt-install line if
# anything's missing.
_check-native-deps:
	@missing=""; \
	for cmd in bc bison flex gcc make perl python3 rsync wget cpio xz \
	           parted mtools mkfs.vfat sbsign cargo rustc; do \
	    command -v $$cmd >/dev/null 2>&1 || missing="$$missing $$cmd"; \
	done; \
	if [ -n "$$missing" ]; then \
	    echo "native-build: missing host commands:$$missing" >&2; \
	    echo "On Debian/Ubuntu install:" >&2; \
	    echo "  sudo apt install build-essential bc bison flex libssl-dev libelf-dev libncurses-dev rsync wget cpio xz-utils python3 perl parted mtools dosfstools sbsigntool efitools cargo rustc cmake" >&2; \
	    exit 1; \
	fi

# ------------------------------------------------------------
# Toolchain — pulls pinned upstream base + builds local image.
# ------------------------------------------------------------

toolchain:
	docker pull $(DOCKER_PLATFORM) $(DEBIAN_BASE)
	docker build $(DOCKER_PLATFORM) -t $(BUILD_IMAGE) \
	    -f docker/Dockerfile docker/

# ------------------------------------------------------------
# Kernel + rootfs build via Buildroot.
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
# UKI + USB image assembly.
# ------------------------------------------------------------

hb-usb-image:
	WIFI="$(WIFI)" ./scripts/build-usb-image.sh \
	    --kernel    "$(KERNEL)" \
	    --initramfs "$(INITRAMFS)" \
	    --cmdline   "$(CMDLINE)" \
	    --size      "$(SIZE_MIB)" \
	    --image     "$(OUT)"

hb-usb-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-write DEV=/dev/diskN"; exit 1; }
	@if [ "$(WIFI)" != "0" ]; then \
	    ./scripts/gather-wifi-creds.sh --if-missing; \
	else \
	    echo ">> skipping wifi credential gather (WIFI=0)"; \
	fi
	WIFI="$(WIFI)" ./scripts/build-usb-image.sh \
	    --kernel    "$(KERNEL)" \
	    --initramfs "$(INITRAMFS)" \
	    --cmdline   "$(CMDLINE)" \
	    --size      "$(SIZE_MIB)" \
	    --device    "$(DEV)"

hb-image-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-image-write DEV=/dev/diskN"; exit 1; }
	@test -f "$(OUT)" || { \
	    echo "$(OUT) missing. Put a pre-built image there or run: make build"; \
	    exit 1; }
	@if [ "$(HOST_OS)" = "Darwin" ]; then \
	    case "$(DEV)" in /dev/disk*|/dev/rdisk*) ;; \
	        *) echo "macOS device must be /dev/diskN or /dev/rdiskN" >&2; exit 1;; \
	    esac; \
	    DISKID=$$(basename "$(DEV)" | sed 's/^r//'); \
	    RAW="/dev/r$$DISKID"; \
	    echo ">> target : $(DEV) -> $$RAW"; \
	    diskutil info "/dev/$$DISKID" | \
	        grep -E '(Device.*(Identifier|Node)|Media Name|Disk Size)' | \
	        sed 's/^/     /'; \
	    printf "Write $(OUT) to $$RAW? [type YES] "; \
	    read CONFIRM; [ "$$CONFIRM" = "YES" ] || { echo "aborted"; exit 1; }; \
	    diskutil unmountDisk "/dev/$$DISKID"; \
	    sudo dd if="$(OUT)" of="$$RAW" bs=4m; \
	    diskutil eject "/dev/$$DISKID"; \
	else \
	    [ -b "$(DEV)" ] || { echo "not a block device: $(DEV)" >&2; exit 1; }; \
	    echo ">> target : $(DEV)"; \
	    lsblk -o NAME,SIZE,MODEL "$(DEV)" 2>/dev/null | sed 's/^/     /' || true; \
	    printf "Write $(OUT) to $(DEV)? [type YES] "; \
	    read CONFIRM; [ "$$CONFIRM" = "YES" ] || { echo "aborted"; exit 1; }; \
	    sudo dd if="$(OUT)" of="$(DEV)" bs=4M status=progress conv=fsync; \
	    sync; \
	fi

hb-usb-debug-image:
	$(MAKE) hb-usb-image DEBUG=1 \
	    OUT="$(BUILD_DIR)/images/lapee-usb-debug.img"

hb-usb-debug-write:
	$(MAKE) hb-usb-write DEBUG=1 \
	    OUT="$(BUILD_DIR)/images/lapee-usb-debug.img" DEV="$(DEV)"

hb-usb-no-tme-image:
	$(MAKE) hb-usb-image \
	    CMDLINE='$(NO_TME_CMDLINE)' \
	    OUT="$(NO_TME_OUT)"

hb-usb-no-tme-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-no-tme-write DEV=/dev/diskN"; exit 1; }
	@if [ "$(WIFI)" != "0" ]; then \
	    ./scripts/gather-wifi-creds.sh --if-missing; \
	else \
	    echo ">> skipping wifi credential gather (WIFI=0)"; \
	fi
	$(MAKE) hb-usb-no-tme-image WIFI="$(WIFI)"
	@if [ "$(HOST_OS)" = "Darwin" ]; then \
	    case "$(DEV)" in /dev/disk*|/dev/rdisk*) ;; \
	        *) echo "macOS device must be /dev/diskN or /dev/rdiskN" >&2; exit 1;; \
	    esac; \
	    DISKID=$$(basename "$(DEV)" | sed 's/^r//'); \
	    RAW="/dev/r$$DISKID"; \
	    echo ">> target : $(DEV) -> $$RAW"; \
	    diskutil info "/dev/$$DISKID" | \
	        grep -E '(Device.*(Identifier|Node)|Media Name|Disk Size)' | \
	        sed 's/^/     /'; \
	    printf "Write $(NO_TME_OUT) to $$RAW? [type YES] "; \
	    read CONFIRM; [ "$$CONFIRM" = "YES" ] || { echo "aborted"; exit 1; }; \
	    BYTES=$$(stat -f %z "$(NO_TME_OUT)" 2>/dev/null || stat -c %s "$(NO_TME_OUT)"); \
	    diskutil unmountDisk "/dev/$$DISKID"; \
	    sudo dd if="$(NO_TME_OUT)" of="$$RAW" bs=4m; \
	    sync; \
	    echo ">> verifying first $$BYTES bytes"; \
	    sudo cmp -n "$$BYTES" "$(NO_TME_OUT)" "$$RAW"; \
	    echo ">> no-TME image bytes verified on $(DEV)"; \
	    diskutil eject "/dev/$$DISKID"; \
	else \
	    [ -b "$(DEV)" ] || { echo "not a block device: $(DEV)" >&2; exit 1; }; \
	    echo ">> target : $(DEV)"; \
	    lsblk -o NAME,SIZE,MODEL "$(DEV)" 2>/dev/null | sed 's/^/     /' || true; \
	    printf "Write $(NO_TME_OUT) to $(DEV)? [type YES] "; \
	    read CONFIRM; [ "$$CONFIRM" = "YES" ] || { echo "aborted"; exit 1; }; \
	    BYTES=$$(stat -f %z "$(NO_TME_OUT)" 2>/dev/null || stat -c %s "$(NO_TME_OUT)"); \
	    sudo dd if="$(NO_TME_OUT)" of="$(DEV)" bs=4M status=progress conv=fsync; \
	    sync; \
	    echo ">> verifying first $$BYTES bytes"; \
	    sudo cmp -n "$$BYTES" "$(NO_TME_OUT)" "$(DEV)"; \
	    echo ">> no-TME image bytes verified on $(DEV)"; \
	fi

hb-usb-no-tme-verify:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-no-tme-verify DEV=/dev/diskN"; exit 1; }
	@test -f "$(NO_TME_OUT)" || { \
	    echo "$(NO_TME_OUT) missing. Run: make hb-usb-no-tme-image"; \
	    exit 1; }
	@set -e; \
	BYTES=$$(stat -f %z "$(NO_TME_OUT)" 2>/dev/null || stat -c %s "$(NO_TME_OUT)"); \
	if [ "$(HOST_OS)" = "Darwin" ]; then \
	    DISKID=$$(basename "$(DEV)" | sed 's/^r//'); \
	    RAW="/dev/r$$DISKID"; \
	    echo ">> comparing first $$BYTES bytes of $(NO_TME_OUT) against $$RAW"; \
	    sudo cmp -n "$$BYTES" "$(NO_TME_OUT)" "$$RAW"; \
	else \
	    echo ">> comparing first $$BYTES bytes of $(NO_TME_OUT) against $(DEV)"; \
	    sudo cmp -n "$$BYTES" "$(NO_TME_OUT)" "$(DEV)"; \
	fi; \
	echo ">> no-TME image bytes match $(DEV)"

hb-usb-no-tme-debug-image:
	$(MAKE) hb-usb-no-tme-image \
	    NO_TME_CMDLINE='$(NO_TME_DEBUG_CMDLINE)' \
	    NO_TME_OUT="$(NO_TME_DEBUG_OUT)"

hb-usb-no-tme-debug-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-no-tme-debug-write DEV=/dev/diskN"; exit 1; }
	$(MAKE) hb-usb-no-tme-write DEV="$(DEV)" WIFI="$(WIFI)" \
	    NO_TME_CMDLINE='$(NO_TME_DEBUG_CMDLINE)' \
	    NO_TME_OUT="$(NO_TME_DEBUG_OUT)"

hb-usb-no-tme-debug-verify:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-no-tme-debug-verify DEV=/dev/diskN"; exit 1; }
	$(MAKE) hb-usb-no-tme-verify DEV="$(DEV)" \
	    NO_TME_OUT="$(NO_TME_DEBUG_OUT)"

hb-sb-keys:
	./scripts/sb-setup.sh keys
	./scripts/sb-setup.sh enrol

hb-usb-no-tme-signed-image:
	@test -f secureboot/db.key || { \
	    echo "secureboot/db.key missing. Run: make hb-sb-keys"; exit 1; }
	@test -f secureboot/enrol/db.esl || { \
	    echo "secureboot/enrol/db.esl missing. Run: make hb-sb-keys"; exit 1; }
	$(MAKE) hb-usb-no-tme-image
	BUILD_UKI="$(LAPEE_BUILD_DIR)/usb-build/lapee.efi" \
	SIGNED_UKI="$(abspath $(NO_TME_SIGNED_UKI))" \
	USB_IMAGE="$(abspath $(NO_TME_SIGNED_OUT))" \
	WIFI="$(WIFI)" \
	    ./scripts/sb-setup.sh sign

hb-usb-no-tme-signed-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-no-tme-signed-write DEV=/dev/diskN"; exit 1; }
	@if [ "$(WIFI)" != "0" ]; then \
	    ./scripts/gather-wifi-creds.sh --if-missing; \
	else \
	    echo ">> skipping wifi credential gather (WIFI=0)"; \
	fi
	$(MAKE) hb-usb-no-tme-signed-image WIFI="$(WIFI)"
	$(MAKE) hb-image-write OUT="$(NO_TME_SIGNED_OUT)" DEV="$(DEV)"

hb-sb-provisioner-image: toolchain
	@test -f secureboot/enrol/db.auth || { \
	    echo "secureboot/enrol/db.auth missing. Run: make hb-sb-keys"; exit 1; }
	@test -f secureboot/enrol/KEK.auth || { \
	    echo "secureboot/enrol/KEK.auth missing. Run: make hb-sb-keys"; exit 1; }
	@test -f secureboot/enrol/PK.auth || { \
	    echo "secureboot/enrol/PK.auth missing. Run: make hb-sb-keys"; exit 1; }
	$(MAKE) buildroot \
	    BUILDROOT_VOLUME=lapee-buildroot-sb-provisioner \
	    LAPEE_BUILD_DIR="$(abspath $(SB_PROVISION_BUILD_DIR))" \
	    KERNEL_EXTRA_FRAGMENT="$(LAPEE_ROOT)/buildroot-external/board/lapee/linux-sb-provisioner-fragment.config" \
	    DEFCONFIG_EXTRA_SNIPPET="$(LAPEE_ROOT)/buildroot-external/configs/lapee-sb-provisioner.extra"
	$(MAKE) hb-usb-image WIFI=0 \
	    LAPEE_BUILD_DIR="$(abspath $(SB_PROVISION_BUILD_DIR))" \
	    KERNEL="$(SB_PROVISION_KERNEL)" \
	    INITRAMFS="$(SB_PROVISION_INITRAMFS)" \
	    CMDLINE='$(SB_PROVISION_CMDLINE)' \
	    OUT="$(SB_PROVISION_OUT)"

hb-sb-provisioner-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-sb-provisioner-write DEV=/dev/diskN"; exit 1; }
	$(MAKE) hb-sb-provisioner-image
	$(MAKE) hb-image-write OUT="$(SB_PROVISION_OUT)" DEV="$(DEV)"

hb-usb-lenovo-intel-debug-image:
	$(MAKE) buildroot \
	    BUILDROOT_VOLUME=lapee-buildroot-intel-gfx \
	    LAPEE_BUILD_DIR="$(abspath $(LENOVO_INTEL_BUILD_DIR))" \
	    KERNEL_EXTRA_FRAGMENT="$(LAPEE_ROOT)/buildroot-external/board/lapee/linux-intel-gfx-fragment.config" \
	    DEFCONFIG_EXTRA_SNIPPET="$(LAPEE_ROOT)/buildroot-external/configs/lapee-intel-gfx.extra"
	$(MAKE) hb-usb-image DEBUG=1 \
	    LAPEE_BUILD_DIR="$(abspath $(LENOVO_INTEL_BUILD_DIR))" \
	    KERNEL="$(LENOVO_INTEL_KERNEL)" \
	    INITRAMFS="$(LENOVO_INTEL_INITRAMFS)" \
	    CMDLINE='$(LENOVO_INTEL_CMDLINE)' \
	    OUT="$(LENOVO_INTEL_OUT)"

hb-usb-lenovo-intel-debug-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make hb-usb-lenovo-intel-debug-write DEV=/dev/diskN"; exit 1; }
	$(MAKE) buildroot \
	    BUILDROOT_VOLUME=lapee-buildroot-intel-gfx \
	    LAPEE_BUILD_DIR="$(abspath $(LENOVO_INTEL_BUILD_DIR))" \
	    KERNEL_EXTRA_FRAGMENT="$(LAPEE_ROOT)/buildroot-external/board/lapee/linux-intel-gfx-fragment.config" \
	    DEFCONFIG_EXTRA_SNIPPET="$(LAPEE_ROOT)/buildroot-external/configs/lapee-intel-gfx.extra"
	$(MAKE) hb-usb-write DEBUG=1 DEV="$(DEV)" \
	    LAPEE_BUILD_DIR="$(abspath $(LENOVO_INTEL_BUILD_DIR))" \
	    KERNEL="$(LENOVO_INTEL_KERNEL)" \
	    INITRAMFS="$(LENOVO_INTEL_INITRAMFS)" \
	    CMDLINE='$(LENOVO_INTEL_CMDLINE)' \
	    OUT="$(LENOVO_INTEL_OUT)"

hb-usb-qemu:
	./scripts/boot-usb-image.sh

hb-usb-qemu-gui:
	./scripts/boot-usb-image.sh --gui

hb-fetch:
	@test -n "$(HYPERBEAM_VERSION)" || { \
	    echo "could not read HYPERBEAM_VERSION from buildroot-external/package/hyperbeam/hyperbeam.mk" >&2; \
	    exit 1; }
	@mkdir -p "$(dir $(HYPERBEAM_SRC))"
	@if [ -f "$(HYPERBEAM_SRC)/rebar.config" ]; then \
	    echo ">> HyperBEAM verifier source already present: $(HYPERBEAM_SRC)"; \
	    if [ "$(HYPERBEAM_SRC)" = "$(BUILD_DIR)/hyperbeam/src-edge" ] || \
	       [ "$(HYPERBEAM_ALLOW_CLEAN)" = "1" ]; then \
	        git -C "$(HYPERBEAM_SRC)" reset --hard; \
	        git -C "$(HYPERBEAM_SRC)" clean -fdx; \
	    elif [ -n "$$(git -C "$(HYPERBEAM_SRC)" status --porcelain)" ]; then \
	        echo "refusing to clean dirty HYPERBEAM_SRC outside $(BUILD_DIR); set HYPERBEAM_ALLOW_CLEAN=1 if this checkout is disposable" >&2; \
	        exit 1; \
	    fi; \
	    git -C "$(HYPERBEAM_SRC)" fetch origin edge; \
	    git -C "$(HYPERBEAM_SRC)" checkout --detach "$(HYPERBEAM_VERSION)"; \
	elif [ -d "$(HOME_DIR)/src/hyperbeam/.git" ] && \
	     git -C "$(HOME_DIR)/src/hyperbeam" cat-file -e "$(HYPERBEAM_VERSION)^{commit}" 2>/dev/null; then \
	    echo ">> creating verifier worktree from $(HOME_DIR)/src/hyperbeam"; \
	    git -C "$(HOME_DIR)/src/hyperbeam" worktree add --detach \
	        "$(abspath $(HYPERBEAM_SRC))" "$(HYPERBEAM_VERSION)"; \
	else \
	    echo ">> cloning verifier source from $(HYPERBEAM_REPO)"; \
	    git clone "$(HYPERBEAM_REPO)" "$(HYPERBEAM_SRC)"; \
	    git -C "$(HYPERBEAM_SRC)" checkout --detach "$(HYPERBEAM_VERSION)"; \
	fi
	@LAPEE_HB_OVERLAY_DIR="$(LAPEE_HB_OVERLAY_DIR)" \
	    ./scripts/stage-hyperbeam-overlay.sh "$(HYPERBEAM_SRC)"

# ------------------------------------------------------------
# ESP injection helpers (operator-side, no UKI re-sign).
# ------------------------------------------------------------

gather-wifi-creds:
	./scripts/gather-wifi-creds.sh --force

hb-wifi-apply: toolchain
	@test -f wifi.conf || { \
	    echo "wifi.conf missing. Create it with EXACTLY two lines:"; \
	    echo "  <SSID>"; echo "  <PSK>"; \
	    echo "(and nothing else). See README.md."; exit 1; }
	@test -f "$(OUT)" || { \
	    echo "$(OUT) missing. Run: make build"; \
	    exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(BUILD_IMAGE) \
	    bash -euo pipefail -c '\
	        START=$$(parted --script --machine /w/$(OUT) \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$2); print \$$2}"); \
	        SECT=$$(parted --script --machine /w/$(OUT) \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$4); print \$$4}"); \
	        dd if=/w/$(OUT) of=/tmp/esp.img \
	            bs=512 skip=$$START count=$$SECT status=none; \
	        mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true; \
	        mcopy -i /tmp/esp.img -o /w/wifi.conf ::/EFI/boot/wifi.conf; \
	        dd if=/tmp/esp.img of=/w/$(OUT) \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none'
	@echo ">> wifi.conf applied to $(OUT)"

hb-sb-apply: toolchain
	@test -d secureboot/enrol || { \
	    echo "secureboot/enrol/ missing. Run: ./scripts/sb-setup.sh enrol"; \
	    exit 1; }
	@test -f "$(OUT)" || { \
	    echo "$(OUT) missing. Run: make build"; \
	    exit 1; }
	docker run --rm $(DOCKER_PLATFORM) \
	    -v $(LAPEE_ROOT):/w -w /w $(BUILD_IMAGE) \
	    bash -euo pipefail -c '\
	        START=$$(parted --script --machine /w/$(OUT) \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$2); print \$$2}"); \
	        SECT=$$(parted --script --machine /w/$(OUT) \
	            unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$$4); print \$$4}"); \
	        dd if=/w/$(OUT) of=/tmp/esp.img \
	            bs=512 skip=$$START count=$$SECT status=none; \
	        for f in PK.cer KEK.cer db.cer PK.auth KEK.auth db.auth PK.esl KEK.esl db.esl; do \
	            if [[ -f /w/secureboot/enrol/$$f ]]; then \
	                mcopy -i /tmp/esp.img -o /w/secureboot/enrol/$$f ::/$$f; \
	            fi; \
	        done; \
	        dd if=/tmp/esp.img of=/w/$(OUT) \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none'
	@echo ">> SB enrolment bundle applied to $(OUT)"

# ------------------------------------------------------------
# Cleanup.
# ------------------------------------------------------------

clean:
	rm -rf $(BUILD_DIR)/images $(BUILD_DIR)/initramfs $(BUILD_DIR)/kernel \
	       $(BUILD_DIR)/usb-build $(BUILD_DIR)/qemu-usb $(BUILD_DIR)/tpm-qemu \
	       $(BUILD_DIR)/qemu-network-test $(BUILD_DIR)/splash-previews \
	       $(BUILD_DIR)/splash-captures $(BUILD_DIR)/qemu-splash-capture
	-$(MAKE) -C paper clean
	@echo "cleaned. HyperBEAM checkout and Buildroot volume preserved (run 'make buildroot-clean' to wipe Buildroot)."
