#!/usr/bin/env bash
# qemu-green-zone-cluster.sh -- four-node measurement/green-zone harness.
#
# The harness boots three admissible LapEE nodes and one inadmissible node
# under QEMU+OVMF+swtpm. The nodes intentionally vary observable system
# properties. The three admitted nodes share the template-matched DMI product;
# node 4 carries a different boot-attested DMI product. Each swtpm is
# manufactured with a local EK certificate so `~measurement@1.0/verify-peer'
# can exercise the real TPM MakeCredential/ActivateCredential path instead of
# a no-cert shortcut.
#
# Acceptance checked here:
#   * all four nodes answer `~measurement@1.0/boot'
#   * node 1 initializes a named green-zone template from its system report
#   * nodes 2 and 3 join through node 1 and receive the shared ring wallet
#   * node 4 has a different DMI product and is rejected by the same template
#   * nodes 1-3 install the same green-zone identity
#   * node 4 never receives that identity
#
# With NONVOLATILE=1, each node also receives a second virtio disk containing
# a single GPT partition named GREENZONE_PRIMARY. Nodes 1-3 must format/open
# it with the green-zone key, mount it as the primary HB store, and node 2 is
# rebooted and rejoined to prove the existing encrypted volume is reused.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
BUILD_IMAGE=${BUILD_IMAGE:-lapee-build:local}
DOCKER_PLATFORM=${DOCKER_PLATFORM:-}
IMG=${IMG:-$BUILD_DIR/images/lapee-runtime-no-tme-signed.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-green-zone}
BASE_PORT=${BASE_PORT:-19080}
TIMEOUT=${TIMEOUT:-480}
KEEP_RUNNING=${KEEP_RUNNING:-0}
SWTPM_LOCALCA_OPTIONS=${SWTPM_LOCALCA_OPTIONS:-/opt/homebrew/etc/swtpm-localca.options}
GUEST_HOST=${GUEST_HOST:-$(ipconfig getifaddr en0 2>/dev/null || echo 10.0.2.2)}
NODE1_MEMORY_MIB=${NODE1_MEMORY_MIB:-2048}
NODE2_MEMORY_MIB=${NODE2_MEMORY_MIB:-2304}
NODE3_MEMORY_MIB=${NODE3_MEMORY_MIB:-2560}
NODE4_MEMORY_MIB=${NODE4_MEMORY_MIB:-2816}
NODE1_DMI_PRODUCT=${NODE1_DMI_PRODUCT:-LapEE-GZ-admit}
NODE2_DMI_PRODUCT=${NODE2_DMI_PRODUCT:-LapEE-GZ-admit}
NODE3_DMI_PRODUCT=${NODE3_DMI_PRODUCT:-LapEE-GZ-admit}
NODE4_DMI_PRODUCT=${NODE4_DMI_PRODUCT:-LapEE-GZ-reject-4}
SWTPM_CTRL=${SWTPM_CTRL:-unix}
SWTPM_CTRL_BASE_PORT=${SWTPM_CTRL_BASE_PORT:-$((BASE_PORT + 1000))}
NONVOLATILE=${NONVOLATILE:-0}
NONVOLATILE_SIZE_MIB=${NONVOLATILE_SIZE_MIB:-768}
MEASUREMENT_DEVICE=${MEASUREMENT_DEVICE:-auto}
NODE1_MEASUREMENT_DEVICE=${NODE1_MEASUREMENT_DEVICE:-$MEASUREMENT_DEVICE}
NODE2_MEASUREMENT_DEVICE=${NODE2_MEASUREMENT_DEVICE:-$MEASUREMENT_DEVICE}
NODE3_MEASUREMENT_DEVICE=${NODE3_MEASUREMENT_DEVICE:-$MEASUREMENT_DEVICE}
NODE4_MEASUREMENT_DEVICE=${NODE4_MEASUREMENT_DEVICE:-$MEASUREMENT_DEVICE}
GREEN_ZONE_TEMPLATE_MODE=${GREEN_ZONE_TEMPLATE_MODE:-device}

while (($# > 0)); do
    case "$1" in
        --img) IMG=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --base-port) BASE_PORT=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --measurement-device) MEASUREMENT_DEVICE=$2; shift 2;;
        --keep-running) KEEP_RUNNING=1; shift;;
        *) echo "unknown arg: $1" >&2; exit 2;;
    esac
done

command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    echo "missing qemu-system-x86_64" >&2; exit 1; }
command -v swtpm >/dev/null 2>&1 || { echo "missing swtpm" >&2; exit 1; }
command -v swtpm_setup >/dev/null 2>&1 || {
    echo "missing swtpm_setup" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "missing jq" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "missing docker" >&2; exit 1; }

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
[[ -f "$OVMF_CODE" ]] || { echo "missing OVMF_CODE: $OVMF_CODE" >&2; exit 1; }
[[ -f "$OVMF_VARS_TEMPLATE" ]] || {
    echo "missing OVMF_VARS_TEMPLATE: $OVMF_VARS_TEMPLATE" >&2; exit 1; }

if [[ ! -f "$IMG" ]]; then
    echo ">> building signed no-TME image: $IMG"
    make runtime-image TME=0 WIFI=0 RUNTIME_SIGNED_OUT="$IMG"
fi
rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"/{ca,nodes,requests,responses}
OUTDIR="$(cd "$OUTDIR" && pwd)"

