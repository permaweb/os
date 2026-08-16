#!/bin/sh
# post-build.sh — runs after Buildroot has installed the rootfs
# overlay + target packages, before image-creation.
#
# Responsibilities:
#   1. Compile lapee_splash.erl using host-erlang and stage the
#      resulting .beam into /usr/local/lib/lapee-splash/.
#   2. Sanity-check that everything we expect on the target is
#      present (HyperBEAM, libtss2, busybox, init).
#
# $1 = TARGET_DIR

set -eu

TARGET_DIR=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LAPEE_EXT=${BR2_EXTERNAL_LAPEE_PATH:-}
if [ -z "$LAPEE_EXT" ] || [ ! -f "$LAPEE_EXT/board/lapee/files/lapee_splash.erl" ]; then
    LAPEE_EXT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
fi
HOST_ROOT=${HOST_DIR:-$(dirname "$TARGET_DIR")/host}
HOST_ERLC=$HOST_ROOT/bin/erlc
BUILD_ROOT=$(dirname "$TARGET_DIR")
BUILD_CONFIG=${BR2_CONFIG:-$BUILD_ROOT/.config}
DOCKER_PROFILE=${LAPEE_DOCKER_PROFILE:-0}

case "$DOCKER_PROFILE" in
    0|1) ;;
    *)
        echo "!! post-build: LAPEE_DOCKER_PROFILE must be 0 or 1" >&2
        exit 1
        ;;
esac

CAPABILITY_DIR=$TARGET_DIR/etc/lapee/capabilities
CAPABILITY_HOOK=$CAPABILITY_DIR/runtime
if [ "$DOCKER_PROFILE" = "1" ]; then
    install -D -m 0700 \
        "$LAPEE_EXT/board/lapee/files/docker-runtime-capability.sh" \
        "$CAPABILITY_HOOK"
else
    if [ -e "$CAPABILITY_HOOK" ]; then
        echo "!! post-build: ordinary rootfs retained a capability activation hook" >&2
        exit 1
    fi
fi

# 1. Splash daemon: compile from this BR2_EXTERNAL tree's source
#    using host-erlang, install into the target rootfs.
if [ -x "$HOST_ERLC" ]; then
    SPLASH_SRC=$LAPEE_EXT/board/lapee/files/lapee_splash.erl
    SPLASH_DST=$TARGET_DIR/usr/local/lib/lapee-splash
    echo ">> compiling lapee_splash from $SPLASH_SRC with $HOST_ERLC"
    if [ ! -f "$SPLASH_SRC" ]; then
        echo "!! splash source not found: $SPLASH_SRC" >&2
        exit 1
    fi
    mkdir -p "$SPLASH_DST"
    (cd "$(dirname "$SPLASH_SRC")" && "$HOST_ERLC" -o "$SPLASH_DST" lapee_splash.erl)
    echo ">> lapee_splash.beam installed at $SPLASH_DST"
else
    echo "!! host-erlang not found at $HOST_ERLC; splash not built" >&2
    exit 1
fi

# 2. Firmware broadening. Buildroot's linux-firmware package exposes
#    some broad Wi-Fi families as fine-grained options, but the package
#    recipe can lag newer Intel and Qualcomm directories even when the
#    downloaded tarball has them. Copy the complete trees for the driver
#    families we build into the kernel.
FW_SRC=$(find "$BUILD_ROOT/build" -maxdepth 1 -type d -name 'linux-firmware-*' \
    | LC_ALL=C sort | tail -n 1)
if [ -z "$FW_SRC" ] || [ ! -d "$FW_SRC" ]; then
    echo "!! post-build: linux-firmware source tree not found under $BUILD_ROOT/build" >&2
    exit 1
fi

stage_firmware_tree() {
    rel=$1
    src=$FW_SRC/$rel
    dst=$TARGET_DIR/lib/firmware/$rel
    if [ ! -d "$src" ]; then
        echo "!! post-build: missing firmware source tree $src" >&2
        exit 1
    fi
    mkdir -p "$dst"
    cp -a "$src"/. "$dst"/
}

