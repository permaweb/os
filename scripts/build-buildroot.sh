#!/usr/bin/env bash
# build-buildroot.sh — drive the full LapEE build via Buildroot.
#
# Buildroot bootstraps a cross-toolchain from source on first
# build (BR2_TOOLCHAIN_BUILDROOT=y in lapee_defconfig) and uses
# it to compile the kernel, libc, OpenSSL, libtss2, busybox,
# wpa_supplicant, Erlang/OTP, and (via the custom hyperbeam
# package) HyperBEAM itself. The shipped boot path still uses
# Debian's x64 systemd EFI stub for the UKI and vendor firmware
# blobs where no source release exists; those are documented in
# the README.
#
# First build wall-clock is non-trivial: gcc bootstrap + Erlang
# cross-build + HB compile dominate. Incremental builds are
# fast (Buildroot tracks per-package state).
#
# Artefacts:
#   build/kernel/vmlinuz-lapee              — bzImage
#   build/initramfs/initramfs-lapee.cpio.zst — primary initramfs
#   build/initramfs/initramfs-lapee.cpio.gz  — fallback initramfs

set -euo pipefail
cd "$(dirname "$0")/.."

LAPEE_ROOT="$(pwd)"
HOST_BUILD_DIR="${LAPEE_BUILD_DIR:-$LAPEE_ROOT/build}"
LAPEE_LINUX_DIR="${LAPEE_LINUX_DIR:-$LAPEE_ROOT/arch/common/linux}"
LAPEE_BUILDROOT_EXTERNAL="${LAPEE_BUILDROOT_EXTERNAL:-$LAPEE_LINUX_DIR/buildroot-external}"
LAPEE_HB_DEVICE_DIR="${LAPEE_HB_DEVICE_DIR:-$LAPEE_ROOT/devices/common}"
LAPEE_HB_DEVICE_INPUTS=(cargo-locks native src rebar.config rebar.lock)
LAPEE_LINUX_DEVICE_DIR="${LAPEE_LINUX_DEVICE_DIR:-$LAPEE_ROOT/devices/linux}"
LAPEE_DOCKER_PROFILE="${LAPEE_DOCKER_PROFILE:-0}"
VOLUME="${BUILDROOT_VOLUME:-lapee-buildroot}"
IMAGE="${BUILD_IMAGE:-lapee-build:local}"
CONTAINER="${BUILDROOT_CONTAINER:-${VOLUME}-build}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
DEFCONFIG=${DEFCONFIG:-lapee_defconfig}
KERNEL_EXTRA_FRAGMENT="${KERNEL_EXTRA_FRAGMENT:-}"
DEFCONFIG_EXTRA_SNIPPET="${DEFCONFIG_EXTRA_SNIPPET:-}"
KERNEL_EXTRA_FRAGMENTS="${KERNEL_EXTRA_FRAGMENTS:-$KERNEL_EXTRA_FRAGMENT}"
DEFCONFIG_EXTRA_SNIPPETS="${DEFCONFIG_EXTRA_SNIPPETS:-$DEFCONFIG_EXTRA_SNIPPET}"
# Bash 3.2 treats expansion of an empty array as an unbound variable under
# `set -u'. Keep one empty sentinel so ordinary builds remain portable to the
# macOS system Bash; every consumer skips it.
KERNEL_EXTRA_FRAGMENT_LIST=("")
DEFCONFIG_EXTRA_SNIPPET_LIST=("")

# Buildroot 2026.02 LTS sources. Pinned tarball URL + sha256 so
# a corrupted/moved upstream is caught at fetch time.
BUILDROOT_VER=${BUILDROOT_VER:-2026.02.1}
BUILDROOT_URL="https://buildroot.org/downloads/buildroot-${BUILDROOT_VER}.tar.gz"
BUILDROOT_SHA256=${BUILDROOT_SHA256:-e296791039f806294a4e3e8d708d6b95631ca9fbca2e76a83d6058acaca459b5}

# HyperBEAM devices may be distributed as compiled BEAM code. Keep the
# Linux appliance on the same OTP release used by AndEE so remote
# packaged devices have one runtime target across PermawebOS arches.
ERLANG_VERSION=${ERLANG_VERSION:-28.5}
ERLANG_SHA256=${ERLANG_SHA256:-2c7e8ca23e6864eb20eff5d44738bfa123aed8cd21ed6d98e533d751eee28d9c}

# Buildroot pins linux-firmware to the release current at its own cut.
# Laptop Wi-Fi support ages faster than the rest of the rootfs, so keep
# this override close to the build driver where the matching source hash
# can be audited.
LINUX_FIRMWARE_VERSION=${LINUX_FIRMWARE_VERSION:-20260410}
LINUX_FIRMWARE_SHA256=${LINUX_FIRMWARE_SHA256:-b7812ed6d59f6b09ecceddaa0be842a7e82a79cc0e46ca60478a4ebf02f1e178}