node_measurement_device() {
    local n=$1
    case "$n" in
        1) echo "$NODE1_MEASUREMENT_DEVICE";;
        2) echo "$NODE2_MEASUREMENT_DEVICE";;
        3) echo "$NODE3_MEASUREMENT_DEVICE";;
        4) echo "$NODE4_MEASUREMENT_DEVICE";;
        *) echo "$MEASUREMENT_DEVICE";;
    esac
}

expected_node_measurement_device() {
    case "$(node_measurement_device "$1")" in
        auto) echo "tpm@2.0a";;
        *) node_measurement_device "$1";;
    esac
}

prepare_qemu_image() {
    local src="${1:?source image required}"
    local dst="${2:?destination image required}"
    local device="${3:?measurement device required}"
    local cfg="$OUTDIR/qemu-config.json"
    local dst_rel="${dst#$OUTDIR/}"
    cp "$src" "$dst"
    python3 - \
        "buildroot-external/board/lapee/rootfs-overlay/etc/lapee/lapee.json" \
        "$cfg" "$device" <<'PY'
import json, pathlib, sys

base = json.loads(pathlib.Path(sys.argv[1]).read_text())
cfg = {
    "lapee_allow_request_trusted_ca": True,
    "peer-http-connect-timeout-ms": 600000,
    "peer-http-timeout-ms": 600000,
}
device = sys.argv[3]
if device != "auto":
    cfg["measurement-device"] = device
if device == "snp-mock@1.0":
    preloaded = list(base["preloaded_devices"])
    preloaded.append({
        "name": "snp-mock@1.0",
        "module": "dev_snp_mock",
        "ao-types": "module=\"atom\"",
    })
    cfg["preloaded_devices"] = preloaded
pathlib.Path(sys.argv[2]).write_text(json.dumps(cfg))
PY
    docker run --rm $DOCKER_PLATFORM \
        -v "$OUTDIR":/work \
        -w /work \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c '
            DISK="/work/$1"
            START=$(parted --script --machine "$DISK" \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$2); print \$2}")
            SECT=$(parted --script --machine "$DISK" \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$4); print \$4}")
            dd if="$DISK" of=/tmp/esp.img \
                bs=512 skip=$START count=$SECT status=none
            mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true
            mcopy -i /tmp/esp.img -o /work/qemu-config.json \
                ::/EFI/boot/config.json
            dd if=/tmp/esp.img of="$DISK" \
                bs=512 seek=$START count=$SECT conv=notrunc status=none
        ' bash "$dst_rel"
    echo "$dst"
}

# AF_UNIX sun_path is 104 bytes on macOS / 108 on Linux. Worktree-rooted
# OUTDIRs blow that limit, so swtpm's `--ctrl type=unixio,path=...' fails
# opaquely with "Path for UnioIO socket is too long". Stage the sockets
# in a short /tmp dir and keep state/logs/certs in OUTDIR.
SOCK_DIR=$(mktemp -d /tmp/lapee-gz.XXXXXX)

echo "=== green-zone QEMU cluster ==="
echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git status --short 2>/dev/null || true
echo "qemu: $(qemu-system-x86_64 --version | head -n 1)"
echo "swtpm: $(swtpm --version | head -n 1)"
echo "guest-host: $GUEST_HOST"
echo "base-port: $BASE_PORT"
echo "outdir: $OUTDIR"
echo "qemu image: $IMG"
echo "measurement devices: $(node_measurement_device 1), $(node_measurement_device 2), $(node_measurement_device 3), $(node_measurement_device 4)"
echo "green-zone template mode: $GREEN_ZONE_TEMPLATE_MODE"
echo "nonvolatile: $NONVOLATILE"
ls -lhT "$IMG" 2>/dev/null || ls -lh "$IMG"

cat > "$OUTDIR/localca.conf" <<EOF
statedir = $OUTDIR/ca
signingkey = $OUTDIR/ca/signkey.pem
issuercert = $OUTDIR/ca/issuercert.pem
certserial = $OUTDIR/ca/certserial
EOF
cat > "$OUTDIR/setup.conf" <<EOF
create_certs_tool= $(command -v swtpm_localca)
create_certs_tool_config = $OUTDIR/localca.conf
create_certs_tool_options = $SWTPM_LOCALCA_OPTIONS
active_pcr_banks = sha256
rsa_keysize = 2048
profile = {"Name": "default-v1"}
local_profiles_dir = $OUTDIR/profiles
EOF