stage_firmware_whence_links() {
    # The kernel firmware loader does exact-path lookups. Upstream
    # linux-firmware records the public compatibility paths in WHENCE as
    # `Link:' entries, often pointing from a driver-requested root filename
    # to a vendor subdirectory. Replay every link whose target exists in
    # our staged subset instead of carrying vendor-specific guesses here.
    links_file=$BUILD_ROOT/.lapee-firmware-whence-links
    awk '
        /^Link:[[:space:]]*/ {
            line = $0
            sub(/^Link:[[:space:]]*/, "", line)
            sub(/[[:space:]]*->[[:space:]]*/, "|", line)
            print line
        }
    ' "$FW_SRC/WHENCE" > "$links_file"

    count=0
    while IFS='|' read -r link target; do
        [ -n "$link" ] || continue
        [ -n "$target" ] || continue

        link_dir=$TARGET_DIR/lib/firmware/$(dirname "$link")
        link_path=$TARGET_DIR/lib/firmware/$link
        mkdir -p "$link_dir"

        # WHENCE link targets are relative to the link's directory, matching
        # upstream copy-firmware.sh.
        [ -e "$link_dir/$target" ] || continue
        if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
            echo ">> preserving existing firmware file $link"
            continue
        fi

        ln -sfn "$target" "$link_path"
        count=$((count + 1))
    done < "$links_file"
    rm -f "$links_file"
    echo ">> staged $count firmware compatibility links from WHENCE"
}

stage_firmware_tree intel/iwlwifi
stage_firmware_tree ath10k
stage_firmware_tree ath11k
stage_firmware_tree ath12k
stage_firmware_tree brcm
stage_firmware_tree cypress
stage_firmware_whence_links

# 3. Optional measured execution profile. Buildroot's Docker Engine package
#    selects its runtime dependencies and general kernel fixups; this gate
#    verifies both the resolved build graph and final target, including the
#    absence of every profile surface from ordinary images.
DOCKER_CONFIG_OPTIONS='BR2_PACKAGE_CGROUPFS_V2_MOUNT=y
BR2_PACKAGE_CONTAINERD=y
BR2_PACKAGE_DOCKER_CLI=y
BR2_PACKAGE_DOCKER_ENGINE=y
BR2_PACKAGE_DOCKER_ENGINE_DOCKER_INIT_TINI=y
BR2_PACKAGE_IPTABLES=y
BR2_PACKAGE_LIBSECCOMP=y
BR2_PACKAGE_RUNC=y
BR2_PACKAGE_TINI=y'

DOCKER_TARGET_PATHS='/usr/bin/docker
/usr/bin/dockerd
/usr/bin/docker-proxy
/usr/bin/containerd
/usr/bin/containerd-shim-runc-v2
/usr/bin/ctr
/usr/bin/runc
/usr/bin/tini
/usr/libexec/docker/docker-init'

