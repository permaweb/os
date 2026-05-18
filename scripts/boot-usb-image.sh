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
#   ./scripts/boot-usb-image.sh --img build/images/lapee-usb.img
#   ./scripts/boot-usb-image.sh --timeout 600   (seconds)
#   ./scripts/boot-usb-image.sh --oracle-url https://example.com/

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
IMG=${IMG:-$BUILD_DIR/images/lapee-usb.img}
TIMEOUT=${TIMEOUT:-420}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-network-test}
LOGFILE=${LOGFILE:-$OUTDIR/serial.log}
ORACLE_URL=${ORACLE_URL:-}
# `--gui' opens a QEMU window so the operator can see the framebuffer
# console -- splash daemon, kernel banners, init traces. Default stays
# headless (`-nographic') for non-interactive attestation testing.
GUI=0

while (($# > 0)); do
    case "$1" in
        --img)     IMG=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --log)     LOGFILE=$2; shift 2;;
        --oracle-url) ORACLE_URL=$2; shift 2;;
        --gui)     GUI=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

[[ -f "$IMG" ]] || { echo "no $IMG (run: make runtime-image)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }
if [[ -n "$ORACLE_URL" ]]; then
    command -v python3 >/dev/null 2>&1 || { echo "missing python3" >&2; exit 1; }
fi

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
QEMU_WORK="$BUILD_DIR/qemu-usb"
TPM_WORK="$BUILD_DIR/tpm-qemu"
mkdir -p "$QEMU_WORK"
SCRATCH_IMG="$QEMU_WORK/scratch.img"
SCRATCH_VARS="$QEMU_WORK/vars.fd"
cp "$IMG" "$SCRATCH_IMG"
cp "$OVMF_VARS_TEMPLATE" "$SCRATCH_VARS"

# Fresh swtpm.
if [[ -f "$TPM_WORK/swtpm.pid" ]]; then
    kill "$(cat "$TPM_WORK/swtpm.pid")" 2>/dev/null || true
fi
rm -rf "$TPM_WORK" && mkdir -p "$TPM_WORK"
TPM_SOCK="$TPM_WORK/swtpm-sock"
swtpm socket --tpm2 --tpmstate "dir=$TPM_WORK" \
    --ctrl "type=unixio,path=$TPM_SOCK" \
    --flags not-need-init,startup-clear \
    --log "file=$TPM_WORK/swtpm.log,level=5" \
    --daemon --pid "file=$TPM_WORK/swtpm.pid"
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
    -chardev "socket,id=chrtpm,path=$TPM_SOCK"
    -tpmdev emulator,id=tpm0,chardev=chrtpm
    -device tpm-tis,tpmdev=tpm0
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:18734-:8734"
    -device virtio-net-pci,netdev=net0
)

# Truncate the serial log up front so a failure report only shows
# the current run.
mkdir -p "$OUTDIR" "$(dirname "$LOGFILE")"
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
trap 'kill $QEMUPID 2>/dev/null || true; kill $(cat "$TPM_WORK/swtpm.pid" 2>/dev/null) 2>/dev/null || true' EXIT

if (( GUI )); then
    # GUI mode: hand control to the QEMU window. Do not poll the
    # network port or auto-kill -- the operator wants to
    # watch the splash + interact. Wait for QEMU to exit on its own
    # (window close, Ctrl-C, guest poweroff).
    echo "    waiting for QEMU to exit (close window or Ctrl-C)..."
    wait $QEMUPID 2>/dev/null || true
    kill "$(cat "$TPM_WORK/swtpm.pid" 2>/dev/null)" 2>/dev/null || true
    exit 0
fi

# Poll the forwarded HTTP port until HB answers. The cheap /info
    # endpoint is readiness; /boot is the end-to-end proof.
BASE_URL=http://127.0.0.1:18734
INFO_OUT="$OUTDIR/info.json"
ATT_OUT="$OUTDIR/boot-attestation.json"
PROBE_OUT="$OUTDIR/system.json"
ORACLE_OUT="$OUTDIR/oracle-response.body"
ORACLE_HEADERS="$OUTDIR/oracle.headers"
rm -f "$INFO_OUT" "$ATT_OUT" "$PROBE_OUT" "$ORACLE_OUT" "$ORACLE_HEADERS"