pids=()
tpm_pids=()
cleanup() {
    if [[ "$KEEP_RUNNING" = "1" ]]; then
        echo ">> KEEP_RUNNING=1; leaving QEMU nodes up"
        return
    fi
    for pid in "${pids[@]+"${pids[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${tpm_pids[@]+"${tpm_pids[@]}"}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$SOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

pid_state() {
    ps -p "$1" -o stat= 2>/dev/null | tr -d '[:space:]' || true
}

terminate_pid() {
    local pid="${1:?pid required}"
    local label="${2:-process}"
    kill "$pid" 2>/dev/null || return 0
    for _ in $(seq 1 50); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        case "$(pid_state "$pid")" in
            Z*) wait "$pid" 2>/dev/null || true; return 0;;
        esac
        sleep 0.2
    done
    echo "!! $label pid $pid did not stop after SIGTERM; killing" >&2
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

request_qemu_quit() {
    local socket=$1
    [[ -S "$socket" ]] || return 0
    python3 - "$socket" <<'PY' || true
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(sys.argv[1])
sock.sendall(b"quit\n")
sock.close()
PY
}

stop_node() {
    local n=$1
    local node_dir="$OUTDIR/nodes/node$n"
    if [[ -s "$node_dir/qemu.pid" ]]; then
        request_qemu_quit "$SOCK_DIR/qemu$n.mon"
        terminate_pid "$(cat "$node_dir/qemu.pid")" "node $n qemu"
        rm -f "$node_dir/qemu.pid"
    fi
    if [[ -s "$node_dir/tpm/swtpm.pid" ]]; then
        terminate_pid "$(cat "$node_dir/tpm/swtpm.pid")" "node $n swtpm"
        rm -f "$node_dir/tpm/swtpm.pid"
    fi
    rm -f "$SOCK_DIR/tpm$n.sock"
    sleep 1
}

node_host_url() {
    local n=$1
    printf 'http://127.0.0.1:%d' "$((BASE_PORT + n))"
}

node_guest_url() {
    local n=$1
    printf 'http://%s:%d' "$GUEST_HOST" "$((BASE_PORT + n))"
}

node_memory_mib() {
    local n=$1
    case "$n" in
        1) echo "$NODE1_MEMORY_MIB";;
        2) echo "$NODE2_MEMORY_MIB";;
        3) echo "$NODE3_MEMORY_MIB";;
        4) echo "$NODE4_MEMORY_MIB";;
        *) echo "2048";;
    esac
}

node_dmi_product() {
    local n=$1
    case "$n" in
        1) echo "$NODE1_DMI_PRODUCT";;
        2) echo "$NODE2_DMI_PRODUCT";;
        3) echo "$NODE3_DMI_PRODUCT";;
        4) echo "$NODE4_DMI_PRODUCT";;
        *) echo "LapEE-GZ-node-$n";;
    esac
}

manufacture_tpm() {
    local n=$1
    local dir="$OUTDIR/nodes/node$n/tpm"
    mkdir -p "$dir/certs" "$dir/state"
    swtpm_setup \
        --tpm2 \
        --tpm-state "dir://$dir/state" \
        --createek \
        --create-ek-cert \
        --lock-nvram \
        --config "$OUTDIR/setup.conf" \
        --write-ek-cert-files "$dir/certs" \
        --overwrite \
        > "$dir/setup.log" 2>&1
}

prepare_nonvolatile_disk() {
    local n=$1
    local node_dir="$OUTDIR/nodes/node$n"
    local disk="$node_dir/nonvolatile.img"
    truncate -s "${NONVOLATILE_SIZE_MIB}M" "$disk"
    docker run --rm $DOCKER_PLATFORM \
        -v "$node_dir":/work \
        -w /work \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c '
            parted -s /work/nonvolatile.img mklabel gpt \
                mkpart GREENZONE_PRIMARY 1MiB 100%
        '
    python3 - "$disk" <<'PY'
import struct, sys

marker = b"LapEE nonvolatile provisioning marker v1\n"
with open(sys.argv[1], "r+b") as f:
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
        if entry[56:128].decode("utf-16le").rstrip("\0") == "GREENZONE_PRIMARY":
            first_lba = struct.unpack_from("<Q", entry, 32)[0]
            f.seek(first_lba * 512)
            f.write(marker)
            raise SystemExit(0)
raise SystemExit("GREENZONE_PRIMARY partition not found")
PY
}

rename_nonvolatile_disk_label() {
    local n=$1
    local label=$2
    local node_dir="$OUTDIR/nodes/node$n"
    docker run --rm $DOCKER_PLATFORM \
        -v "$node_dir":/work \
        -w /work \
        "$BUILD_IMAGE" \
        parted -s /work/nonvolatile.img name 1 "$label"
}

start_node() {
    local n=$1
    local img=$2
    local fresh=${3:-1}
    local node_dir="$OUTDIR/nodes/node$n"
    local port=$((BASE_PORT + n))
    mkdir -p "$node_dir"
    if [[ "$fresh" = "1" ]]; then
        prepare_qemu_image \
            "$img" \
            "$node_dir/disk.img" \
            "$(node_measurement_device "$n")" >/dev/null
        cp "$OVMF_VARS_TEMPLATE" "$node_dir/vars.fd"
        manufacture_tpm "$n"
        if [[ "$NONVOLATILE" = "1" ]]; then
            prepare_nonvolatile_disk "$n"
        fi
    fi
    local sock="$SOCK_DIR/tpm$n.sock"
    local monitor="$SOCK_DIR/qemu$n.mon"
    local memory_mib
    memory_mib=$(node_memory_mib "$n")
    local dmi_product
    dmi_product=$(node_dmi_product "$n")
    local swtpm_ctrl qemu_chardev
    case "$SWTPM_CTRL" in
        tcp)
            local tpm_port=$((SWTPM_CTRL_BASE_PORT + n))
            swtpm_ctrl="type=tcp,bindaddr=127.0.0.1,port=$tpm_port"
            qemu_chardev="socket,id=chrtpm,host=127.0.0.1,port=$tpm_port"
            ;;
        unix)
            swtpm_ctrl="type=unixio,path=$sock"
            qemu_chardev="socket,id=chrtpm,path=$sock"
            ;;
        *)
            echo "unknown SWTPM_CTRL: $SWTPM_CTRL" >&2
            return 1
            ;;
    esac
    if ! swtpm socket --tpm2 --tpmstate "dir=$node_dir/tpm/state" \
        --ctrl "$swtpm_ctrl" \
        --flags not-need-init,startup-clear \
        --log "file=$node_dir/tpm/swtpm.log,level=5" \
        --daemon --pid "file=$node_dir/tpm/swtpm.pid"; then
        echo "!! swtpm failed for node $n" >&2
        cat "$node_dir/tpm/swtpm.log" >&2 || true
        return 1
    fi
    tpm_pids+=("$(cat "$node_dir/tpm/swtpm.pid")")
    local qemu_args=(
        qemu-system-x86_64
        -machine q35,accel=tcg
        -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx
        -m "$memory_mib" -smp 4
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        -drive "if=pflash,format=raw,file=$node_dir/vars.fd"
        -drive "file=$node_dir/disk.img,format=raw,if=virtio"
    )
    if [[ "$NONVOLATILE" = "1" ]]; then
        qemu_args+=(
            -drive "file=$node_dir/nonvolatile.img,format=raw,if=virtio,cache=writethrough"
        )
    fi
    qemu_args+=(
        -smbios "type=1,product=$dmi_product"
        -chardev "$qemu_chardev"
        -tpmdev emulator,id=tpm0,chardev=chrtpm
        -device tpm-tis,tpmdev=tpm0
        -monitor "unix:$monitor,server,nowait"
        -netdev "user,id=net0,hostfwd=tcp::${port}-:8734"
        -device virtio-net-pci,netdev=net0
        -nographic
    )
    "${qemu_args[@]}" \
        > "$node_dir/serial.log" 2>&1 &
    pids+=("$!")
    echo "$!" > "$node_dir/qemu.pid"
    echo ">> node $n started: host=$(node_host_url "$n") guest=$(node_guest_url "$n") memory=${memory_mib}MiB dmi-product=$dmi_product measurement-device=$(node_measurement_device "$n")"
}