case "$LAPEE_DOCKER_PROFILE" in
    0|1) ;;
    *) echo "LAPEE_DOCKER_PROFILE must be 0 or 1" >&2; exit 1 ;;
esac

if [[ -n "$KERNEL_EXTRA_FRAGMENTS" ]]; then
    read -r -a KERNEL_EXTRA_FRAGMENT_LIST <<< "$KERNEL_EXTRA_FRAGMENTS"
fi
if [[ -n "$DEFCONFIG_EXTRA_SNIPPETS" ]]; then
    read -r -a DEFCONFIG_EXTRA_SNIPPET_LIST <<< "$DEFCONFIG_EXTRA_SNIPPETS"
fi
for index in "${!KERNEL_EXTRA_FRAGMENT_LIST[@]}"; do
    fragment="${KERNEL_EXTRA_FRAGMENT_LIST[$index]}"
    [[ -n "$fragment" ]] || continue
    [[ -f "$fragment" ]] || {
        echo "missing kernel extra fragment: $fragment" >&2
        exit 1
    }
    KERNEL_EXTRA_FRAGMENT_LIST[$index]="$(cd "$(dirname "$fragment")" && pwd)/$(basename "$fragment")"
done
for index in "${!DEFCONFIG_EXTRA_SNIPPET_LIST[@]}"; do
    snippet="${DEFCONFIG_EXTRA_SNIPPET_LIST[$index]}"
    [[ -n "$snippet" ]] || continue
    [[ -f "$snippet" ]] || {
        echo "missing defconfig extra snippet: $snippet" >&2
        exit 1
    }
    DEFCONFIG_EXTRA_SNIPPET_LIST[$index]="$(cd "$(dirname "$snippet")" && pwd)/$(basename "$snippet")"
done

[[ -d "$LAPEE_HB_DEVICE_DIR" ]] || {
    echo "missing LAPEE_HB_DEVICE_DIR: $LAPEE_HB_DEVICE_DIR" >&2
    exit 1
}
for path in "${LAPEE_HB_DEVICE_INPUTS[@]}"; do
    [[ -e "$LAPEE_HB_DEVICE_DIR/$path" ]] || {
        echo "missing HyperBEAM device input: $LAPEE_HB_DEVICE_DIR/$path" >&2
        exit 1
    }
done
if [[ "$LAPEE_DOCKER_PROFILE" == "1" ]]; then
    [[ -d "$LAPEE_LINUX_DEVICE_DIR/src" ]] || {
        echo "missing Docker execution source directory: $LAPEE_LINUX_DEVICE_DIR/src" >&2
        exit 1
    }
    [[ -d "$LAPEE_LINUX_DEVICE_DIR/docs/device-specs" ]] || {
        echo "missing Docker device specifications" >&2
        exit 1
    }
fi

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
    -v "$LAPEE_BUILDROOT_EXTERNAL":/src-external:ro \
    $IMAGE bash -c "rm -rf /build/buildroot-external && \
                    cp -r /src-external /build/buildroot-external"

# Sync the LapEE-owned HyperBEAM device package into the volume. The
# HyperBEAM package build consumes this as an external Forge device source
# set; the fetched upstream checkout remains stock.
docker run --rm $DOCKER_PLATFORM \
    -v $VOLUME:/build \
    -v "$LAPEE_HB_DEVICE_DIR":/src-hyperbeam-devices:ro \
    $IMAGE bash -c "rm -rf /build/common-devices && \
                    mkdir -p /build/common-devices && \
                    cp -r \
                        /src-hyperbeam-devices/cargo-locks \
                        /src-hyperbeam-devices/native \
                        /src-hyperbeam-devices/src \
                        /src-hyperbeam-devices/rebar.config \
                        /src-hyperbeam-devices/rebar.lock \
                        /build/common-devices/"

