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
# Release artifacts:
#
#   make runtime-image      - build a signed runtime disk image.
#                             TME=0 allows no-TME test hardware.
#                             DEBUG=1 enables the measured debug console.
#                             REFERENCE=1 forces the publishable
#                             linux/amd64 Docker path.
#   make runtime-write DEV= - build and write the signed runtime image.
#   make provisioner-image  - build the Secure Boot provisioner image.
#   make provisioner-write DEV=
#                           - build and write the provisioner image.
#
# Operator helpers:
#
#   make signing-keys       - generate operator Secure Boot keys and
#                             enrolment payloads under secureboot/.
#   make write-image DEV= IMAGE=
#                           - write an existing disk image to a device.
#   make wifi-creds         - prompt locally for wifi.conf.
#   make operator-config-apply
#                           - inject wifi.conf and/or config.json into
#                             the selected image without re-signing.
#   make clean              - remove generated build/ files only.
#
# QEMU tests:
#
#   make qemu               - boot the selected image under QEMU+OVMF+swtpm.
#   make qemu-oracle        - boot one node and verify a signed HTTPS relay.
#   make qemu-gui           - boot the selected image with a QEMU window.
#   make qemu-green-zone    - run the four-node green-zone acceptance test.
#   make qemu-green-zone-nonvolatile
#                           - run green-zone plus encrypted storage reuse.
#   make qemu-provisioner-nonvolatile
#                           - test provisioner destructive disk selection.
#   make qemu-operator-config
#                           - run the operator-config attestation test.
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
TME       ?= 1
BUILDROOT_VOLUME ?= lapee-buildroot
KERNEL_EXTRA_FRAGMENT ?=
DEFCONFIG_EXTRA_SNIPPET ?=
SB_PROVISION_BUILD_DIR ?= build/sb-provisioner
SB_PROVISION_BUILDROOT_VOLUME = lapee-buildroot-sb-provisioner
SB_PROVISION_OUT = $(BUILD_DIR)/images/lapee-sb-provisioner.img
SB_PROVISION_UNSIGNED_OUT = $(BUILD_DIR)/images/lapee-sb-provisioner-unsigned.img
SB_PROVISION_SIGNED_UKI = $(BUILD_DIR)/images/lapee-sb-provisioner.signed.efi
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
RUNTIME_TME_TAG = $(if $(filter 0,$(TME)),no-tme,tme)
RUNTIME_DEBUG_TAG = $(if $(filter 1,$(DEBUG)),-debug,)
RUNTIME_CMDLINE = $(if $(filter 1,$(DEBUG)),$(DEBUG_CMDLINE),$(PROD_CMDLINE))$(if $(filter 0,$(TME)), LAPEE_NO_TME=1)
RUNTIME_UNSIGNED_OUT ?= $(BUILD_DIR)/images/lapee-runtime-$(RUNTIME_TME_TAG)$(RUNTIME_DEBUG_TAG).img
RUNTIME_SIGNED_OUT ?= $(BUILD_DIR)/images/lapee-runtime-$(RUNTIME_TME_TAG)$(RUNTIME_DEBUG_TAG)-signed.img
RUNTIME_SIGNED_UKI ?= $(BUILD_DIR)/images/lapee-runtime-$(RUNTIME_TME_TAG)$(RUNTIME_DEBUG_TAG).signed.efi
IMAGE ?= $(RUNTIME_SIGNED_OUT)
WRITE_IMAGE = $(if $(filter file,$(origin OUT)),$(IMAGE),$(OUT))
export BUILDROOT_VOLUME KERNEL_EXTRA_FRAGMENT DEFCONFIG_EXTRA_SNIPPET

