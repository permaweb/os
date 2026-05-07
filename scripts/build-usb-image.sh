#!/usr/bin/env bash
# build-usb-image.sh — assemble a UEFI-bootable LapEE USB image.
#
# Inputs (kernel + initramfs + cmdline) → GPT-partitioned disk
# image with one EFI System Partition containing a single
# Unified Kernel Image at the UEFI fallback boot path
# (\EFI\Boot\BootX64.efi). UEFI firmware executes that path
# automatically when no NVRAM BootOrder entry is configured —
# fully portable between machines without Framework NVRAM
# changes.
#
# The UKI is assembled in-container by `systemd-ukify' over the
# kernel + initramfs + cmdline, stamped with os-release metadata,
# linked against systemd-stub.
#
# For signed-UKI workflows see `sb-setup.sh': it signs the UKI
# this script produces with the operator's db.key and re-invokes
# this script with `--uki <signed>' to wrap the signed PE into a
# fresh USB image.
#
#   Inputs  : --kernel PATH --initramfs PATH --cmdline TEXT
#             [--size MIB]     image size in MiB, or "auto"
#                              (default: auto, derived from UKI
#                              plus staged ESP files and margin)
#             [--uki PATH]     skip the inline ukify build and
#                              use a pre-built UKI (e.g. the
#                              signed one from sb-setup.sh)
#   Outputs : --image PATH     write an .img file you can dd
#             OR
#             --device PATH    write directly to a raw block dev
#                              (macOS: /dev/rdiskN; Linux:
#                              /dev/sdX). Prompts before writing.
#
# Tool wrapping: every Linux-only step (parted, mkfs.vfat, mtools,
# ukify) runs inside the lapee-build container. Override the
# image with BUILD_IMAGE=<tag>; the Makefile sets that to a
# pinned-digest local layer.

set -euo pipefail

LAPEE_ROOT="${LAPEE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_IMAGE="${BUILD_IMAGE:-lapee-build:local}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"
WORK="${LAPEE_BUILD_DIR:-${LAPEE_ROOT}/build}"

KERNEL=""
INITRAMFS=""
CMDLINE=""
PREBUILT_UKI=""
OUT_IMAGE=""
OUT_DEVICE=""
SIZE_MIB=auto

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# /,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --kernel)    KERNEL="$2"; shift 2 ;;
        --initramfs) INITRAMFS="$2"; shift 2 ;;
        --cmdline)   CMDLINE="$2"; shift 2 ;;
        --uki)       PREBUILT_UKI="$2"; shift 2 ;;
        --size)      SIZE_MIB="$2"; shift 2 ;;
        --image)     OUT_IMAGE="$2"; shift 2 ;;
        --device)    OUT_DEVICE="$2"; shift 2 ;;
        -h|--help)   usage ;;
        *) die "unknown argument: $1 (use --help)" ;;
    esac
done

# ---- input validation ------------------------------------------

if [[ -z "$OUT_IMAGE" && -z "$OUT_DEVICE" ]]; then
    die "one of --image or --device is required"
fi
if [[ -n "$OUT_IMAGE" && -n "$OUT_DEVICE" ]]; then
    die "--image and --device are mutually exclusive"