deadline=$((SECONDS + TIMEOUT))
while (( SECONDS < deadline )); do
    if curl -fsSL \
            -H "accept: application/json" \
            -H "accept-bundle: true" \
            "$BASE_URL/~measurement@1.0/info" \
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

echo ">> fetching boot attestation"
if ! curl -fsSL \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        "$BASE_URL/~measurement@1.0/boot" \
        -o "$ATT_OUT"; then
    echo "!! boot-attestation fetch failed from $BASE_URL" >&2
    echo "!! last 80 lines of serial log:" >&2
    tail -80 "$LOGFILE" >&2
    exit 1
fi
if [[ ! -s "$ATT_OUT" ]]; then
    echo "!! empty boot attestation from $BASE_URL" >&2
    exit 1
fi

echo ">> fetching system report"
if ! curl -fsSL \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        "$BASE_URL/~system@1.0/all" \
        -o "$PROBE_OUT"; then
    echo "!! system report fetch failed from $BASE_URL" >&2
    echo "!! last 80 lines of serial log:" >&2
    tail -80 "$LOGFILE" >&2
    exit 1
fi
if [[ ! -s "$PROBE_OUT" ]]; then
    echo "!! empty system report from $BASE_URL" >&2
    exit 1
fi

if [[ -n "$ORACLE_URL" ]]; then
    echo ">> fetching signed oracle response via relay: $ORACLE_URL"
    ORACLE_QUERY=$(
        python3 - "$ORACLE_URL" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
    )
    if ! curl -fsSL \
            -H "accept-bundle: true" \
            -D "$ORACLE_HEADERS" \
            "$BASE_URL/~relay@1.0/call?method=GET&accept-bundle=true&relay-path=$ORACLE_QUERY" \
            -o "$ORACLE_OUT"; then
        echo "!! oracle relay failed from $BASE_URL" >&2
        echo "!! last 80 lines of serial log:" >&2
        tail -80 "$LOGFILE" >&2
        exit 1
    fi
    python3 - "$INFO_OUT" "$ORACLE_HEADERS" "$ORACLE_OUT" <<'PY'
import json
import re
import sys

info_path, headers_path, oracle_path = sys.argv[1:4]

def load(path):
    with open(path, "rb") as f:
        return json.load(f)

def rsa_keyids(msg):
    commitments = msg.get("commitments") or {}
    return {
        c.get("keyid")
        for c in commitments.values()
        if c.get("type") == "rsa-pss-sha512" and c.get("keyid")
    }

info = load(info_path)
headers = open(headers_path, "rb").read().decode("iso-8859-1")
body = open(oracle_path, "rb").read()
node_keyids = rsa_keyids(info)
oracle_keyids = set(re.findall(r'keyid="([^"]+)"', headers, re.I))
if not node_keyids:
    raise SystemExit("info response had no node RSA keyid")
if "signature:" not in headers.lower():
    raise SystemExit("oracle response had no HTTP signature header")
if "signature-input:" not in headers.lower():
    raise SystemExit("oracle response had no HTTP signature-input header")
if not (node_keyids & oracle_keyids):
    raise SystemExit(
        "oracle response was not signed by the same node "
        f"(node={sorted(node_keyids)}, oracle={sorted(oracle_keyids)})"
    )
if not body:
    raise SystemExit("oracle response body was empty")
print(">> oracle response signed by node key:", sorted(node_keyids & oracle_keyids)[0])
PY
fi

kill $QEMUPID 2>/dev/null || true
wait $QEMUPID 2>/dev/null || true
kill "$(cat "$TPM_WORK/swtpm.pid" 2>/dev/null)" 2>/dev/null || true

echo ""
echo "=== QEMU boot test PASSED ==="
ls -lh "$OUTDIR"/
echo ""
echo "Saved boot attestation and system report:"
echo "  $ATT_OUT"
echo "  $PROBE_OUT"
if [[ -n "$ORACLE_URL" ]]; then
    echo "  $ORACLE_HEADERS"
    echo "  $ORACLE_OUT"
fi
echo ""
echo "For physical hardware, prefer the live network path:"
echo "  ./scripts/interpret-local-capture.sh --url http://NODE-IP:8734 --label LABEL"
