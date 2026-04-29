# LapEE bare-metal — build orchestration.
#
# Goal: one UEFI-bootable USB image that boots a real laptop and
# serves a TPM-attested HyperBEAM node. Every binary in the boot
# chain is from-source: Buildroot bootstraps gcc / glibc /
# binutils, then cross-compiles the kernel + Erlang/OTP +
# OpenSSL + libtss2 + busybox + wpa_supplicant + iproute2 + iw +
# the LapEE custom hyperbeam package. The only upstream binaries
# left are non-free WiFi firmware (Intel iwlwifi / MediaTek
# MT7922) — no source release exists; their hashes go into PCR 9.
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
#   make hb-usb-write DEV=  — flash work/lapee-usb.img to a USB.
#   make hb-usb-debug-write DEV=
#                           — flash a measured debug-console image
#                             with lapee.debug=1 on the cmdline.
#   make gather-wifi-creds  — prompt locally for wifi.conf.
#   make hb-usb-qemu        — boot work/lapee-usb.img under
#                             QEMU+OVMF+swtpm and fetch attestation
#                             over the forwarded network port.
#   make hb-usb-qemu-gui    — same with a Cocoa window so the
#                             operator can watch the splash.
#   make hb-fetch           — populate build-hyperbeam/src-edge
#                             with the pinned verifier source.
#   make hb-wifi-apply      — inject host-side wifi.conf into the
#                             ESP without re-signing.
#   make hb-sb-apply        — inject Secure Boot enrolment bundle.
#   make buildroot-shell    — drop into the Buildroot volume in a
#                             shell, for debugging.
#   make buildroot-clean    — wipe the Buildroot volume entirely.
#   make clean              — remove generated work/ files only.
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
KERNEL    ?= build-kernel/vmlinuz-lapee
INITRAMFS ?= work/initramfs-lapee.cpio.zst
SIZE_MIB  ?= 1024
OUT       ?= work/lapee-usb.img
WIFI      ?= 1
SPLASH    ?= blue
DEBUG     ?= 0
HYPERBEAM_REPO ?= https://github.com/permaweb/hyperbeam
HYPERBEAM_VERSION ?= $(shell awk -F'\\?= ' '/^HYPERBEAM_VERSION/ {print $$2; exit}' buildroot-external/package/hyperbeam/hyperbeam.mk)
HYPERBEAM_SRC ?= build-hyperbeam/src-edge
PROD_CMDLINE  = console=tty0 quiet loglevel=0 vt.global_cursor_default=0 \
                rdinit=/init lapee.mode=prod lapee.wifi=enabled \
                lapee.splash=$(SPLASH)
DEBUG_CMDLINE = console=ttyS0 console=tty0 earlyprintk=efi,keep keep_bootcon \
                fbcon=nodefer loglevel=7 panic=10 rdinit=/init \
                lapee.mode=debug lapee.debug=1 lapee.wifi=enabled \
                lapee.splash=$(SPLASH)

CMDLINE   ?= $(if $(filter 1,$(DEBUG)),$(DEBUG_CMDLINE),$(PROD_CMDLINE))

.PHONY: help all build native-build toolchain \
        kernel buildroot buildroot-shell buildroot-clean \
        hb-usb-image hb-usb-write hb-usb-debug-image hb-usb-debug-write \
        hb-usb-qemu hb-usb-qemu-gui hb-fetch gather-wifi-creds hb-wifi-apply hb-sb-apply \
        clean

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

hb-usb-debug-image: DEBUG=1
hb-usb-debug-image: OUT=work/lapee-usb-debug.img
hb-usb-debug-image: hb-usb-image

hb-usb-debug-write: DEBUG=1
hb-usb-debug-write: hb-usb-write

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

# ------------------------------------------------------------
# ESP injection helpers (operator-side, no UKI re-sign).
# ------------------------------------------------------------

gather-wifi-creds:
	./scripts/gather-wifi-creds.sh --force

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
	       work/initramfs-lapee.cpio.* work/usb-build/ out/local-capture/
	@echo "cleaned. Buildroot volume preserved (run 'make buildroot-clean' to wipe)."
