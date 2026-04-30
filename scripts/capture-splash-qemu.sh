#!/usr/bin/env bash
# Capture framebuffer screenshots from LapEE splash image variants.

set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: scripts/capture-splash-qemu.sh

Environment overrides:
  BUILD_DIR=build/splash-builds/<label> Directory containing lapee-usb-<layout>.img
  OUTDIR=build/splash-captures/<label>  Capture output directory
  LAYOUTS="qr max deck ..."             Layouts to boot and capture
  CAPTURE_SECONDS="30 75 120"           Seconds after QEMU launch to capture
  QEMU_TIMEOUT=180                      Per-layout hard stop in seconds

Each layout gets:
  <layout>/<layout>-<seconds>s.ppm
  <layout>/<layout>-<seconds>s.png      if `sips' is available
  <layout>/serial.log
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [ -z "${BUILD_DIR:-}" ]; then
    if [ -f build/splash-builds/LATEST ]; then
        BUILD_DIR=$(cat build/splash-builds/LATEST)
    else
        BUILD_DIR=build/splash-builds
    fi
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="${OUTDIR:-build/splash-captures/overnight-$timestamp}"
LAYOUTS="${LAYOUTS:-qr max deck sigil blue orbit matrix plaque classic}"
CAPTURE_SECONDS="${CAPTURE_SECONDS:-30 75 120}"
QEMU_TIMEOUT="${QEMU_TIMEOUT:-180}"

find_ovmf() {
    for path in "$@"; do
        [ -f "$path" ] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
}

OVMF_CODE="${OVMF_CODE:-}"
OVMF_VARS_TEMPLATE="${OVMF_VARS_TEMPLATE:-}"
if [ -z "$OVMF_CODE" ]; then
    OVMF_CODE=$(find_ovmf \
        /opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd \
        /usr/local/share/qemu/edk2-x86_64-code.fd \
        /usr/share/qemu/edk2-x86_64-code.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd || true)
fi
if [ -z "$OVMF_VARS_TEMPLATE" ]; then
    OVMF_VARS_TEMPLATE=$(find_ovmf \
        /opt/homebrew/opt/qemu/share/qemu/edk2-i386-vars.fd \
        /usr/local/share/qemu/edk2-i386-vars.fd \
        /usr/share/qemu/edk2-i386-vars.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/x64/OVMF_VARS.fd || true)
fi

[ -f "$OVMF_CODE" ] || { echo "missing OVMF_CODE (set env override)" >&2; exit 1; }
[ -f "$OVMF_VARS_TEMPLATE" ] || { echo "missing OVMF_VARS_TEMPLATE (set env override)" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo "missing qemu-system-x86_64" >&2; exit 1; }
command -v swtpm >/dev/null 2>&1 || { echo "missing swtpm" >&2; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "missing nc" >&2; exit 1; }

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
mkdir -p build/splash-captures
echo "$OUTDIR" > build/splash-captures/LATEST

abs_build_dir="$(cd "$BUILD_DIR" && pwd)"

send_hmp() {
    local mon="$1"
    local cmd="$2"
    printf '%s\n' "$cmd" | nc -U -w 1 "$mon" >/dev/null
}

wait_for_monitor() {
    local mon="$1"
    local deadline=$((SECONDS + 20))
    while [ ! -S "$mon" ]; do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        sleep 0.2
    done
}

cleanup_one() {
    local qpid="${1:-}"
    local tpm_pid_file="${2:-}"
    if [ -n "$qpid" ]; then
        kill "$qpid" 2>/dev/null || true
        wait "$qpid" 2>/dev/null || true
    fi
    if [ -n "$tpm_pid_file" ] && [ -f "$tpm_pid_file" ]; then
        kill "$(cat "$tpm_pid_file")" 2>/dev/null || true
    fi
}

capture_layout() {
    local layout="$1"
    local img="$abs_build_dir/lapee-usb-$layout.img"
    [ -f "$img" ] || { echo "missing image for layout '$layout': $img" >&2; return 1; }

    local layout_out="$OUTDIR/$layout"
    local scratch_dir="build/qemu-splash-capture/$layout"
    local scratch_img="$scratch_dir/scratch.img"
    local scratch_vars="$scratch_dir/vars.fd"
    local tpm_dir="$scratch_dir/tpm"
    local tpm_pid="$tpm_dir/swtpm.pid"
    local tpm_sock="$tpm_dir/swtpm-sock"
    local mon="$scratch_dir/hmp.sock"
    local serial="$layout_out/serial.log"

    echo "=== capture $layout ==="
    rm -rf "$scratch_dir"
    mkdir -p "$scratch_dir" "$tpm_dir" "$layout_out"
    cp "$img" "$scratch_img"
    cp "$OVMF_VARS_TEMPLATE" "$scratch_vars"
    : > "$serial"

    swtpm socket --tpm2 --tpmstate "dir=$tpm_dir" \
        --ctrl "type=unixio,path=$tpm_sock" \
        --flags not-need-init,startup-clear \
        --log "file=$tpm_dir/swtpm.log,level=5" \
        --daemon --pid "file=$tpm_pid"

    qemu-system-x86_64 \
        -machine q35,accel=tcg \
        -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx \
        -m 2048 -smp 4 \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$scratch_vars" \
        -drive "file=$scratch_img,format=raw,if=virtio" \
        -chardev "socket,id=chrtpm,path=$tpm_sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev "user,id=net0" \
        -device virtio-net-pci,netdev=net0 \
        -display none -vga std \
        -monitor "unix:$mon,server=on,wait=off" \
        -serial "file:$serial" &
    local qpid=$!

    trap 'cleanup_one "$qpid" "$tpm_pid"' RETURN
    wait_for_monitor "$mon" || {
        echo "monitor did not appear for $layout" >&2
        cleanup_one "$qpid" "$tpm_pid"
        return 1
    }

    local last=0
    for at in $CAPTURE_SECONDS; do
        if [ "$at" -gt "$QEMU_TIMEOUT" ]; then
            echo "skipping ${at}s for $layout; exceeds QEMU_TIMEOUT=$QEMU_TIMEOUT" >&2
            break
        fi
        if ! kill -0 "$qpid" 2>/dev/null; then
            echo "qemu exited before ${at}s for $layout" >&2
            break
        fi
        if [ "$at" -gt "$last" ]; then
            sleep $((at - last))
        fi
        last="$at"
        local ppm="$layout_out/$layout-${at}s.ppm"
        local png="$layout_out/$layout-${at}s.png"
        send_hmp "$mon" "screendump $ppm"
        if command -v sips >/dev/null 2>&1; then
            sips -s format png "$ppm" --out "$png" >/dev/null
        fi
        echo "$png"
    done

    send_hmp "$mon" "quit" || true
    cleanup_one "$qpid" "$tpm_pid"
    trap - RETURN

    if ls "$layout_out"/"$layout"-*s.png >/dev/null 2>&1 || \
       ls "$layout_out"/"$layout"-*s.ppm >/dev/null 2>&1; then
        echo "capture: ok" > "$layout_out/status.txt"
    else
        echo "capture: no-frame" > "$layout_out/status.txt"
    fi
}

for layout in $LAYOUTS; do
    capture_layout "$layout"
done

echo "Captured splash screenshots under $OUTDIR"