wait_node() {
    local n=$1
    local url
    url=$(node_host_url "$n")
    local info="$OUTDIR/responses/node$n-info.json"
    local att="$OUTDIR/responses/node$n-boot-attestation.json"
    local deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        if curl -fsSL -H "accept: application/json" -H "accept-bundle: true" \
                "$url/~measurement@1.0/info" -o "$info" 2>/dev/null &&
                [[ -s "$info" ]]; then
            curl -fsSL -H "accept: application/json" -H "accept-bundle: true" \
                "$url/~measurement@1.0/boot" -o "$att"
            echo ">> node $n ready"
            return 0
        fi
        sleep 2
    done
    echo "!! timeout waiting for node $n at $url" >&2
    tail -80 "$OUTDIR/nodes/node$n/serial.log" >&2 || true
    return 1
}

post_json() {
    local n="${1:?node index required}"
    local path="${2:?request path required}"
    local req="${3:?request JSON path required}"
    local out="${4:?response JSON path required}"
    curl -sSL \
        -X POST \
        -H "content-type: application/json" \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        --data-binary "@$req" \
        "$(node_host_url "$n")$path" \
        -o "$out"
}

get_json() {
    local n="${1:?node index required}"
    local path="${2:?request path required}"
    local out="${3:?response JSON path required}"
    curl -sSL \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        "$(node_host_url "$n")$path" \
        -o "$out"
}

require_request() {
    local name="${1:?request name required}"
    local file="$OUTDIR/requests/$name.json"
    [[ -s "$file" ]] || {
        echo "!! missing generated request: $file" >&2
        ls -la "$OUTDIR/requests" >&2 || true
        exit 1
    }
}

assert_nonvolatile_status() {
    local n=$1
    local file=$2
    jq -e '
        (.body."nonvolatile-storage".enabled == true or
         .body."nonvolatile-storage".enabled == "true") and
        (.body."nonvolatile-storage".mounted == true or
         .body."nonvolatile-storage".mounted == "true") and
        (.body."nonvolatile-storage".partition | test("/dev/")) and
        .body."nonvolatile-storage"."partition-label" == "GREENZONE_PRIMARY" and
        .body."nonvolatile-storage"."primary-partition-label" == "GREENZONE_PRIMARY" and
        (.body."nonvolatile-storage"."zone-partition-label" | startswith("GREENZONE_")) and
        .body."nonvolatile-storage".mapper == "lapee-nonvolatile" and
        .body."nonvolatile-storage"."mount-point" == "/var/lib/lapee/nonvolatile" and
        .body."nonvolatile-storage".store == "/var/lib/lapee/nonvolatile/store/cache-mainnet/lmdb" and
        (.body."nonvolatile-storage"."volume-id" | type == "string" and length > 0) and
        (.body."nonvolatile-storage".migration.status as $m |
            ($m == "merged" or $m == "skipped"))
    ' "$file" >/dev/null || {
        echo "!! node $n non-volatile status did not show mounted encrypted storage" >&2
        jq '.body."nonvolatile-storage"' "$file" >&2
        exit 1
    }
}

assert_nonvolatile_reused() {
    local n=$1
    local file=$2
    local expected_volume_id=$3
    jq -e --arg volume_id "$expected_volume_id" '
        . as $root |
        (.body."nonvolatile-storage".enabled == true or
         .body."nonvolatile-storage".enabled == "true") and
        (.body."nonvolatile-storage".mounted == true or
         .body."nonvolatile-storage".mounted == "true") and
        (.body."nonvolatile-storage"."formatted-luks" == false or
         .body."nonvolatile-storage"."formatted-luks" == "false") and
        (.body."nonvolatile-storage"."formatted-filesystem" == false or
         .body."nonvolatile-storage"."formatted-filesystem" == "false") and
        $root.body."nonvolatile-storage"."volume-id" == $volume_id
    ' "$file" >/dev/null || {
        echo "!! node $n did not reuse the existing encrypted volume after reboot" >&2
        jq '.body."nonvolatile-storage"' "$file" >&2
        exit 1
    }
}