if [ "$DOCKER_PROFILE" = "1" ]; then
    for _option in $DOCKER_CONFIG_OPTIONS; do
        grep -qx "$_option" "$BUILD_CONFIG" || {
            echo "!! post-build: Docker profile did not resolve $_option" >&2
            exit 1
        }
    done
    for _path in $DOCKER_TARGET_PATHS; do
        if [ ! -e "$TARGET_DIR$_path" ]; then
            echo "!! post-build: Docker profile is missing $TARGET_DIR$_path" >&2
            exit 1
        fi
    done
    KERNEL_CONFIG=$(find "$BUILD_ROOT/build" -maxdepth 2 -type f \
        -path '*/linux-*/.config' | LC_ALL=C sort | tail -n 1)
    if [ -z "$KERNEL_CONFIG" ]; then
        echo "!! post-build: Docker profile kernel config was not found" >&2
        exit 1
    fi
    for _kernel_option in \
            CONFIG_BLK_CGROUP CONFIG_BLK_DEV_THROTTLING CONFIG_BPF_SYSCALL \
            CONFIG_BRIDGE CONFIG_BRIDGE_NETFILTER CONFIG_CFS_BANDWIDTH \
            CONFIG_CGROUPS CONFIG_CGROUP_BPF CONFIG_CGROUP_CPUACCT \
            CONFIG_CGROUP_DEVICE CONFIG_CGROUP_FREEZER CONFIG_CGROUP_PIDS \
            CONFIG_CGROUP_SCHED CONFIG_CPUSETS CONFIG_FAIR_GROUP_SCHED \
            CONFIG_IPC_NS CONFIG_IP_NF_FILTER CONFIG_IP_NF_IPTABLES \
            CONFIG_IP_NF_IPTABLES_LEGACY CONFIG_IP_NF_NAT CONFIG_MEMCG \
            CONFIG_NAMESPACES CONFIG_NETFILTER CONFIG_NETFILTER_XTABLES \
            CONFIG_NETFILTER_XTABLES_LEGACY \
            CONFIG_NET_NS CONFIG_NF_CONNTRACK CONFIG_NF_NAT \
            CONFIG_OVERLAY_FS CONFIG_PID_NS CONFIG_SECCOMP \
            CONFIG_SECCOMP_FILTER CONFIG_UTS_NS CONFIG_VETH; do
        grep -Eq "^${_kernel_option}=[ym]$" "$KERNEL_CONFIG" || {
            echo "!! post-build: Docker kernel did not resolve $_kernel_option" >&2
            exit 1
        }
    done
    if grep -Eq '^CONFIG_KVM(_INTEL|_AMD)?=[ym]$' "$KERNEL_CONFIG"; then
        echo "!! post-build: Docker profile contains forbidden guest KVM support" >&2
        exit 1
    fi

    PRELOADED_STORE=$TARGET_DIR/usr/lib/hyperbeam/_build/preloaded-store/data.mdb
    if [ ! -s "$PRELOADED_STORE" ] || \
       ! grep -aFq 'docker@1.0' "$PRELOADED_STORE"; then
        echo "!! post-build: Docker profile has no docker@1.0 device archive" >&2
        exit 1
    fi
    echo ">> verified optional measured Docker execution profile"
else
    for _option in $DOCKER_CONFIG_OPTIONS; do
        if grep -qx "$_option" "$BUILD_CONFIG"; then
            echo "!! post-build: ordinary rootfs resolved forbidden $_option" >&2
            exit 1
        fi
    done
    for _path in $DOCKER_TARGET_PATHS; do
        if [ -e "$TARGET_DIR$_path" ]; then
            echo "!! post-build: ordinary rootfs contains $TARGET_DIR$_path" >&2
            exit 1
        fi
    done
    if grep -Eq \
            '^BR2_PACKAGE_(CONTAINERD|DOCKER[^=]*|RUNC|TINI)=y$' \
            "$BUILD_CONFIG"; then
        echo "!! post-build: ordinary rootfs resolved a Docker runtime package" >&2
        exit 1
    fi
    if find "$TARGET_DIR" \( -iname '*docker*' -o -name containerd -o \
            -name 'containerd-shim*' -o -name runc -o -name tini \) \
            -print -quit | grep -q .; then
        echo "!! post-build: ordinary rootfs contains a Docker runtime artifact" >&2
        exit 1
    fi
    PRELOADED_STORE=$TARGET_DIR/usr/lib/hyperbeam/_build/preloaded-store/data.mdb
    if [ -s "$PRELOADED_STORE" ] && \
       grep -aFq 'docker@1.0' "$PRELOADED_STORE"; then
        echo "!! post-build: ordinary rootfs contains docker@1.0" >&2
        exit 1
    fi
    if grep -iq 'docker' "$TARGET_DIR/init"; then
        echo "!! post-build: ordinary init contains a Docker marker" >&2
        exit 1
    fi
    echo ">> verified ordinary rootfs remains Docker-free"
fi

# Application devices are runtime composition, never image payload. Check both
# the filesystem boundary and the opaque Forge store so a stale Buildroot
# volume cannot smuggle an Ouroboros package into either profile.
if find "$TARGET_DIR" -iname '*ouroboros*' -print -quit | grep -q .; then
    echo "!! post-build: rootfs contains a forbidden Ouroboros artifact" >&2
    exit 1
