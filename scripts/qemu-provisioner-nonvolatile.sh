#!/usr/bin/env bash
# qemu-provisioner-nonvolatile.sh -- destructive-storage prompt smoke test.
#
# Boots the Secure Boot provisioner image under QEMU with one sacrificial extra
# disk, types the real confirmation strings through QMP keyboard events, and
# verifies that the extra disk receives a GPT partition named
# GREENZONE_test-zone. OVMF is not expected to be in real firmware Setup Mode
# in this harness; the Secure Boot enrollment may fail after the storage step.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
IMG=${IMG:-$BUILD_DIR/images/lapee-sb-provisioner.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-provisioner-nonvolatile}
TIMEOUT=${TIMEOUT:-240}
DISK_SIZE_MIB=${DISK_SIZE_MIB:-64}

while (($# > 0)); do
    case "$1" in
        --img) IMG=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

find_ovmf() {
    for p in "$@"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}

OVMF_CODE=${OVMF_CODE:-$(find_ovmf \
    /opt/homebrew/opt/qemu/share/qemu/edk2-x86_64-code.fd \
    /usr/local/share/qemu/edk2-x86_64-code.fd \
    /usr/share/qemu/edk2-x86_64-code.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/x64/OVMF_CODE.fd || true)}
OVMF_VARS_TEMPLATE=${OVMF_VARS_TEMPLATE:-$(find_ovmf \
    /opt/homebrew/opt/qemu/share/qemu/edk2-i386-vars.fd \
    /usr/local/share/qemu/edk2-i386-vars.fd \
    /usr/share/qemu/edk2-i386-vars.fd \
    /usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/OVMF/OVMF_VARS.fd \
    /usr/share/edk2/x64/OVMF_VARS.fd || true)}

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "missing qemu-system-x86_64" >&2; exit 1; }
[[ -f "$OVMF_CODE" ]] || { echo "missing OVMF_CODE: $OVMF_CODE" >&2; exit 1; }
[[ -f "$OVMF_VARS_TEMPLATE" ]] || {
    echo "missing OVMF_VARS_TEMPLATE: $OVMF_VARS_TEMPLATE" >&2; exit 1; }

if [[ ! -f "$IMG" ]]; then
    echo ">> building provisioner image: $IMG"
    make provisioner-image
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"
cp "$IMG" "$OUTDIR/provisioner.img"
cp "$OVMF_VARS_TEMPLATE" "$OUTDIR/vars.fd"
truncate -s "${DISK_SIZE_MIB}M" "$OUTDIR/nonvolatile.img"

QMP="$OUTDIR/qmp.sock"
SERIAL="$OUTDIR/serial.log"
qemu_pid=
cleanup() {
    if [[ -n "${qemu_pid:-}" ]]; then
        kill "$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

qemu-system-x86_64 \
    -machine q35,accel=tcg \
    -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx \
    -m 2048 \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$OUTDIR/vars.fd" \
    -drive "file=$OUTDIR/provisioner.img,format=raw,if=virtio" \
    -drive "file=$OUTDIR/nonvolatile.img,format=raw,if=virtio" \
    -qmp "unix:$QMP,server=on,wait=off" \
    -nographic \
    > "$SERIAL" 2>&1 &
qemu_pid=$!

wait_log() {
    local pattern=$1
    local deadline=$((SECONDS + TIMEOUT))
    while ((SECONDS < deadline)); do
        if LC_ALL=C grep -a -q "$pattern" "$SERIAL" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for: $pattern" >&2
    tail -160 "$SERIAL" >&2 || true
    return 1
}

type_qemu() {
    python3 - "$QMP" "$1" <<'PY'
import json, socket, sys, time

sock_path, text = sys.argv[1], sys.argv[2]
special = {" ": "spc", ".": "dot", "-": "minus", "_": "shift-minus",
           ">": "shift-dot",
           "\n": "ret", "\r": "ret"}

def key_for(ch):
    if ch in special:
        return special[ch]
    if ch.isalpha():
        return ("shift-" if ch.isupper() else "") + ch.lower()
    if ch.isdigit():
        return ch
    raise SystemExit(f"no QEMU key mapping for {ch!r}")

def recv_some(sock):
    sock.settimeout(1)
    try:
        return sock.recv(4096)
    except TimeoutError:
        return b""

sock = socket.socket(socket.AF_UNIX)
sock.connect(sock_path)
recv_some(sock)
sock.sendall(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
recv_some(sock)
for ch in text:
    sock.sendall(json.dumps({
        "execute": "human-monitor-command",
        "arguments": {"command-line": "sendkey " + key_for(ch)}
    }).encode() + b"\n")
    recv_some(sock)
    time.sleep(0.06)
PY
}

wait_log "Found provisioning bundle"
type_qemu $'I UNDERSTAND.\n'
wait_log "Non-volatile storage selection is ready"
type_qemu $'DESTROY 1 -> test-zone\n'
wait_log "Prepared /dev/vdb1 as GREENZONE_test-zone"

python3 - "$OUTDIR/nonvolatile.img" <<'PY'
import struct, sys

marker = b"LapEE nonvolatile provisioning marker v1\n"

with open(sys.argv[1], "rb") as f:
    f.seek(512)
    header = f.read(512)
    if header[:8] != b"EFI PART":
        raise SystemExit("missing GPT header")
    entries_lba = struct.unpack_from("<Q", header, 72)[0]
    entries = struct.unpack_from("<I", header, 80)[0]
    entry_size = struct.unpack_from("<I", header, 84)[0]
    f.seek(entries_lba * 512)
    for _ in range(entries):
        entry = f.read(entry_size)
        if entry[:16] == b"\0" * 16:
            continue
        name = entry[56:128].decode("utf-16le").rstrip("\0")
        if name == "GREENZONE_test-zone":
            first_lba = struct.unpack_from("<Q", entry, 32)[0]
            f.seek(first_lba * 512)
            if f.read(len(marker)) != marker:
                raise SystemExit("missing LapEE nonvolatile marker")
            print("found GREENZONE_test-zone partition")
            raise SystemExit(0)
raise SystemExit("GREENZONE_test-zone partition not found")
PY

echo "=== provisioner non-volatile QEMU smoke PASSED ==="
echo "out: $OUTDIR"