.PHONY: help runtime-image runtime-write provisioner-image provisioner-write \
        signing-keys write-image wifi-creds operator-config-apply \
        qemu qemu-oracle qemu-gui qemu-green-zone qemu-green-zone-nonvolatile \
        qemu-provisioner-nonvolatile qemu-operator-config \
        _check-runtime-flags _check-signing-keys _check-provisioner-keys \
        _runtime-signed-image _usb-image _image-write _signing-keys \
        _provisioner-image _provisioner-write _wifi-creds \
        _operator-config-apply _qemu-green-zone-cluster \
        _qemu-green-zone-nonvolatile \
        _qemu-provisioner-nonvolatile \
        _qemu-operator-config-green-zone \
        all build native-build toolchain \
        kernel buildroot buildroot-shell buildroot-clean \
        hb-fetch paper clean

help:
	@awk '/^# =+$$/{flag=!flag;if(!flag)exit;next} \
	      flag{sub(/^# ?/,"");print}' $(firstword $(MAKEFILE_LIST))

# ------------------------------------------------------------
# Public release surface.
# ------------------------------------------------------------

runtime-image:
	$(MAKE) _check-runtime-flags
	$(MAKE) _check-signing-keys
	$(MAKE) toolchain
	$(MAKE) kernel
	$(MAKE) _runtime-signed-image
	@echo ">> signed runtime image: $(RUNTIME_SIGNED_OUT)"

runtime-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make runtime-write DEV=/dev/diskN [TME=0] [DEBUG=1]"; exit 1; }
	@if [ "$(WIFI)" != "0" ]; then \
	    ./scripts/gather-wifi-creds.sh --if-missing; \
	else \
	    echo ">> skipping wifi credential gather (WIFI=0)"; \
	fi
	$(MAKE) runtime-image
	$(MAKE) write-image DEV="$(DEV)" IMAGE="$(RUNTIME_SIGNED_OUT)"

provisioner-image:
	$(MAKE) _check-provisioner-keys
	$(MAKE) _provisioner-image

provisioner-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make provisioner-write DEV=/dev/diskN"; exit 1; }
	$(MAKE) _check-provisioner-keys
	$(MAKE) _provisioner-write DEV="$(DEV)"

signing-keys:
	$(MAKE) _signing-keys

write-image:
	@test -n "$(DEV)" || { \
	    echo "usage: make write-image DEV=/dev/diskN IMAGE=$(IMAGE)"; exit 1; }
	@test -f "$(WRITE_IMAGE)" || { \
	    echo "$(WRITE_IMAGE) missing. Set IMAGE=... or run: make runtime-image"; \
	    exit 1; }
	$(MAKE) _image-write OUT="$(WRITE_IMAGE)" DEV="$(DEV)"

wifi-creds:
	$(MAKE) _wifi-creds

operator-config-apply:
	@[ -f wifi.conf ] || [ -f config.json ] || { \
	    echo "nothing to apply: create wifi.conf and/or config.json"; \
	    exit 1; }
	$(MAKE) _operator-config-apply OUT="$(WRITE_IMAGE)"

qemu:
	@test -f "$(WRITE_IMAGE)" || { \
	    echo "$(WRITE_IMAGE) missing. Run: make runtime-image or set IMAGE=..."; \
	    exit 1; }
	./scripts/boot-usb-image.sh --img "$(WRITE_IMAGE)"

ORACLE_URL ?= https://example.com/
qemu-oracle:
	@test -f "$(WRITE_IMAGE)" || { \
	    echo "$(WRITE_IMAGE) missing. Run: make runtime-image or set IMAGE=..."; \
	    exit 1; }
	./scripts/boot-usb-image.sh --img "$(WRITE_IMAGE)" --oracle-url "$(ORACLE_URL)"

qemu-gui:
	@test -f "$(WRITE_IMAGE)" || { \
	    echo "$(WRITE_IMAGE) missing. Run: make runtime-image or set IMAGE=..."; \
	    exit 1; }
	./scripts/boot-usb-image.sh --img "$(WRITE_IMAGE)" --gui

qemu-green-zone:
	$(MAKE) _qemu-green-zone-cluster

qemu-green-zone-nonvolatile:
	$(MAKE) _qemu-green-zone-nonvolatile

qemu-provisioner-nonvolatile:
	$(MAKE) _qemu-provisioner-nonvolatile