if [[ "$LAPEE_DOCKER_PROFILE" == "1" ]]; then
    # Compose only the Linux adapter into the common source set Forge preloads.
    # The shared sandbox contract already belongs to the common package.
    docker run --rm $DOCKER_PLATFORM \
        -v $VOLUME:/build \
        -v "$LAPEE_LINUX_DEVICE_DIR":/src-linux-devices:ro \
        $IMAGE bash -euo pipefail -c '
            cp -a /src-linux-devices/src/*.erl /build/common-devices/src/
            mkdir -p /build/common-devices/docs/device-specs
            cp -a /src-linux-devices/docs/device-specs/*.md \
                /build/common-devices/docs/device-specs/
        '
fi

for KERNEL_EXTRA_FRAGMENT_PATH in "${KERNEL_EXTRA_FRAGMENT_LIST[@]}"; do
    [[ -n "$KERNEL_EXTRA_FRAGMENT_PATH" ]] || continue
    EXTRA_FRAGMENT_NAME="$(basename "$KERNEL_EXTRA_FRAGMENT_PATH")"
    echo "=== Applying extra kernel fragment: $EXTRA_FRAGMENT_NAME ==="
    docker run --rm $DOCKER_PLATFORM \
        -v $VOLUME:/build \
        -v "$KERNEL_EXTRA_FRAGMENT_PATH":/extra-kernel-fragment:ro \
        $IMAGE bash -euo pipefail -c "
            cfg=/build/buildroot-external/configs/$DEFCONFIG
            dst=/build/buildroot-external/board/lapee/$EXTRA_FRAGMENT_NAME
            cp /extra-kernel-fragment \"\$dst\"
            grep -q '^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=' \"\$cfg\"
            awk -v extra='\$(BR2_EXTERNAL_LAPEE_PATH)/board/lapee/$EXTRA_FRAGMENT_NAME' '
                /^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=/ {
                    sub(/\"$/, \" \" extra \"\\\"\")
                }
                { print }
            ' \"\$cfg\" > \"\$cfg.tmp\"
            mv \"\$cfg.tmp\" \"\$cfg\"
        "
done

for DEFCONFIG_EXTRA_SNIPPET_PATH in "${DEFCONFIG_EXTRA_SNIPPET_LIST[@]}"; do
    [[ -n "$DEFCONFIG_EXTRA_SNIPPET_PATH" ]] || continue
    echo "=== Applying extra defconfig snippet: $(basename "$DEFCONFIG_EXTRA_SNIPPET_PATH") ==="
    docker run --rm $DOCKER_PLATFORM \
        -v $VOLUME:/build \
        -v "$DEFCONFIG_EXTRA_SNIPPET_PATH":/extra-defconfig-snippet:ro \
        $IMAGE bash -euo pipefail -c "
            cfg=/build/buildroot-external/configs/$DEFCONFIG
            printf '\n# Extra LapEE build variant options.\n' >> \"\$cfg\"
            cat /extra-defconfig-snippet >> \"\$cfg\"
        "
done

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

# Buildroot's linux-firmware package accepts LINUX_FIRMWARE_VERSION from
# the make command line; add the corresponding source hash before the
# package downloader sees the override.
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
    bash -euo pipefail -c "
        hash_file=/build/buildroot/package/linux-firmware/linux-firmware.hash
        grep -q 'linux-firmware-${LINUX_FIRMWARE_VERSION}.tar.xz' \"\$hash_file\" || \
            printf '%s  %s  %s\n' \
                sha256 '${LINUX_FIRMWARE_SHA256}' \
                'linux-firmware-${LINUX_FIRMWARE_VERSION}.tar.xz' >> \"\$hash_file\"
    "

# Re-generate defconfig when absent or when the external defconfig changes.
# This preserves package build artefacts while keeping Buildroot .config
# aligned with BR2_EXTERNAL inputs.
DEFCONFIG_SHA=$(
    {
        shasum -a 256 "$LAPEE_BUILDROOT_EXTERNAL/configs/$DEFCONFIG"
        for path in "${KERNEL_EXTRA_FRAGMENT_LIST[@]}"; do
            [[ -n "$path" ]] || continue
            shasum -a 256 "$path"
        done
        for path in "${DEFCONFIG_EXTRA_SNIPPET_LIST[@]}"; do
            [[ -n "$path" ]] || continue
            shasum -a 256 "$path"
        done
    } | shasum -a 256 | awk '{print $1}'
)
KERNEL_FRAGMENT_SHA=$(
    {
        shasum -a 256 "$LAPEE_BUILDROOT_EXTERNAL"/board/lapee/linux-*.config
        if [[ -d "$LAPEE_BUILDROOT_EXTERNAL/board/lapee/patches" ]]; then
            while IFS= read -r patch; do
                shasum -a 256 "$patch"
            done < <(
                find "$LAPEE_BUILDROOT_EXTERNAL/board/lapee/patches" -type f \
                    | LC_ALL=C sort
            )
        fi
        for path in "${KERNEL_EXTRA_FRAGMENT_LIST[@]}"; do
            [[ -n "$path" ]] || continue
            shasum -a 256 "$path"
        done
    } | shasum -a 256 | awk '{print $1}'
)
HYPERBEAM_RECIPE_SHA=$(
    {
        find "$LAPEE_BUILDROOT_EXTERNAL/package/hyperbeam" -type f
        for path in "${LAPEE_HB_DEVICE_INPUTS[@]}"; do
            if [[ -d "$LAPEE_HB_DEVICE_DIR/$path" ]]; then
                find "$LAPEE_HB_DEVICE_DIR/$path" -type f
            else
                printf '%s\n' "$LAPEE_HB_DEVICE_DIR/$path"
            fi
        done
        if [[ "$LAPEE_DOCKER_PROFILE" == "1" ]]; then
            find "$LAPEE_LINUX_DEVICE_DIR/src" \
                 "$LAPEE_LINUX_DEVICE_DIR/docs" -type f
        fi
    } \
        | LC_ALL=C sort \
        | xargs shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
FIRMWARE_SELECTION_SHA=$(
    {
        printf 'LINUX_FIRMWARE_VERSION=%s\n' "$LINUX_FIRMWARE_VERSION"
        printf 'LINUX_FIRMWARE_SHA256=%s\n' "$LINUX_FIRMWARE_SHA256"
        grep '^BR2_PACKAGE_LINUX_FIRMWARE_' "$LAPEE_BUILDROOT_EXTERNAL/configs/$DEFCONFIG"
        for path in "${DEFCONFIG_EXTRA_SNIPPET_LIST[@]}"; do
            [[ -n "$path" ]] || continue
            grep '^BR2_PACKAGE_LINUX_FIRMWARE_' "$path" || true
        done
    } \
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

if ! docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -c "test \"\$(cat /build/out/.lapee-kernel-fragment.sha256 2>/dev/null)\" = '$KERNEL_FRAGMENT_SHA'" 2>/dev/null; then
    echo "=== Kernel fragment changed or untracked; cleaning linux ==="
    docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build $IMAGE \
        bash -euo pipefail -c "
            cd /build/out
            make linux-dirclean || true
            rm -f /build/out/images/bzImage
            echo '$KERNEL_FRAGMENT_SHA' > /build/out/.lapee-kernel-fragment.sha256
        "
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
            make LINUX_FIRMWARE_VERSION='$LINUX_FIRMWARE_VERSION' linux-firmware-dirclean || true
            rm -rf /build/out/build/linux-firmware-*
            rm -rf /build/out/target/lib/firmware/intel/iwlwifi \
                   /build/out/target/lib/firmware/i915 \
                   /build/out/target/lib/firmware/xe \
                   /build/out/target/lib/firmware/amdgpu \
                   /build/out/target/lib/firmware/ath10k \
                   /build/out/target/lib/firmware/ath11k \
                   /build/out/target/lib/firmware/ath12k \
                   /build/out/target/lib/firmware/brcm \
                   /build/out/target/lib/firmware/cypress \
                   /build/out/target/lib/firmware/mediatek \
                   /build/out/target/lib/firmware/mrvl \
                   /build/out/target/lib/firmware/rtlwifi \
                   /build/out/target/lib/firmware/rtl_nic \
                   /build/out/target/lib/firmware/rtw88 \
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

# Rebuild HyperBEAM when its Buildroot recipe changes. Buildroot correctly
# tracks package source files once extracted, but it does not automatically
# notice edits to BR2_EXTERNAL package makefiles, where cross-compile settings
# live.
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
docker rm -f "$CONTAINER" 2>/dev/null || true
echo "=== Buildroot build (foreground; logs streamed; -j$JOBS) ==="
docker run --rm --name "$CONTAINER" $DOCKER_PLATFORM \
    -v $VOLUME:/build \
    -e BR2_JLEVEL="$JOBS" \
    -e LAPEE_DOCKER_PROFILE="$LAPEE_DOCKER_PROFILE" \
    $IMAGE bash -euo pipefail -c "cd /build/out && date && make ERLANG_VERSION='$ERLANG_VERSION' LINUX_FIRMWARE_VERSION='$LINUX_FIRMWARE_VERSION' -j$JOBS 2>&1 | tee /build/out/build.log"

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
mkdir -p "$HOST_BUILD_DIR/kernel" "$HOST_BUILD_DIR/initramfs"
docker run --rm $DOCKER_PLATFORM -v $VOLUME:/build \
    -v "$HOST_BUILD_DIR/kernel:/host-kernel" \
    -v "$HOST_BUILD_DIR/initramfs:/host-initramfs" \
    $IMAGE bash -euo pipefail -c "
        test -f /build/out/images/bzImage || { \
            echo 'no bzImage produced (look at /build/out/build.log)' >&2; \
            exit 1; }
        cp /build/out/images/bzImage /host-kernel/vmlinuz-lapee

        for ext in zst gz; do
            if [ -f /build/out/images/rootfs.cpio.\$ext ]; then
                cp /build/out/images/rootfs.cpio.\$ext \
                   /host-initramfs/initramfs-lapee.cpio.\$ext
            fi
        done
    "

echo ""
echo "=== artefacts ==="
ls -lh "$HOST_BUILD_DIR/kernel/vmlinuz-lapee" \
       "$HOST_BUILD_DIR"/initramfs/initramfs-lapee.cpio.* 2>/dev/null