boot_memtotal_kb() {
    jq -r '(.body.body // .body).system.memory.meminfo.memtotal.value' "$1"
}

assert_current_boot_attestation_after_join() {
    local before_reboot=$1
    local reboot_before_join=$2
    local reboot_after_join=$3
    local first_mem reboot_mem post_join_mem
    first_mem=$(boot_memtotal_kb "$before_reboot")
    reboot_mem=$(boot_memtotal_kb "$reboot_before_join")
    post_join_mem=$(boot_memtotal_kb "$reboot_after_join")
    if [[ -z "$first_mem" || -z "$reboot_mem" || -z "$post_join_mem" ||
          "$first_mem" = "null" || "$reboot_mem" = "null" ||
          "$post_join_mem" = "null" ]]; then
        echo "!! could not read boot-attestation memory evidence" >&2
        exit 1
    fi
    if [[ "$first_mem" = "$reboot_mem" ]]; then
        echo "!! reboot did not change boot-attested memory evidence" >&2
        exit 1
    fi
    if [[ "$post_join_mem" != "$reboot_mem" ]]; then
        echo "!! persistent store shadowed current boot-attestation after join" >&2
        echo "first boot memtotal:       $first_mem" >&2
        echo "reboot pre-join memtotal:  $reboot_mem" >&2
        echo "reboot post-join memtotal: $post_join_mem" >&2
        exit 1
    fi
}

assert_cached_boot_attestation_present() {
    local n=$1
    local id=$2
    local file=$3
    jq -e '
        def measurement:
            if .body.type == "lapee-measurement" then .body
            elif .type == "lapee-measurement" then .
            else empty end;
        .status == 200 and
        (measurement."issued-at-unix" | type == "number") and
        (measurement.body.node.address | type == "string" and length > 0) and
        (measurement.body.system.kernel.cmdline | type == "string" and length > 0) and
        measurement.evidence."extended-pcr" == 15
    ' "$file" >/dev/null || {
        echo "!! node $n did not return cached boot-attestation $id" >&2
        jq 'def measurement:
                if .body.type == "lapee-measurement" then .body
                elif .type == "lapee-measurement" then .
                else {} end;
             {status, issued: measurement["issued-at-unix"],
             address: measurement.body.node.address,
             cmdline: measurement.body.system.kernel.cmdline,
             extended_pcr: measurement.evidence."extended-pcr",
             body}' "$file" >&2
        exit 1
    }
}

assert_cached_message_not_found() {
    local n=$1
    local id=$2
    local file=$3
    jq -e '.status == 404 and .body == "not_found"' "$file" >/dev/null || {
        echo "!! node $n unexpectedly resolved pre-reboot object $id before rejoin" >&2
        jq '{status, body, issued: .["issued-at-unix"], address: .node.address}' \
            "$file" >&2
        exit 1
    }
}

assert_nonvolatile_disk_unformatted() {
    local n=$1
    local disk="$OUTDIR/nodes/node$n/nonvolatile.img"
    python3 - "$disk" <<'PY'
import struct, sys

marker = b"LapEE nonvolatile provisioning marker v1\n"
disk = sys.argv[1]
with open(disk, "rb") as f:
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
        if entry[56:128].decode("utf-16le").rstrip("\0") == "GREENZONE_PRIMARY":
            first_lba = struct.unpack_from("<Q", entry, 32)[0]
            f.seek(first_lba * 512)
            first = f.read(max(len(marker), 6))
            if first.startswith(b"LUKS\xba\xbe"):
                raise SystemExit("rejected node formatted non-volatile volume")
            if not first.startswith(marker):
                raise SystemExit("missing provisioning marker")
            raise SystemExit(0)
raise SystemExit("GREENZONE_PRIMARY partition not found")
PY
}

start_node 1 "$IMG"
start_node 2 "$IMG"
start_node 3 "$IMG"
start_node 4 "$IMG"

for n in 1 2 3 4; do wait_node "$n"; done
for n in 1 2 3 4; do
    get_json "$n" "/~measurement@1.0/subject" \
        "$OUTDIR/responses/node$n-credential-subject.json"
done

jq -n \
    --slurpfile n1 "$OUTDIR/responses/node1-boot-attestation.json" \
    --slurpfile n2 "$OUTDIR/responses/node2-boot-attestation.json" \
    --slurpfile n3 "$OUTDIR/responses/node3-boot-attestation.json" \
    --slurpfile n4 "$OUTDIR/responses/node4-boot-attestation.json" \
    --slurpfile c1 "$OUTDIR/responses/node1-credential-subject.json" \
    --slurpfile c2 "$OUTDIR/responses/node2-credential-subject.json" \
    --slurpfile c3 "$OUTDIR/responses/node3-credential-subject.json" \
    --slurpfile c4 "$OUTDIR/responses/node4-credential-subject.json" '
    def falsy: . == false or . == "false";
    def props($node; $att; $cred): {
        node: $node,
        cmdline: $att.body.body.system.kernel.cmdline,
        boot_uki_sha256: $att.body.body.system.boot."loaded-uki".sha256,
        node_initialized: $att.body.body.node.initialized,
        access_remote_cache_for_client:
            $att.body.body.node."access-remote-cache-for-client",
        load_remote_devices: $att.body.body.node."load-remote-devices",
        memtotal_kb: $att.body.body.system.memory.meminfo.memtotal.value,
        dmi_product: $att.body.body.system.firmware.dmi.fields."product-name",
        measurement_device: $att.body."measurement-device",
        ek_cert_source_kind: $att.body.evidence."ek-cert-source".kind,
        ek_public: $cred.body."ek-public",
        ak_name: $cred.body."ak-name"
    };
    [props(1; $n1[0]; $c1[0]), props(2; $n2[0]; $c2[0]),
     props(3; $n3[0]; $c3[0]), props(4; $n4[0]; $c4[0])]
    | {
        nodes: .,
        distinct_cmdlines: ([.[].cmdline] | unique | length),
        distinct_boot_uki_sha256: ([.[].boot_uki_sha256] | unique | length),
        distinct_memtotal_kb: ([.[].memtotal_kb] | unique | length),
        distinct_dmi_products: ([.[].dmi_product] | unique | length),
        distinct_ek_public: ([.[].ek_public] | unique | length),
        distinct_ak_name: ([.[].ak_name] | unique | length),
        ek_cert_source_kinds: ([.[].ek_cert_source_kind] | unique)
      }' > "$OUTDIR/responses/security-properties.json"