qemu-operator-config:
	$(MAKE) _qemu-operator-config-green-zone

_check-runtime-flags:
	@case "$(TME)" in 0|1) ;; \
	    *) echo "TME must be 0 or 1"; exit 1;; \
	esac
	@case "$(DEBUG)" in 0|1) ;; \
	    *) echo "DEBUG must be 0 or 1"; exit 1;; \
	esac

_check-signing-keys:
	@test -f secureboot/db.key || { \
	    echo "secureboot/db.key missing. Run: make signing-keys"; exit 1; }
	@test -f secureboot/enrol/db.esl || { \
	    echo "secureboot/enrol/db.esl missing. Run: make signing-keys"; exit 1; }

_check-provisioner-keys:
	@test -f secureboot/enrol/db.auth || { \
	    echo "secureboot/enrol/db.auth missing. Run: make signing-keys"; exit 1; }
	@test -f secureboot/enrol/KEK.auth || { \
	    echo "secureboot/enrol/KEK.auth missing. Run: make signing-keys"; exit 1; }
	@test -f secureboot/enrol/PK.auth || { \
	    echo "secureboot/enrol/PK.auth missing. Run: make signing-keys"; exit 1; }

_runtime-signed-image:
	$(MAKE) _check-runtime-flags
	$(MAKE) _check-signing-keys
	$(MAKE) _usb-image \
	    CMDLINE='$(RUNTIME_CMDLINE)' \
	    OUT="$(RUNTIME_UNSIGNED_OUT)"
	BUILD_UKI="$(LAPEE_BUILD_DIR)/usb-build/lapee.efi" \
	SIGNED_UKI="$(abspath $(RUNTIME_SIGNED_UKI))" \
	USB_IMAGE="$(abspath $(RUNTIME_SIGNED_OUT))" \
	WIFI="$(WIFI)" \
	    ./scripts/sb-setup.sh sign

# ------------------------------------------------------------
# Top-level build orchestration.
#
# `build' = toolchain (Docker images) + kernel/rootfs (Buildroot
# inside the build image) + USB image (UKI + GPT/ESP, also inside
# the build image). Three steps, all Docker-internal under the
# hood; Buildroot owns the entire userspace including HyperBEAM.
# ------------------------------------------------------------

build: runtime-image

all: runtime-image

paper:
	$(MAKE) -C paper

native-build:
	@if [ "$(HOST_OS)" != "Linux" ]; then \
	    echo "native-build requires a Linux host (Buildroot doesn't run on $(HOST_OS))." >&2; \
	    echo "Use 'make runtime-image' instead." >&2; \
	    exit 1; \
	fi
	@$(MAKE) _check-native-deps
	NATIVE_BUILD=1 $(MAKE) kernel
	NATIVE_BUILD=1 $(MAKE) _usb-image
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

_usb-image:
	WIFI="$(WIFI)" ./scripts/build-usb-image.sh \
	    --kernel    "$(KERNEL)" \
	    --initramfs "$(INITRAMFS)" \
	    --cmdline   "$(CMDLINE)" \
	    --size      "$(SIZE_MIB)" \
	    --image     "$(OUT)"