fi
if [ -s "$PRELOADED_STORE" ] && grep -aEq \
        'ouroboros(@1[.]0|-space@1[.]0)|lib_ouroboros' "$PRELOADED_STORE"; then
    echo "!! post-build: preloaded store contains a forbidden application device" >&2
    exit 1
fi

# QEMU, VM firmware, and toolbox payloads are not part of either Linux image
# profile. Keep this independent of the optional execution capability so a
# stale Buildroot volume cannot silently carry them into an ordinary build.
if grep -E '^BR2_PACKAGE_QEMU[^=]*=y$' "$BUILD_CONFIG" | \
        grep -Fvxq 'BR2_PACKAGE_QEMU_ARCH_SUPPORTS_TARGET=y'; then
    echo "!! post-build: rootfs resolved a forbidden QEMU package" >&2
    exit 1
fi
for _forbidden in /usr/bin/qemu-img /usr/bin/qemu-system-x86_64 \
        /usr/share/qemu /usr/share/permawebos/tool-environments; do
    if [ -e "$TARGET_DIR$_forbidden" ]; then
        echo "!! post-build: rootfs contains forbidden $_forbidden" >&2
        exit 1
    fi
done
if find "$TARGET_DIR" \( -iname '*qemu*' -o -iname '*.qcow2' -o \
        -iname '*toolbox*' -o -name 'docker-image.tar' \) \
        -print -quit | grep -q .; then
    echo "!! post-build: rootfs contains a forbidden VM/toolbox/image payload" >&2
    exit 1
fi

# 4. Sanity checks.
for f in /init /etc/lapee/lapee.json \
         /usr/lib/hyperbeam/bin/hb \
         /usr/local/lib/lapee-splash/lapee_splash.beam \
         /lib/firmware/regulatory.db \
         /lib/firmware/ath10k/QCA6174/hw3.0/firmware-6.bin \
         /lib/firmware/ath11k/QCA6390/hw2.0/amss.bin \
         /lib/firmware/ath11k/WCN6855/hw2.0/amss.bin \
         /lib/firmware/ath12k/WCN7850/hw2.0/amss.bin \
         /lib/firmware/brcm/bcm43xx-0.fw \
         /lib/firmware/brcm/bcm43xx_hdr-0.fw \
         /lib/firmware/brcm/brcmfmac43602-pcie.bin \
         /lib/firmware/cypress/cyfmac54591-pcie.bin \
         /lib/firmware/intel/iwlwifi/iwlwifi-bz-b0-fm-c0-101.ucode \
         /lib/firmware/intel/iwlwifi/iwlwifi-sc-a0-wh-b0-c103.ucode \
         /lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0-89.ucode \
         /lib/firmware/intel/iwlwifi/iwlwifi-so-a0-gf-a0.pnvm \
         /lib/firmware/intel/iwlwifi/iwlwifi-ma-b0-gf-a0-89.ucode \
         /lib/firmware/intel/iwlwifi/iwlwifi-ma-b0-gf-a0.pnvm \
         /lib/firmware/iwlwifi-ma-b0-gf-a0-89.ucode \
         /lib/firmware/iwlwifi-ma-b0-gf-a0.pnvm \
         /lib/firmware/intel/iwlwifi/iwlwifi-ty-a0-gf-a0.pnvm \
         /lib/firmware/intel/iwlwifi/iwlwifi-gl-c0-fm-c0.pnvm \
         /lib/firmware/mrvl/pcie8897_uapsta.bin \
         /lib/firmware/mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin \
         /lib/firmware/mediatek/WIFI_RAM_CODE_MT7922_1.bin \
         /lib/firmware/rtl_nic/rtl8156b-2.fw \
         /lib/firmware/rtlwifi/rtl8822befw.bin \
         /lib/firmware/rtw88/rtw8822c_fw.bin; do
    if [ ! -e "$TARGET_DIR$f" ]; then
        echo "!! post-build: missing $TARGET_DIR$f" >&2
        exit 1
    fi
done

echo ">> post-build sanity checks passed"