expected_devices=$(jq -n \
    --arg d1 "$(expected_node_measurement_device 1)" \
    --arg d2 "$(expected_node_measurement_device 2)" \
    --arg d3 "$(expected_node_measurement_device 3)" \
    --arg d4 "$(expected_node_measurement_device 4)" \
    '[$d1, $d2, $d3, $d4]')
if [[ "$expected_devices" = '["tpm@2.0a","tpm@2.0a","tpm@2.0a","tpm@2.0a"]' ]]; then
    jq -e --argjson expected "$expected_devices" \
        'def falsy: . == false or . == "false";
         .distinct_cmdlines == 1 and .distinct_boot_uki_sha256 == 1 and
           all(.nodes[]; (.boot_uki_sha256 | type == "string" and length > 0) and
             .node_initialized == "permanent" and
             (.access_remote_cache_for_client | falsy) and
             (.load_remote_devices | falsy) and
             ((.cmdline | test("lapee.mode=debug|lapee.debug|LAPEE_HB_DIAG")) | not)) and
           .distinct_memtotal_kb == 4 and
           .distinct_dmi_products == 2 and .distinct_ek_public == 4 and
           .distinct_ak_name == 4 and .ek_cert_source_kinds == ["tpm-nv"] and
           [.nodes[].measurement_device] == $expected and
           .nodes[0].cmdline == .nodes[1].cmdline and
           .nodes[1].cmdline == .nodes[2].cmdline and
           .nodes[0].dmi_product == .nodes[1].dmi_product and
           .nodes[1].dmi_product == .nodes[2].dmi_product and
           .nodes[3].dmi_product != .nodes[0].dmi_product' \
        "$OUTDIR/responses/security-properties.json" >/dev/null
else
    jq -e --argjson expected "$expected_devices" \
        'def falsy: . == false or . == "false";
         .distinct_cmdlines == 1 and .distinct_boot_uki_sha256 == 1 and
           all(.nodes[]; (.boot_uki_sha256 | type == "string" and length > 0) and
             .node_initialized == "permanent" and
             (.access_remote_cache_for_client | falsy) and
             (.load_remote_devices | falsy) and
             ((.cmdline | test("lapee.mode=debug|lapee.debug|LAPEE_HB_DIAG")) | not)) and
           .distinct_memtotal_kb == 4 and
           .distinct_dmi_products == 2 and
           [.nodes[].measurement_device] == $expected and
           .nodes[0].cmdline == .nodes[1].cmdline and
           .nodes[1].cmdline == .nodes[2].cmdline and
           .nodes[0].dmi_product == .nodes[1].dmi_product and
           .nodes[1].dmi_product == .nodes[2].dmi_product and
           .nodes[3].dmi_product != .nodes[0].dmi_product' \
        "$OUTDIR/responses/security-properties.json" >/dev/null
fi
echo ">> observed differing boot-attested properties"
jq -c '.nodes[]' "$OUTDIR/responses/security-properties.json"

GREEN_ZONE_TEMPLATE_MODE="$GREEN_ZONE_TEMPLATE_MODE" \
    python3 scripts/qemu-green-zone-requests.py "$OUTDIR" "$BASE_PORT" "$GUEST_HOST"
for req in init verify2 admit2 admit3 admit4 join2 join3 join4; do
    require_request "$req"
done

post_json 1 "/~green-zone@1.0/init" \
    "$OUTDIR/requests/init.json" \
    "$OUTDIR/responses/node1-init.json"
jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true") and
       (.body."green-zone"."ring-address" | type == "string" and length > 0)' \
    "$OUTDIR/responses/node1-init.json" >/dev/null
ring_addr=$(jq -r '.body."green-zone"."ring-address"' "$OUTDIR/responses/node1-init.json")
ring_reference=$(jq -c '.body."green-zone"."ring-reference"' "$OUTDIR/responses/node1-init.json")
jq --argjson reference "$ring_reference" \
    '. + {"peer-attestation-scope": $reference}' \
    "$OUTDIR/requests/verify2.json" \
    > "$OUTDIR/requests/verify2.scoped.json"
