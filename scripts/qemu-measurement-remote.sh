#!/usr/bin/env bash
# qemu-measurement-remote.sh -- targetable single-node measurement smoke.
#
# The remote SNP path is intentionally single-node: it proves the signed LapEE
# image boots as an SNP guest, `~measurement@1.0' selects the requested device,
# and boot/fresh/verify can be queried from outside the guest. Green-zone
# multi-node behavior is covered by qemu-green-zone-cluster.sh.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
BUILD_IMAGE=${BUILD_IMAGE:-lapee-build:local}
DOCKER_PLATFORM=${DOCKER_PLATFORM:-}
IMAGE=${IMAGE:-$BUILD_DIR/images/lapee-runtime-no-tme-signed.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-measurement-remote}
TARGET=${TARGET:-local}
MEASUREMENT_DEVICE=${MEASUREMENT_DEVICE:-snp@1.0}
MEASUREMENT_TRACE=${MEASUREMENT_TRACE:-0}
MEASUREMENT_TIMEOUT_MS=${MEASUREMENT_TIMEOUT_MS:-30000}
REMOTE_WORKDIR=${REMOTE_WORKDIR:-/home/hb/lapee-measurement-tests}
REMOTE_PORT=${REMOTE_PORT:-19734}
REMOTE_BIND=${REMOTE_BIND:-127.0.0.1}
REMOTE_QEMU=${REMOTE_QEMU:-/home/hb/hb-os/build/snp-release/usr/local/bin/qemu-system-x86_64}
REMOTE_OVMF=${REMOTE_OVMF:-/home/hb/hb-os/release/DIRECT_BOOT_OVMF.fd}
REMOTE_CBITPOS=${REMOTE_CBITPOS:-51}
REMOTE_MEMORY_MIB=${REMOTE_MEMORY_MIB:-2048}
TIMEOUT=${TIMEOUT:-600}
KEEP_RUNNING=${KEEP_RUNNING:-0}

usage() {
    cat >&2 <<EOF
usage:
  TARGET=ssh://hb@dev-1.forward.computer \\
  IMAGE=build/images/lapee-runtime-no-tme-signed.img \\
  MEASUREMENT_DEVICE=snp@1.0 \\
  ./scripts/qemu-measurement-remote.sh
EOF
}

while (($# > 0)); do
    case "$1" in
        --target) TARGET=$2; shift 2;;
        --image) IMAGE=$2; shift 2;;
        --measurement-device) MEASUREMENT_DEVICE=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --keep-running) KEEP_RUNNING=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage; exit 2;;
    esac
done

[[ -f "$IMAGE" ]] || { echo "missing image: $IMAGE" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "missing docker" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "missing jq" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "missing ssh" >&2; exit 1; }
command -v scp >/dev/null 2>&1 || { echo "missing scp" >&2; exit 1; }

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

prepare_image() {
    local dst="$OUTDIR/measurement-disk.img"
    local cfg="$OUTDIR/config.json"
    local trace_json=false
    [[ "$MEASUREMENT_TRACE" == "1" ]] && trace_json=true
    cp "$IMAGE" "$dst"
    jq -n \
        --arg device "$MEASUREMENT_DEVICE" \
        --argjson trace "$trace_json" \
        --argjson measurement_timeout_ms "$MEASUREMENT_TIMEOUT_MS" '
        {
          "peer-http-connect-timeout-ms": 600000,
          "peer-http-timeout-ms": 600000,
          "measurement-timeout-ms": $measurement_timeout_ms
        }
        + (if $trace then {"measurement-trace": true} else {} end)
        + (if $device == "auto" then {} else {"measurement-device": $device} end)
    ' > "$cfg"
    docker run --rm $DOCKER_PLATFORM \
        -v "$OUTDIR":/work \
        -w /work \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c '
            START=$(parted --script --machine /work/measurement-disk.img \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$2); print \$2}")
            SECT=$(parted --script --machine /work/measurement-disk.img \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$4); print \$4}")
            dd if=/work/measurement-disk.img of=/tmp/esp.img \
                bs=512 skip=$START count=$SECT status=none
            mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true
            mcopy -i /tmp/esp.img -o /work/config.json ::/EFI/boot/config.json
            dd if=/tmp/esp.img of=/work/measurement-disk.img \
                bs=512 seek=$START count=$SECT conv=notrunc status=none
        '
    echo "$dst"
}

remote_host() {
    case "$TARGET" in
        ssh://*) printf '%s\n' "${TARGET#ssh://}";;
        local) echo "local target is not implemented by this SNP runner" >&2; exit 2;;
        *) echo "TARGET must be local or ssh://user@host" >&2; exit 2;;
    esac
}

remote_run() {
    local host=$1
    local disk=$2
    local remote_dir=$REMOTE_WORKDIR
    local remote_disk="$remote_dir/measurement-disk.img"

    ssh "$host" "mkdir -p '$remote_dir'"
    scp "$disk" "$host:$remote_disk" >/dev/null
    ssh "$host" "cat > '$remote_dir/run-snp-node.sh'" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

cmd=${1:?start|stop|status}
workdir=${2:?workdir}
port=${3:?port}
qemu=${4:?qemu}
ovmf=${5:?ovmf}
cbitpos=${6:?cbitpos}
memory_mib=${7:?memory}
bind_addr=${8:?bind-address}

pidfile="$workdir/qemu.pid"
monitor="$workdir/qemu.mon"
serial="$workdir/serial.log"
disk="$workdir/measurement-disk.img"

stop_node() {
    if [[ -S "$monitor" ]]; then
        python3 - "$monitor" 2>/dev/null <<'PY' || true
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2)
s.connect(sys.argv[1])
s.sendall(b"quit\n")
s.close()
PY
    fi
    if [[ -s "$pidfile" ]]; then
        sudo kill "$(cat "$pidfile")" 2>/dev/null || true
        for _ in $(seq 1 50); do
            sudo kill -0 "$(cat "$pidfile")" 2>/dev/null || break
            sleep 0.2
        done
        sudo kill -KILL "$(cat "$pidfile")" 2>/dev/null || true
    fi
    rm -f "$pidfile" "$monitor"
}

