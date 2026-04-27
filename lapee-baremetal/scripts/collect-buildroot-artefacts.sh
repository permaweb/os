#!/usr/bin/env bash
# collect-buildroot-artefacts.sh — copy Buildroot outputs from the
# lapee-build-m1 Docker volume into build-kernel/ and work/.
#
# `make kernel' (build-buildroot.sh) does this automatically;
# this script exists as a separate tool for the case where the
# build was driven manually or where the volume already holds
# completed outputs but the host-side artefacts went away.

set -euo pipefail
cd "$(dirname "$0")/.."

VOLUME=lapee-buildroot
IMAGE="${BUILD_IMAGE:-lapee-build:local}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"

# Sanity-check that outputs actually exist in the volume.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
    bash -c "ls /build/out/images/" || {
    echo "[FAIL] /build/out/images/ empty — build didn't complete?"
    exit 1
}

mkdir -p build-kernel work

# Kernel.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build \
    -v "$PWD/build-kernel:/host-out" $IMAGE \
    bash -c "test -f /build/out/images/bzImage && \
             cp /build/out/images/bzImage /host-out/vmlinuz-lapee && \
             ls -lh /host-out/vmlinuz-lapee"

# Buildroot's smoke-boot rootfs (only consumed by the kernel
# defconfig's QEMU smoke-boot path; the production initramfs is
# assembled separately by build-initramfs-hb.sh).
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build \
    -v "$PWD/work:/host-work" $IMAGE \
    bash -c "if [ -f /build/out/images/rootfs.cpio.gz ]; then \
               cp /build/out/images/rootfs.cpio.gz /host-work/initramfs-buildroot.cpio.gz; \
             elif [ -f /build/out/images/rootfs.cpio ]; then \
               gzip -c /build/out/images/rootfs.cpio > /host-work/initramfs-buildroot.cpio.gz; \
             else \
               echo '(no Buildroot rootfs image — fine if you only need the kernel)'; \
             fi"

# Kernel .config snapshot, useful for verifying the hardened
# symbols actually made it into the build.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build \
    -v "$PWD/work:/host-work" $IMAGE \
    bash -c "cp /build/out/build/linux-*/.config /host-work/linux.config.built 2>/dev/null || \
             echo '(no kernel .config found — linux pkg not built yet)'"

echo
echo "=== Artefacts collected ==="
ls -lh build-kernel/vmlinuz-lapee work/initramfs-buildroot.cpio.gz 2>&1 || true
[[ -f work/linux.config.built ]] && echo "kernel .config: work/linux.config.built"
