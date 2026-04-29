#!/usr/bin/env bash
# boot-usb-image.sh — boot the LapEE USB image under QEMU+OVMF+
# swtpm. This is the same artefact we'd write to a USB stick for
# Framework native boot; booting it in QEMU gives us high-
# confidence validation that the image is correct (UEFI +
# FAT32 ESP + \EFI\Boot\BootX64.efi + UKI + kernel + init +
# network attestation path) before we hand it to hardware.
#
# The image is copied to a scratch path first so test runs never
# mutate the original. Success is defined by fetching the live
# attestation envelope through QEMU's forwarded HTTP port.
#
# Usage:
#   ./scripts/boot-usb-image.sh
#   ./scripts/boot-usb-image.sh --img work/lapee-usb.img
#   ./scripts/boot-usb-image.sh --timeout 600   (seconds)

set -euo pipefail
cd "$(dirname "$0")/.."

IMG=${IMG:-work/lapee-usb.img}
TIMEOUT=${TIMEOUT:-420}
LOGFILE=${LOGFILE:-/tmp/lapee-usb-qemu.log}
# `--gui' opens a QEMU window so the operator can see the framebuffer
# console -- splash daemon, kernel banners, init traces. Default stays
# headless (`-nographic') for non-interactive attestation testing.
GUI=0