_image-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make write-image DEV=/dev/diskN IMAGE=$(OUT)"; exit 1; }
	@test -f "$(OUT)" || { \
	    echo "$(OUT) missing. Put a pre-built image there or run: make runtime-image"; \
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

_signing-keys:
	./scripts/sb-setup.sh keys
	./scripts/sb-setup.sh enrol

_provisioner-image: toolchain
	@test -f secureboot/enrol/db.auth || { \
	    echo "secureboot/enrol/db.auth missing. Run: make signing-keys"; exit 1; }
	@test -f secureboot/enrol/KEK.auth || { \
	    echo "secureboot/enrol/KEK.auth missing. Run: make signing-keys"; exit 1; }
	@test -f secureboot/enrol/PK.auth || { \
	    echo "secureboot/enrol/PK.auth missing. Run: make signing-keys"; exit 1; }
	@if docker volume inspect $(SB_PROVISION_BUILDROOT_VOLUME) >/dev/null 2>&1; then \
	    docker run --rm $(DOCKER_PLATFORM) \
	        -v $(SB_PROVISION_BUILDROOT_VOLUME):/build \
	        $(BUILD_IMAGE) bash -c "rm -rf /build/out/build/lapee-sb-provisioner"; \
	fi
	$(MAKE) buildroot \
	    BUILDROOT_VOLUME=$(SB_PROVISION_BUILDROOT_VOLUME) \
	    LAPEE_BUILD_DIR="$(abspath $(SB_PROVISION_BUILD_DIR))" \
	    KERNEL_EXTRA_FRAGMENT="$(LAPEE_ROOT)/buildroot-external/board/lapee/linux-sb-provisioner-fragment.config" \
	    DEFCONFIG_EXTRA_SNIPPET="$(LAPEE_ROOT)/buildroot-external/configs/lapee-sb-provisioner.extra"
	$(MAKE) _usb-image WIFI=0 \
	    LAPEE_BUILD_DIR="$(abspath $(SB_PROVISION_BUILD_DIR))" \
	    KERNEL="$(SB_PROVISION_KERNEL)" \
	    INITRAMFS="$(SB_PROVISION_INITRAMFS)" \
	    CMDLINE='$(SB_PROVISION_CMDLINE)' \
	    OUT="$(SB_PROVISION_UNSIGNED_OUT)"
	BUILD_UKI="$(abspath $(SB_PROVISION_BUILD_DIR))/usb-build/lapee.efi" \
	SIGNED_UKI="$(abspath $(SB_PROVISION_SIGNED_UKI))" \
	USB_IMAGE="$(abspath $(SB_PROVISION_OUT))" \
	LAPEE_BUILD_DIR="$(abspath $(SB_PROVISION_BUILD_DIR))" \
	WIFI=0 \
	    ./scripts/sb-setup.sh sign

_provisioner-write:
	@test -n "$(DEV)" || { \
	    echo "usage: make provisioner-write DEV=/dev/diskN"; exit 1; }
	$(MAKE) _provisioner-image
	$(MAKE) _image-write OUT="$(SB_PROVISION_OUT)" DEV="$(DEV)"

_qemu-green-zone-cluster: toolchain
	./scripts/qemu-green-zone-cluster.sh

_qemu-green-zone-nonvolatile: toolchain
	NONVOLATILE=1 OUTDIR="$(BUILD_DIR)/qemu-green-zone-nonvolatile" \
	    ./scripts/qemu-green-zone-cluster.sh

_qemu-provisioner-nonvolatile: toolchain
	OUTDIR="$(BUILD_DIR)/qemu-provisioner-nonvolatile" \
	    ./scripts/qemu-provisioner-nonvolatile.sh

_qemu-operator-config-green-zone: toolchain
	./scripts/qemu-operator-config-green-zone.sh

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

_wifi-creds:
	./scripts/gather-wifi-creds.sh --force

_operator-config-apply: toolchain
	@[ -f wifi.conf ] || [ -f config.json ] || { \
	    echo "nothing to apply: create wifi.conf and/or config.json"; \
	    exit 1; }
	@test -f "$(OUT)" || { \
	    echo "$(OUT) missing. Run: make runtime-image or set OUT=..."; \
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
	        if [[ -f /w/wifi.conf ]]; then \
	            mcopy -i /tmp/esp.img -o /w/wifi.conf ::/EFI/boot/wifi.conf; \
	        fi; \
	        if [[ -f /w/config.json ]]; then \
	            mcopy -i /tmp/esp.img -o /w/config.json ::/EFI/boot/config.json; \
	        fi; \
	        dd if=/tmp/esp.img of=/w/$(OUT) \
	            bs=512 seek=$$START count=$$SECT \
	            conv=notrunc status=none'
	@echo ">> operator files applied to $(OUT)"

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
