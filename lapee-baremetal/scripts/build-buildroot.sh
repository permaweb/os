#!/usr/bin/env bash
# build-buildroot.sh — drive the full LapEE build via Buildroot.
#
# Buildroot bootstraps a cross-toolchain from source on first
# build (BR2_TOOLCHAIN_BUILDROOT=y in lapee_defconfig) and uses
# it to compile every binary in the boot chain — kernel, libc,
# OpenSSL, libtss2, busybox, wpa_supplicant, Erlang/OTP, and
# (via the custom hyperbeam package) HyperBEAM itself. The only
# upstream binaries left are non-free WiFi firmware blobs, which
# are documented in the README.
#
# First build wall-clock is non-trivial: gcc bootstrap + Erlang
# cross-build + HB compile dominate. Incremental builds are
# fast (Buildroot tracks per-package state).
#
# Artefacts:
#   build-kernel/vmlinuz-lapee           — bzImage
#   work/initramfs-lapee.cpio.zst        — primary initramfs
#   work/initramfs-lapee.cpio.gz         — fallback initramfs

set -euo pipefail
cd "$(dirname "$0")/.."

LAPEE_ROOT="$(pwd)"
VOLUME=lapee-buildroot
IMAGE="${BUILD_IMAGE:-lapee-build:local}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
DEFCONFIG=${DEFCONFIG:-lapee_defconfig}

# Buildroot 2024.02 LTS sources. Pinned tarball URL + sha256 so
# a corrupted/moved upstream is caught at fetch time.
BUILDROOT_VER=${BUILDROOT_VER:-2024.02.7}
BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.gz"
BUILDROOT_SHA256=${BUILDROOT_SHA256:-5032773427d97ccb08ef125f98e288c0042562e3340e07b5c3978dc8698d5d22}

# Ensure the docker volume exists. Wipe its config marker if the
# defconfig file's mtime is newer than what the volume saw last
# time — Buildroot regenerates the config but doesn't always
# rebuild downstream packages without this nudge when toolchain
# choice changes.
docker volume inspect $VOLUME >/dev/null 2>&1 || docker volume create $VOLUME

# A fresh docker volume is owned by UID 0 (root) at the
# mountpoint. Buildroot refuses to run as root, so the Dockerfile
# sets USER builder — but builder can't `mkdir /build/...' on a
# root-owned mount. Idempotent fix: chown /build to builder
# before any builder-owned operation. Cheap when already correct.
docker run --rm $DOCKER_PLATFORM --user 0 \
    -v $VOLUME:/build \
    $IMAGE bash -c "chown builder:builder /build"

# Sync the external tree into the volume (always — it's tiny).
docker run --rm $DOCKER_PLATFORM \
    -v $VOLUME:/build \
    -v "$LAPEE_ROOT/buildroot-external":/src-external:ro \
    $IMAGE bash -c "rm -rf /build/buildroot-external && \
                    cp -r /src-external /build/buildroot-external"

# If the buildroot source tree isn't in the volume yet, download it.
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test -f /build/buildroot/Makefile" 2>/dev/null; then
    echo "=== Fetching Buildroot ${BUILDROOT_VER} into volume (one-time) ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -euo pipefail -c "
            cd /tmp
            wget -q --no-verbose -O br.tar.gz '${BUILDROOT_URL}'
            echo '${BUILDROOT_SHA256}  br.tar.gz' | sha256sum -c -
            tar -xzf br.tar.gz
            rm -f br.tar.gz
            mv 'buildroot-${BUILDROOT_VER}' /build/buildroot
        "
fi

# Re-generate defconfig if /build/out doesn't exist yet.
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test -f /build/out/.config" 2>/dev/null; then
    echo "=== Generating $DEFCONFIG ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "mkdir -p /build/out && cd /build/buildroot && \
                 make O=/build/out BR2_EXTERNAL=/build/buildroot-external $DEFCONFIG"
fi

# Run the build to completion.
#
# JOBS controls per-package parallelism. Buildroot itself
# serialises packages (it has to — package B may depend on
# package A's headers); within a package's `make' the JOBS value
# is the -j level. Default to the host CPU count; override with
# JOBS=N if needed (e.g. on a memory-constrained host).
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}
docker rm -f lapee-br-build 2>/dev/null || true
echo "=== Buildroot build (foreground; logs streamed; -j$JOBS) ==="
docker run --rm --name lapee-br-build $DOCKER_PLATFORM \
    -v $VOLUME:/build \
    -e BR2_JLEVEL="$JOBS" \
    $IMAGE bash -c "cd /build/out && date && make -j$JOBS 2>&1 | tee /build/out/build.log"

# Collect artefacts.
mkdir -p build-kernel work
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build \
    -v "$PWD/build-kernel:/host-kernel" \
    -v "$PWD/work:/host-work" \
    $IMAGE bash -euo pipefail -c "
        test -f /build/out/images/bzImage || { \
            echo 'no bzImage produced (look at /build/out/build.log)' >&2; \
            exit 1; }
        cp /build/out/images/bzImage /host-kernel/vmlinuz-lapee

        for ext in zst gz; do
            if [ -f /build/out/images/rootfs.cpio.\$ext ]; then
                cp /build/out/images/rootfs.cpio.\$ext \
                   /host-work/initramfs-lapee.cpio.\$ext
            fi
        done
    "

echo ""
echo "=== artefacts ==="
ls -lh build-kernel/vmlinuz-lapee work/initramfs-lapee.cpio.* 2>/dev/null