while (($# > 0)); do
    case "$1" in
        --img)     IMG=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --log)     LOGFILE=$2; shift 2;;
        --gui)     GUI=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[[ -f "$IMG" ]] || { echo "no $IMG (run: make hb-usb-image)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }

# OVMF firmware is shipped by the host's QEMU package. The path
# varies across distros + Homebrew prefixes; search the usual
# spots and let the operator override by exporting
# OVMF_CODE / OVMF_VARS_TEMPLATE before running.
find_ovmf() {
    local _name=$1; shift
    for _p in "$@"; do
        [[ -f "$_p" ]] && { echo "$_p"; return 0; }
    done
    return 1
}
if [[ -z "${OVMF_CODE:-}" ]]; then
    OVMF_CODE=$(find_ovmf code \
        /opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd \
        /usr/share/qemu/edk2-x86_64-code.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd || true)
fi
if [[ -z "${OVMF_VARS_TEMPLATE:-}" ]]; then
    OVMF_VARS_TEMPLATE=$(find_ovmf vars \
        /opt/homebrew/opt/qemu/share/qemu/edk2-i386-vars.fd \
        /usr/local/share/qemu/edk2-i386-vars.fd \
        /usr/share/qemu/edk2-i386-vars.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/x64/OVMF_VARS.fd || true)
fi
for f in "$OVMF_CODE" "$OVMF_VARS_TEMPLATE"; do
    [[ -f "$f" ]] || { echo "missing OVMF firmware (set OVMF_CODE/OVMF_VARS_TEMPLATE if installed at a non-standard path): $f" >&2; exit 1; }
done

# Scratch copies so we don't mutate the source image or NVRAM.
mkdir -p work/qemu-usb
SCRATCH_IMG=work/qemu-usb/scratch.img
SCRATCH_VARS=work/qemu-usb/vars.fd
cp "$IMG" "$SCRATCH_IMG"
cp "$OVMF_VARS_TEMPLATE" "$SCRATCH_VARS"

# Fresh swtpm.
if [[ -f work/tpm-qemu/swtpm.pid ]]; then
    kill "$(cat work/tpm-qemu/swtpm.pid)" 2>/dev/null || true
fi
rm -rf work/tpm-qemu && mkdir -p work/tpm-qemu
swtpm socket --tpm2 --tpmstate dir=work/tpm-qemu \
    --ctrl type=unixio,path="$(pwd)/work/tpm-qemu/swtpm-sock" \
    --flags not-need-init,startup-clear \
    --log "file=work/tpm-qemu/swtpm.log,level=5" \
    --daemon --pid "file=work/tpm-qemu/swtpm.pid"
sleep 1

echo "=== booting $SCRATCH_IMG under QEMU+OVMF+swtpm ==="
echo "    log: $LOGFILE  (timeout: ${TIMEOUT}s)"

# QEMU invocation. The image boots via \EFI\Boot\BootX64.efi so
# no -kernel / -initrd is needed — UEFI finds and executes the
# UKI itself. Two display modes: headless (-nographic, default;
# kernel + init goes to host stdio) and gui (Cocoa window with
# the framebuffer console + a serial chardev so we can still see
# the boot log via $LOGFILE). VGA is `std' so the kernel binds
# vesafb/efifb cleanly.
COMMON_ARGS=(
    -machine q35,accel=tcg
    -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx
    -m 2048 -smp 4
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
    -drive "if=pflash,format=raw,file=${SCRATCH_VARS}"
    -drive "file=${SCRATCH_IMG},format=raw,if=virtio"
    -chardev "socket,id=chrtpm,path=$(pwd)/work/tpm-qemu/swtpm-sock"
    -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis,tpmdev=tpm0
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:18734-:8734"
    -device virtio-net-pci,netdev=net0
)

# Truncate the serial log up front so a failure report only shows
# the current run.
: > "$LOGFILE"

if (( GUI )); then
    echo "    GUI: QEMU window will open; close it (or send Ctrl-C) to stop"
    qemu-system-x86_64 \
        "${COMMON_ARGS[@]}" \
        -display cocoa -vga std \
        -serial "file:${LOGFILE}" &
else
    qemu-system-x86_64 \
        "${COMMON_ARGS[@]}" \
        -nographic \
        > "$LOGFILE" 2>&1 &
fi
QEMUPID=$!
trap 'kill $QEMUPID 2>/dev/null || true; kill $(cat work/tpm-qemu/swtpm.pid 2>/dev/null) 2>/dev/null || true' EXIT

if (( GUI )); then
    # GUI mode: hand control to the QEMU window. Do not poll the
    # network port or auto-kill -- the operator wants to
    # watch the splash + interact. Wait for QEMU to exit on its own
    # (window close, Ctrl-C, guest poweroff).
    echo "    waiting for QEMU to exit (close window or Ctrl-C)..."
    wait $QEMUPID 2>/dev/null || true
    kill "$(cat work/tpm-qemu/swtpm.pid 2>/dev/null)" 2>/dev/null || true
    exit 0
fi

# Poll the forwarded HTTP port until HB answers. The cheap /info
# endpoint is readiness; /attestation is the actual end-to-end proof.
BASE_URL=http://127.0.0.1:18734
OUTDIR=out/qemu-network-test
mkdir -p "$OUTDIR"
INFO_OUT="$OUTDIR/info.json"
ATT_OUT="$OUTDIR/attestation.json"

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
    if curl -fsSL \
            -H "accept: application/json" \
            -H "accept-bundle: true" \
            "$BASE_URL/~tpm2@2.0a/info" \
            -o "$INFO_OUT" 2>/dev/null && [[ -s "$INFO_OUT" ]]; then
        echo ">> HB /info answered on $BASE_URL"
        break
    fi
    if ! kill -0 $QEMUPID 2>/dev/null; then
        echo "!! qemu exited before network attestation became reachable" >&2
        tail -60 "$LOGFILE"
        exit 1
    fi
    sleep 2
done

if [[ ! -s "$INFO_OUT" ]]; then
    echo "!! timeout waiting for HB /info on $BASE_URL" >&2
    echo "!! last 80 lines of serial log:" >&2
    tail -80 "$LOGFILE" >&2
    exit 1
fi

echo ">> fetching full attestation envelope"
if ! curl -fsSL \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        "$BASE_URL/~tpm2@2.0a/attestation" \
        -o "$ATT_OUT"; then
    echo "!! attestation fetch failed from $BASE_URL" >&2
    echo "!! last 80 lines of serial log:" >&2
    tail -80 "$LOGFILE" >&2
    exit 1
fi
if [[ ! -s "$ATT_OUT" ]]; then
    echo "!! empty attestation envelope from $BASE_URL" >&2
    exit 1
fi

kill $QEMUPID 2>/dev/null || true
wait $QEMUPID 2>/dev/null || true
kill "$(cat work/tpm-qemu/swtpm.pid 2>/dev/null)" 2>/dev/null || true

echo ""
echo "=== QEMU boot test PASSED ==="
ls -lh "$OUTDIR"/
echo ""
echo "Interpret the saved QEMU envelope (fetched over the network):"
echo "  ./scripts/interpret-local-capture.sh \\"
echo "      --label 'QEMU USB image self-test' \\"
echo "      $ATT_OUT"
echo ""
echo "For physical hardware, prefer the live network path:"
echo "  ./scripts/interpret-local-capture.sh --url http://NODE-IP:8734 --label LABEL"
