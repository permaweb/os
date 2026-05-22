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

# 3. Sanity checks.
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