fi
if [[ -n "$OUT_IMAGE" && "$OUT_IMAGE" != /* ]]; then
    OUT_IMAGE="${LAPEE_ROOT}/${OUT_IMAGE}"
fi

if [[ -z "$PREBUILT_UKI" ]]; then
    [[ -n "$KERNEL"    ]] || die "--kernel required (or supply --uki)"
    [[ -n "$INITRAMFS" ]] || die "--initramfs required (or supply --uki)"
    [[ -n "$CMDLINE"   ]] || die "--cmdline required (or supply --uki)"
    [[ -f "$KERNEL"    ]] || die "kernel not found: $KERNEL"
    [[ -f "$INITRAMFS" ]] || die "initramfs not found: $INITRAMFS"
else
    [[ -f "$PREBUILT_UKI" ]] || die "UKI not found: $PREBUILT_UKI"
fi

mkdir -p "$WORK"
BUILD_DIR="$WORK/usb-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- step 1: build or stage the UKI ---------------------------

if [[ -n "$PREBUILT_UKI" ]]; then
    cp "$PREBUILT_UKI" "$BUILD_DIR/lapee.efi"
    echo ">> using pre-built UKI: $PREBUILT_UKI"
else
    echo ">> building UKI from kernel + initramfs"
    cp "$KERNEL"    "$BUILD_DIR/kernel"
    cp "$INITRAMFS" "$BUILD_DIR/initramfs.cpio.gz"
    cat > "$BUILD_DIR/os-release" <<EOF
NAME="LapEE"
ID=lapee
VERSION_ID="${LAPEE_VERSION:-dev}"
PRETTY_NAME="LapEE (${LAPEE_VERSION:-dev})"
EOF
    echo "$CMDLINE" > "$BUILD_DIR/cmdline.txt"

    docker run --rm $DOCKER_PLATFORM \
        -v "${WORK}":/work \
        -w /work/usb-build \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c "
            if command -v ukify >/dev/null 2>&1; then
                ukify build \\
                    --linux=/work/usb-build/kernel \\
                    --initrd=/work/usb-build/initramfs.cpio.gz \\
                    --cmdline=\"\$(cat /work/usb-build/cmdline.txt)\" \\
                    --os-release=@/work/usb-build/os-release \\
                    --output=/work/usb-build/lapee.efi
            else
                STUB=\$(find /usr/lib /lib -name 'linuxx64.efi.stub' \\
                        -print -quit 2>/dev/null)
                : \${STUB:?systemd-stub not found}
                OBJCOPY=\$(command -v x86_64-w64-mingw32-objcopy || \\
                          command -v objcopy)
                KERNEL_SIZE=\$(stat -c %s /work/usb-build/kernel)
                LINUX_VMA=0x2000000
                INITRD_VMA=\$(( (LINUX_VMA + KERNEL_SIZE + 0xfffff) & ~0xfffff ))
                INITRD_VMA_HEX=\$(printf '0x%x' "\$INITRD_VMA")
                \"\$OBJCOPY\" \\
                    --add-section .osrel=/work/usb-build/os-release \\
                    --change-section-vma .osrel=0x20000 \\
                    --add-section .cmdline=/work/usb-build/cmdline.txt \\
                    --change-section-vma .cmdline=0x30000 \\
                    --add-section .linux=/work/usb-build/kernel \\
                    --change-section-vma .linux=\$LINUX_VMA \\
                    --add-section .initrd=/work/usb-build/initramfs.cpio.gz \\
                    --change-section-vma .initrd=\$INITRD_VMA_HEX \\
                    \"\${STUB}\" /work/usb-build/lapee.efi
            fi
        "
fi

UKI_SIZE=$(stat -f %z "$BUILD_DIR/lapee.efi" 2>/dev/null \
           || stat -c %s "$BUILD_DIR/lapee.efi")
echo ">> UKI size: $UKI_SIZE bytes"

# ---- step 1b: stage SB enrolment .auth files if present -------
SB_ENROL_DIR="${LAPEE_ROOT}/secureboot/enrol"
STAGED_SB=""
STAGED_EXTRA_BYTES=0
if [[ -d "$SB_ENROL_DIR" ]]; then
    for f in PK.auth KEK.auth db.auth PK.cer KEK.cer db.cer PK.esl KEK.esl db.esl; do
        if [[ -f "$SB_ENROL_DIR/$f" ]]; then
            cp "$SB_ENROL_DIR/$f" "$BUILD_DIR/$f"
            STAGED_SB="${STAGED_SB}${STAGED_SB:+ }$f"
            sz=$(stat -f %z "$SB_ENROL_DIR/$f" 2>/dev/null \
                 || stat -c %s "$SB_ENROL_DIR/$f")
            STAGED_EXTRA_BYTES=$((STAGED_EXTRA_BYTES + sz))
        fi
    done
fi
if [[ -n "$STAGED_SB" ]]; then
    echo ">> staging SB enrolment bundle: $STAGED_SB"
fi

# Stage host-side wifi.conf if present and enabled. WIFI=0 is useful
# for QEMU/test images and for intentionally wired-only USB sticks:
# the measured cmdline may still carry lapee.wifi=enabled, but init
# will find no credential file and keep association disabled.
if [[ "${WIFI:-1}" != "0" && -f "${LAPEE_ROOT}/wifi.conf" ]]; then
    cp "${LAPEE_ROOT}/wifi.conf" "$BUILD_DIR/wifi.conf"
    wifi_bytes=$(wc -c <"${LAPEE_ROOT}/wifi.conf" | tr -d ' ')
    STAGED_EXTRA_BYTES=$((STAGED_EXTRA_BYTES + wifi_bytes))
    echo ">> staging wifi.conf (${wifi_bytes} bytes)"
elif [[ "${WIFI:-1}" == "0" ]]; then
    echo ">> not staging wifi.conf (WIFI=0)"
fi

# Optional operator HyperBEAM config. Init copies this off the ESP
# into tmpfs as /tmp/config.json, then starts HB with the measured
# LapEE config last in HB_CONFIG so enforced devices/hooks win.
if [[ -f "${LAPEE_ROOT}/config.json" ]]; then
    cp "${LAPEE_ROOT}/config.json" "$BUILD_DIR/config.json"
    config_bytes=$(wc -c <"${LAPEE_ROOT}/config.json" | tr -d ' ')
    STAGED_EXTRA_BYTES=$((STAGED_EXTRA_BYTES + config_bytes))
    echo ">> staging config.json (${config_bytes} bytes)"
fi

# A disk image cannot be exactly the UKI byte length: firmware wants
# a GPT disk with an EFI System Partition, and FAT32 needs metadata
# and slack. Auto-size from staged payload bytes, then add enough room
# for FAT tables, GPT alignment, and small ESP-side metadata.
PAYLOAD_BYTES=$((UKI_SIZE + STAGED_EXTRA_BYTES + 131072))
PAYLOAD_MIB=$(( (PAYLOAD_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))
MIN_IMAGE_MIB=$((PAYLOAD_MIB + 20))
if (( MIN_IMAGE_MIB < 64 )); then
    MIN_IMAGE_MIB=64
fi
# Round to a 4 MiB boundary. This keeps the image compact without
# creating awkward byte-sized GPT/FAT geometry.
MIN_IMAGE_MIB=$(( ((MIN_IMAGE_MIB + 3) / 4) * 4 ))

if [[ "$SIZE_MIB" == "auto" ]]; then
    SIZE_MIB="$MIN_IMAGE_MIB"
    echo ">> auto image size: ${SIZE_MIB} MiB (payload ${PAYLOAD_MIB} MiB)"
elif [[ "$SIZE_MIB" =~ ^[0-9]+$ ]]; then
    if (( SIZE_MIB < MIN_IMAGE_MIB )); then
        die "--size $SIZE_MIB MiB too small (minimum ${MIN_IMAGE_MIB} MiB for staged payload)"
    fi
else
    die "--size must be an integer MiB value or 'auto'"
fi

# ---- step 2: build the disk image inside the tools container --

IMG_IN_WORK="usb-build/disk.img"

docker run --rm $DOCKER_PLATFORM \
    -v "${WORK}":/work \
    -w /work \
    "$BUILD_IMAGE" \
    bash -euo pipefail -c "
        truncate -s ${SIZE_MIB}M /work/${IMG_IN_WORK}

        parted --script /work/${IMG_IN_WORK} \\
            mklabel gpt \\
            mkpart ESP fat32 1MiB 100% \\
            set 1 esp on

        START_LBA=\$(parted --script --machine /work/${IMG_IN_WORK} \\
            unit s print | awk -F: '/^1:/ {gsub(\"s\",\"\",\$2); print \$2}')
        SECTORS=\$(parted --script --machine /work/${IMG_IN_WORK} \\
            unit s print | awk -F: '/^1:/ {gsub(\"s\",\"\",\$4); print \$4}')
        echo \">> ESP starts at sector \$START_LBA, spans \$SECTORS sectors\"

        dd if=/work/${IMG_IN_WORK} of=/work/usb-build/esp.img \\
            bs=512 skip=\$START_LBA count=\$SECTORS \\
            status=none conv=sparse

        mkfs.vfat -F 32 -n LAPEE_ESP /work/usb-build/esp.img \\
            >/dev/null

        mmd -i /work/usb-build/esp.img ::/EFI
        mmd -i /work/usb-build/esp.img ::/EFI/Boot
        mcopy -i /work/usb-build/esp.img \\
            /work/usb-build/lapee.efi ::/EFI/Boot/BootX64.efi
        echo 'LapEE UEFI-bootable USB. UKI at /EFI/Boot/BootX64.efi.' \\
            > /work/usb-build/README.TXT
        echo 'lapee-esp-v1' > /work/usb-build/LAPEE.MARKER
        mcopy -i /work/usb-build/esp.img \\
            /work/usb-build/README.TXT ::/README.TXT
        mcopy -i /work/usb-build/esp.img \\
            /work/usb-build/LAPEE.MARKER ::/LAPEE.MARKER

        for _a in PK.auth KEK.auth db.auth PK.cer KEK.cer db.cer PK.esl KEK.esl db.esl; do
            if [[ -f /work/usb-build/\$_a ]]; then
                mcopy -i /work/usb-build/esp.img \\
                    /work/usb-build/\$_a ::/\$_a
            fi
        done

        if [[ -f /work/usb-build/wifi.conf ]]; then
            mcopy -i /work/usb-build/esp.img \\
                /work/usb-build/wifi.conf ::/EFI/boot/wifi.conf
        fi

        if [[ -f /work/usb-build/config.json ]]; then
            mcopy -i /work/usb-build/esp.img \\
                /work/usb-build/config.json ::/EFI/boot/config.json
        fi

        dd if=/work/usb-build/esp.img of=/work/${IMG_IN_WORK} \\
            bs=512 seek=\$START_LBA count=\$SECTORS \\
            conv=notrunc,sparse status=none

        echo '>> verifying partition layout:'
        parted --script /work/${IMG_IN_WORK} unit MiB print

        ls -lh /work/${IMG_IN_WORK}
    "

FINAL_IMG="${WORK}/${IMG_IN_WORK}"
if [[ ! -f "$FINAL_IMG" ]]; then
    die "image build failed (no $FINAL_IMG)"
fi

# ---- step 3: move to --image or write to --device --------------

if [[ -n "$OUT_IMAGE" ]]; then
    mkdir -p "$(dirname "$OUT_IMAGE")"
    mv "$FINAL_IMG" "$OUT_IMAGE"
    IMG_BYTES=$(stat -f %z "$OUT_IMAGE" 2>/dev/null \
                || stat -c %s "$OUT_IMAGE")
    echo ""
    echo "=========================================================="
    echo ">> USB image ready: $OUT_IMAGE ($IMG_BYTES bytes)"
    echo "=========================================================="
    echo "To write to a USB stick on macOS:"
    echo "  diskutil list                       # find /dev/diskN"
    echo "  diskutil unmountDisk /dev/diskN"
    echo "  sudo dd if=$OUT_IMAGE of=/dev/rdiskN bs=4m status=progress"
    echo "  diskutil eject /dev/diskN"
    echo ""
    echo "On Linux:"
    echo "  sudo dd if=$OUT_IMAGE of=/dev/sdX bs=4M status=progress conv=fsync"
    echo ""
fi

if [[ -n "$OUT_DEVICE" ]]; then
    [[ -e "$OUT_DEVICE" ]] || die "device not found: $OUT_DEVICE"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        [[ "$OUT_DEVICE" =~ ^/dev/(r?disk[0-9]+)$ ]] \
            || die "macOS device must be /dev/diskN or /dev/rdiskN"
        DISKID="${BASH_REMATCH[1]#r}"
        RAW="/dev/r${DISKID}"
        echo ">> target : $OUT_DEVICE → will write through $RAW"
        echo ">> $(diskutil info "/dev/$DISKID" \
                   | grep -E '(Device.*(Identifier|Node)|Media Name|Disk Size)' \
                   | sed 's/^/     /')"
        echo ""
        read -r -p "Unmount and write image to $RAW? [type YES] " CONFIRM
        [[ "$CONFIRM" == "YES" ]] || die "aborted"
        diskutil unmountDisk "/dev/$DISKID"
        sudo dd if="$FINAL_IMG" of="$RAW" bs=4m
        diskutil eject "/dev/$DISKID"
    else
        [[ -b "$OUT_DEVICE" ]] || die "not a block device: $OUT_DEVICE"
        echo ">> target : $OUT_DEVICE"
        echo ">> $(lsblk -o NAME,SIZE,MODEL "$OUT_DEVICE" 2>/dev/null \
                   | sed 's/^/     /')"
        read -r -p "Write image to $OUT_DEVICE? [type YES] " CONFIRM
        [[ "$CONFIRM" == "YES" ]] || die "aborted"
        sudo dd if="$FINAL_IMG" of="$OUT_DEVICE" bs=4M status=progress conv=fsync
        sync
    fi
    LAST_IMG="${WORK}/images/lapee-usb-last.img"
    mkdir -p "$(dirname "$LAST_IMG")"
    mv "$FINAL_IMG" "$LAST_IMG"
    echo ""
    echo "=========================================================="
    echo ">> $OUT_DEVICE ready. Image saved at ${LAST_IMG#$LAPEE_ROOT/}."
    echo "=========================================================="
fi