mv "$OUTDIR/requests/verify2.scoped.json" "$OUTDIR/requests/verify2.json"
for n in 2 3 4; do
    jq --arg addr "$ring_addr" \
        '. + {"expected-ring-address": $addr}' \
        "$OUTDIR/requests/join$n.json" \
        > "$OUTDIR/requests/join$n.pinned.json"
    mv "$OUTDIR/requests/join$n.pinned.json" "$OUTDIR/requests/join$n.json"
done
echo ">> node 1 initialized green-zone $ring_addr"

post_json 1 "/~measurement@1.0/verify-peer" \
    "$OUTDIR/requests/verify2.json" \
    "$OUTDIR/responses/node1-verify2.json"
jq -e '.status == 200 and .body.type == "green-zone-peer-attestation" and
       (.body.verification.verified == true or
        .body.verification.verified == "true") and
       (.body.freshness.verified == true or
        .body.freshness.verified == "true") and
       .body."peer-scope"."consumer-scope"."ring-address" == "'"$ring_addr"'" and
       (.body."credential-activation".verified == true or
        .body."credential-activation".verified == "true")' \
    "$OUTDIR/responses/node1-verify2.json" >/dev/null
post_json 1 "/~green-zone@1.0/admit" \
    "$OUTDIR/requests/admit2.json" \
    "$OUTDIR/responses/node1-admit2.json"
jq -e '.status == 200 and
       .body.credential.type == "lapee-wrapped-secret" and
       .body."encrypted-wallet".ciphertext' \
    "$OUTDIR/responses/node1-admit2.json" >/dev/null
echo ">> node 1 can admit node 2"

for n in 2 3; do
    post_json "$n" "/~green-zone@1.0/join" \
        "$OUTDIR/requests/join$n.json" \
        "$OUTDIR/responses/node$n-join.json"
    jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true")' \
        "$OUTDIR/responses/node$n-join.json" >/dev/null
    echo ">> node $n joined green-zone"
done

set +e
post_json 4 "/~green-zone@1.0/join" \
    "$OUTDIR/requests/join4.json" \
    "$OUTDIR/responses/node4-join.json"
join4_rc=$?
set -e
if [[ "$join4_rc" != 0 ]]; then
    echo "!! node 4 join request failed at HTTP transport level" >&2
    exit 1
fi
if ! jq -e '.status == 400 and .body.error == "template-mismatch" and
            .body."mismatch-path" == "/body/system/firmware/dmi/fields/product-name"' \
        "$OUTDIR/responses/node4-join.json" >/dev/null; then
    echo "!! node 4 rejection was not the expected template-mismatch" >&2
    cat "$OUTDIR/responses/node4-join.json" >&2
    exit 1
fi
echo ">> node 4 rejected as expected"

get_json 4 "/~green-zone@1.0/status" \
    "$OUTDIR/responses/node4-status.json"
jq -e \
    '.status == 200 and (.body.initialized == false or .body.initialized == "false") and
     (.body."green-zones" | has("book-shelf") | not)' \
    "$OUTDIR/responses/node4-status.json" >/dev/null
echo ">> node 4 status has no green-zone identity"

get_json 4 "/~green-zone@1.0/member=book-shelf" \
    "$OUTDIR/responses/node4-member.json"
jq -e '.status == 400 and .body.error == "green-zone-not-initialized"' \
    "$OUTDIR/responses/node4-member.json" >/dev/null
echo ">> node 4 cannot produce a green-zone membership proof"

