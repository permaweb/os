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
BUILDROOT_VER=${BUILDROOT_VER:-2026.02.1}
BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.gz"
BUILDROOT_SHA256=${BUILDROOT_SHA256:-e296791039f806294a4e3e8d708d6b95631ca9fbca2e76a83d6058acaca459b5}

# HyperBEAM's v1-ish LapEE branch uses OTP 27 syntax (maybe expressions
# and triple-quoted strings). Buildroot 2026.02.1 still defaults to OTP
# 26, so pin the package version here while keeping the package recipe
# itself upstream Buildroot.
ERLANG_VERSION=${ERLANG_VERSION:-27.3.4.11}
ERLANG_SHA256=${ERLANG_SHA256:-9d63382d3e7707c058dabe338114e09ff8228d54d29df794d907d3c8dddde5f9}

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

# Teach the pinned Buildroot tree the hash for the Erlang/OTP release
# selected above. The make command line overrides ERLANG_VERSION; the
# package hash file still needs to know about that source tarball.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
    bash -euo pipefail -c "
        hash_file=/build/buildroot/package/erlang/erlang.hash
        grep -q 'otp_src_${ERLANG_VERSION}.tar.gz' \"\$hash_file\" || \
            printf '%s  %s  %s\n' \
                sha256 '${ERLANG_SHA256}' \
                'otp_src_${ERLANG_VERSION}.tar.gz' >> \"\$hash_file\"
    "

# Re-generate defconfig when absent or when the external defconfig
# changes. This preserves package build artefacts but keeps the
# Buildroot .config aligned with the moving BR2_EXTERNAL tree during
# the from-scratch-toolchain transition.
DEFCONFIG_SHA=$(shasum -a 256 "buildroot-external/configs/$DEFCONFIG" | awk '{print $1}')
HYPERBEAM_RECIPE_SHA=$(
    find buildroot-external/package/hyperbeam -type f \
        | LC_ALL=C sort \
        | xargs shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
FIRMWARE_SELECTION_SHA=$(
    grep '^BR2_PACKAGE_LINUX_FIRMWARE_' "buildroot-external/configs/$DEFCONFIG" \
        | LC_ALL=C sort \
        | shasum -a 256 \
        | awk '{print $1}'
)
CONFIG_NEEDS_REFRESH=0
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test -f /build/out/.config" 2>/dev/null; then
    CONFIG_NEEDS_REFRESH=1
elif ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test \"\$(cat /build/out/.lapee-defconfig.sha256 2>/dev/null)\" = '$DEFCONFIG_SHA'" 2>/dev/null; then
    CONFIG_NEEDS_REFRESH=1
fi

if [ "$CONFIG_NEEDS_REFRESH" = "1" ]; then
    echo "=== Generating $DEFCONFIG ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
	    bash -c "mkdir -p /build/out && cd /build/buildroot && \
	             make O=/build/out BR2_EXTERNAL=/build/buildroot-external $DEFCONFIG && \
	             echo '$DEFCONFIG_SHA' > /build/out/.lapee-defconfig.sha256"
fi

# Buildroot tracks package state with stamps, so a defconfig refresh that
# enables additional firmware can leave linux-firmware marked installed from
# the previous selection. Force just that package to rebuild when our firmware
# selection changes; keep the wireless regulatory database owned by its own
# package intact.
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test \"\$(cat /build/out/.lapee-firmware-selection.sha256 2>/dev/null)\" = '$FIRMWARE_SELECTION_SHA'" 2>/dev/null; then
    echo "=== Firmware selection changed or untracked; cleaning linux-firmware ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -euo pipefail -c "
            cd /build/out
            make linux-firmware-dirclean || true
            rm -rf /build/out/target/lib/firmware/intel/iwlwifi \
                   /build/out/target/lib/firmware/mediatek \
                   /build/out/target/lib/firmware/rtl_nic \
                   /build/out/target/lib/firmware/rtw89
            echo '$FIRMWARE_SELECTION_SHA' > /build/out/.lapee-firmware-selection.sha256
        "
fi

# Rebuild Erlang and HyperBEAM when the pinned OTP version changes; the
# target rootfs can otherwise retain stale erts/lib files from an older
# package install.
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test \"\$(cat /build/out/.lapee-erlang-version 2>/dev/null)\" = '$ERLANG_VERSION'" 2>/dev/null; then
    echo "=== Erlang/OTP version changed or untracked; cleaning Erlang + HyperBEAM ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -euo pipefail -c "
            cd /build/out
            make ERLANG_VERSION='$ERLANG_VERSION' erlang-dirclean host-erlang-dirclean hyperbeam-dirclean || true
            rm -rf /build/out/target/usr/lib/erlang \
                   /build/out/target/usr/lib/hyperbeam \
                   /build/out/build/hyperbeam-*
            echo '$ERLANG_VERSION' > /build/out/.lapee-erlang-version
        "
fi

# Rebuild HyperBEAM when its Buildroot recipe changes. Buildroot
# correctly tracks package source files once extracted, but it does not
# automatically notice edits to BR2_EXTERNAL package makefiles. During
# this toolchain transition those makefile hooks are exactly where
# cross-compile fixes land, so stale release trees are more dangerous
# than a short dirclean.
if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test \"\$(cat /build/out/.lapee-hyperbeam-recipe.sha256 2>/dev/null)\" = '$HYPERBEAM_RECIPE_SHA'" 2>/dev/null; then
    echo "=== HyperBEAM recipe changed or untracked; cleaning HyperBEAM ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -euo pipefail -c "
            cd /build/out
            make ERLANG_VERSION='$ERLANG_VERSION' hyperbeam-dirclean || true
            rm -rf /build/out/target/usr/lib/hyperbeam \
                   /build/out/build/hyperbeam-*
            echo '$HYPERBEAM_RECIPE_SHA' > /build/out/.lapee-hyperbeam-recipe.sha256
        "
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
    $IMAGE bash -c "cd /build/out && date && make ERLANG_VERSION='$ERLANG_VERSION' -j$JOBS 2>&1 | tee /build/out/build.log"

# Guard the final rootfs against stale host-architecture release
# payloads. This is especially important on Apple Silicon because relx
# runs under host Erlang while the target release must be x86_64.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
    bash -euo pipefail -c '
        test -f /build/out/target/usr/lib/hyperbeam/lib/asn1-*/priv/lib/asn1rt_nif.so
        find /build/out/target/usr/lib/hyperbeam /build/out/target/usr/lib/erlang \
            -type f \( -perm /111 -o -name "*.so*" \) -print0 \
            | xargs -0 -r file \
            | awk "/ELF/ && \$0 !~ /x86-64/ {print; bad=1} END {exit bad}"
    '

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