case "$cmd" in
    stop)
        stop_node
        ;;
    status)
        if [[ -s "$pidfile" ]] && sudo kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            echo running
        else
            echo stopped
        fi
        ;;
    start)
        stop_node
        rm -f "$serial" "$monitor"
        sudo "$qemu" \
            -enable-kvm \
            -cpu EPYC-v4 \
            -machine q35,memory-encryption=sev0,vmport=off \
            -m "${memory_mib}M" \
            -smp 2,maxcpus=2 \
            -object "memory-backend-memfd,id=ram1,size=${memory_mib}M,share=true,prealloc=false" \
            -machine memory-backend=ram1 \
            -object "sev-snp-guest,id=sev0,policy=0x30000,cbitpos=${cbitpos},reduced-phys-bits=1" \
            -bios "$ovmf" \
            -drive "file=$disk,if=none,id=disk0,format=raw" \
            -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true \
            -device scsi-hd,drive=disk0,bootindex=1 \
            -netdev "user,id=net0,hostfwd=tcp:${bind_addr}:${port}-:8734" \
            -device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=net0,romfile= \
            -monitor "unix:$monitor,server,nowait" \
            -serial "file:$serial" \
            -display none \
            -no-reboot \
            > "$workdir/qemu.log" 2>&1 &
        echo $! > "$pidfile"
        ;;
    *)
        echo "unknown command: $cmd" >&2
        exit 2
        ;;
esac
REMOTE
    ssh "$host" "chmod +x '$remote_dir/run-snp-node.sh'"
    ssh "$host" \
        "'$remote_dir/run-snp-node.sh' start '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'"

    local deadline=$((SECONDS + TIMEOUT))
    until ssh "$host" \
            "curl --max-time 10 -fsS 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/info' >/dev/null 2>/dev/null"
    do
        if (( SECONDS >= deadline )); then
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-timeout.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            echo "timed out waiting for remote node; serial: $OUTDIR/serial-timeout.log" >&2
            exit 1
        fi
        sleep 2
    done

    ssh "$host" "curl --max-time 120 -fsS 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/info?accept=application/json&accept-bundle=true'" \
        > "$OUTDIR/info.json" || {
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-info-failed.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            exit 1
        }
    ssh "$host" "curl --max-time 120 -fsS 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/boot?accept=application/json&accept-bundle=true'" \
        > "$OUTDIR/boot.json" || {
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-boot-failed.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            exit 1
        }
    local nonce
    nonce=$(printf 'lapee-remote-snp-%s' "$(date +%s)" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    ssh "$host" "curl --max-time 120 -fsS 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/fresh?nonce=$nonce&accept=application/json&accept-bundle=true'" \
        > "$OUTDIR/fresh.json" || {
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-fresh-failed.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            exit 1
        }
    jq -e --arg device "$MEASUREMENT_DEVICE" '
        .body."selected-measurement-device" == $device
            or (.body."selected-measurement-device" == "snp@1.0" and $device == "auto")
    ' "$OUTDIR/info.json" >/dev/null
    jq -e '.body."measurement-device" == "snp@1.0"' "$OUTDIR/boot.json" >/dev/null
    jq -e '.body."measurement-device" == "snp@1.0"' "$OUTDIR/fresh.json" >/dev/null
    ssh "$host" "curl --max-time 120 -fsS -X POST -H 'content-type: application/json' 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/verify?accept=application/json&accept-bundle=true' --data-binary @-" \
        < "$OUTDIR/boot.json" > "$OUTDIR/verify-boot.json" || {
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-verify-boot-failed.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            exit 1
        }
    local fresh_nonce
    fresh_nonce=$(jq -r '.body.evidence.nonce' "$OUTDIR/fresh.json")
    ssh "$host" "curl --max-time 120 -fsS -X POST -H 'content-type: application/json' 'http://127.0.0.1:$REMOTE_PORT/~measurement@1.0/verify?nonce=$fresh_nonce&accept=application/json&accept-bundle=true' --data-binary @-" \
        < "$OUTDIR/fresh.json" > "$OUTDIR/verify-fresh.json" || {
            ssh "$host" "tail -200 '$remote_dir/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/serial-verify-fresh-failed.log" || true
            ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
            exit 1
        }
    jq -e '(.body.verified == true or .body.verified == "true")
        and .body.verdict == "accepted"' \
        "$OUTDIR/verify-boot.json" >/dev/null
    jq -e '(.body.verified == true or .body.verified == "true")
        and .body.verdict == "accepted"' \
        "$OUTDIR/verify-fresh.json" >/dev/null

    if [[ "$KEEP_RUNNING" != "1" ]]; then
        ssh "$host" "'$remote_dir/run-snp-node.sh' stop '$remote_dir' '$REMOTE_PORT' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$REMOTE_BIND'" || true
    fi
}

DISK=$(prepare_image)
HOST=$(remote_host)
remote_run "$HOST" "$DISK"

echo "=== remote measurement smoke PASSED ==="
echo "target: $TARGET"
echo "out: $OUTDIR"