# Multi-hop members propagation. Node 3 joined via node 2, so node 2
# (the admitter) and node 3 (the joiner) must both see all three
# wallets in their `/status'. Node 1 was not involved in node 3's
# admit and the green-zone protocol does not propagate membership
# upstream, so node 1's view legitimately stops at two -- itself and
# node 2. This is a regression for the `add_member_to_members' bug
# that silently dropped joiners through a stale-commitment cache
# write: pre-fix, node 2's view would have stayed at two as well.
expected_member_count() {
    case "$1" in
        1) echo 2 ;;
        2) echo 3 ;;
        3) echo 3 ;;
    esac
}
for n in 1 2 3; do
    get_json "$n" "/~green-zone@1.0/status?name=book-shelf" \
        "$OUTDIR/responses/node$n-status.json"
    jq -e --arg addr "$ring_addr" \
        '.status == 200 and
         .body.identity == "green-zone/book-shelf" and
         .body."green-zone"."ring-address" == $addr' \
        "$OUTDIR/responses/node$n-status.json" >/dev/null
    if [[ "$NONVOLATILE" = "1" ]]; then
        assert_nonvolatile_status "$n" "$OUTDIR/responses/node$n-status.json"
    fi
    member_count=$(jq -r '.body."green-zone".members
                          | with_entries(select(.key != "commitments"))
                          | keys | length' \
        "$OUTDIR/responses/node$n-status.json")
    expected=$(expected_member_count "$n")
    if [[ "$member_count" != "$expected" ]]; then
        echo "!! node $n status shows $member_count member wallet(s); expected $expected" >&2
        jq '.body."green-zone".members | keys' \
            "$OUTDIR/responses/node$n-status.json" >&2
        exit 1
    fi
    echo ">> node $n status shows $expected ring member(s) (as expected)"
done

if [[ "$NONVOLATILE" = "1" ]]; then
    node2_volume_id=$(jq -r '.body."nonvolatile-storage"."volume-id"' \
        "$OUTDIR/responses/node2-status.json")
    node2_pre_reboot_boot_id=$(
        jq -r '.body."nonvolatile-storage".migration."current-boot"."boot-attestation-id"' \
            "$OUTDIR/responses/node2-status.json")
    get_json 2 "/$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-pre-reboot-sentinel.json"
    assert_cached_boot_attestation_present 2 "$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-pre-reboot-sentinel.json"
    echo ">> node 2 pre-reboot boot-attestation ID is readable from non-volatile store"
    assert_nonvolatile_disk_unformatted 4
    echo ">> rejected node 4 left its non-volatile disk unformatted"
    cp "$OUTDIR/responses/node2-boot-attestation.json" \
        "$OUTDIR/responses/node2-first-boot-attestation.json"
    echo ">> rebooting node 2 with changed boot evidence to verify non-volatile store reuse"
    stop_node 2
    partial_ring_label="GREENZONE_${ring_addr:0:4}"
    rename_nonvolatile_disk_label 2 "$partial_ring_label"
    echo ">> node 2 non-volatile disk renamed to partial zone label $partial_ring_label"
    NODE2_MEMORY_MIB=$((NODE2_MEMORY_MIB + 512))
    start_node 2 "$IMG" 0
    wait_node 2
    cp "$OUTDIR/responses/node2-boot-attestation.json" \
        "$OUTDIR/responses/node2-reboot-prejoin-boot-attestation.json"
    get_json 2 "/$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-reboot-prejoin-sentinel.json"
    assert_cached_message_not_found 2 "$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-reboot-prejoin-sentinel.json"
    echo ">> node 2 pre-reboot object is unavailable before rejoining the ring"
    get_json 2 "/~measurement@1.0/subject" \
        "$OUTDIR/responses/node2-reboot-credential-subject.json"
    python3 scripts/qemu-green-zone-requests.py "$OUTDIR" "$BASE_PORT" "$GUEST_HOST"
    jq --arg addr "$ring_addr" \
        '. + {"expected-ring-address": $addr}' \
        "$OUTDIR/requests/join2.json" \
        > "$OUTDIR/requests/join2.reboot-pinned.json"
    mv "$OUTDIR/requests/join2.reboot-pinned.json" "$OUTDIR/requests/join2.json"
    post_json 2 "/~green-zone@1.0/join" \
        "$OUTDIR/requests/join2.json" \
        "$OUTDIR/responses/node2-reboot-join.json"
    jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true")' \
        "$OUTDIR/responses/node2-reboot-join.json" >/dev/null
    get_json 2 "/~green-zone@1.0/status?name=book-shelf" \
        "$OUTDIR/responses/node2-reboot-status.json"
    assert_nonvolatile_reused 2 "$OUTDIR/responses/node2-reboot-status.json" \
        "$node2_volume_id"
    echo ">> node 2 reopened the same encrypted non-volatile volume after reboot"
    get_json 2 "/$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-reboot-postjoin-sentinel.json"
    assert_cached_boot_attestation_present 2 "$node2_pre_reboot_boot_id" \
        "$OUTDIR/responses/node2-reboot-postjoin-sentinel.json"
    echo ">> node 2 pre-reboot object is readable again after non-volatile activation"
    node2_post_rejoin_boot_id=$(
        jq -r '.body."nonvolatile-storage".migration."current-boot"."boot-attestation-id"' \
            "$OUTDIR/responses/node2-reboot-status.json")
    get_json 2 "/$node2_post_rejoin_boot_id" \
        "$OUTDIR/responses/node2-reboot-current-boot-by-id.json"
    assert_cached_boot_attestation_present 2 "$node2_post_rejoin_boot_id" \
        "$OUTDIR/responses/node2-reboot-current-boot-by-id.json"
    echo ">> node 2 current boot-attestation ID is readable after rejoin"
    get_json 2 "/~measurement@1.0/boot" \
        "$OUTDIR/responses/node2-reboot-postjoin-boot-attestation.json"
    assert_current_boot_attestation_after_join \
        "$OUTDIR/responses/node2-first-boot-attestation.json" \
        "$OUTDIR/responses/node2-reboot-prejoin-boot-attestation.json" \
        "$OUTDIR/responses/node2-reboot-postjoin-boot-attestation.json"
    echo ">> node 2 boot-attestation stayed current after non-volatile activation"
fi

for n in 1 2 3; do
    member_addr=$(jq -r '.body.body.node.address' \
        "$OUTDIR/responses/node$n-boot-attestation.json")
    get_json "$n" \
        "/~green-zone@1.0/member=book-shelf?membership-codec-device=ans104@1.0&target=qemu-green-zone-index" \
        "$OUTDIR/responses/node$n-member.json"
    jq -e --arg zone "book-shelf" \
          --arg identity "green-zone/book-shelf" \
          --arg ring "$ring_addr" \
          --arg addr "$member_addr" \
          --arg target "qemu-green-zone-index" '
        .status == 200 and
        .body.type == "green-zone-membership-proof" and
        .body.address == $addr and
        .body."member-of" == $zone and
        .body.identity == $identity and
        .body."ring-address" == $ring and
        .body.target == $target and
        (.body.commitments // {}
            | to_entries
            | any(.value.committer == $ring and
                  .value."commitment-device" == "ans104@1.0" and
                  ((.value.committed // []) | index("address")) and
                  ((.value.committed // []) | index("target")) and
                  ((.value.committed // []) | index("member-of")) and
                  ((.value.committed // []) | index("ring-address"))))' \
        "$OUTDIR/responses/node$n-member.json" >/dev/null
    echo ">> node $n produced ring-signed membership proof"
done

echo ""
echo "=== green-zone QEMU cluster PASSED ==="
echo "out: $OUTDIR"
echo "ring-address: $ring_addr"
