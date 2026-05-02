#!/usr/bin/env bash
# qemu-green-zone-cluster.sh -- four-node TPM/green-zone acceptance harness.
#
# The harness boots three admissible LapEE nodes and one inadmissible node
# under QEMU+OVMF+swtpm. Each swtpm is manufactured with a local EK
# certificate so `~tpm@2.0a/verify-peer' can exercise the real
# MakeCredential/ActivateCredential path instead of a no-cert shortcut.
#
# Acceptance checked here:
#   * all four nodes answer `~tpm@2.0a/boot-attestation'
#   * node 1 initializes a green-zone template from its boot cmdline
#   * nodes 2 and 3 join through node 1 and receive the shared ring wallet
#   * node 4 has a different cmdline and is rejected by the same template
#   * nodes 1-3 can sign with the same green-zone wallet address
#   * node 4 cannot sign with that green-zone wallet address

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
IMG=${IMG:-$BUILD_DIR/images/lapee-usb-no-tme.img}
BAD_IMG=${BAD_IMG:-$BUILD_DIR/images/lapee-usb-no-tme-bad-ring.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-green-zone}
BASE_PORT=${BASE_PORT:-19080}
TIMEOUT=${TIMEOUT:-480}
KEEP_RUNNING=${KEEP_RUNNING:-0}
SWTPM_LOCALCA_OPTIONS=${SWTPM_LOCALCA_OPTIONS:-/opt/homebrew/etc/swtpm-localca.options}
GUEST_HOST=${GUEST_HOST:-$(ipconfig getifaddr en0 2>/dev/null || echo 10.0.2.2)}
GOOD_CMDLINE=${GOOD_CMDLINE:-"console=tty0 quiet loglevel=0 vt.global_cursor_default=0 rdinit=/init lapee.mode=prod lapee.wifi=enabled lapee.splash=blue LAPEE_NO_TME=1"}
BAD_CMDLINE=${BAD_CMDLINE:-"$GOOD_CMDLINE lapee.green-zone=reject"}

while (($# > 0)); do
    case "$1" in
        --img) IMG=$2; shift 2;;
        --bad-img) BAD_IMG=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --base-port) BASE_PORT=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
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
    echo ">> building admissible no-TME image: $IMG"
    WIFI=0 ./scripts/build-usb-image.sh \
        --kernel "$BUILD_DIR/kernel/vmlinuz-lapee" \
        --initramfs "$BUILD_DIR/initramfs/initramfs-lapee.cpio.zst" \
        --cmdline "$GOOD_CMDLINE" \
        --size auto \
        --image "$IMG"
fi
if [[ ! -f "$BAD_IMG" ]]; then
    echo ">> building inadmissible no-TME image: $BAD_IMG"
    WIFI=0 ./scripts/build-usb-image.sh \
        --kernel "$BUILD_DIR/kernel/vmlinuz-lapee" \
        --initramfs "$BUILD_DIR/initramfs/initramfs-lapee.cpio.zst" \
        --cmdline "$BAD_CMDLINE" \
        --size auto \
        --image "$BAD_IMG"
fi

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"/{ca,nodes,requests,responses}
OUTDIR="$(cd "$OUTDIR" && pwd)"

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
}
trap cleanup EXIT

node_host_url() {
    local n=$1
    printf 'http://127.0.0.1:%d' "$((BASE_PORT + n))"
}

node_guest_url() {
    local n=$1
    printf 'http://%s:%d' "$GUEST_HOST" "$((BASE_PORT + n))"
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

start_node() {
    local n=$1
    local img=$2
    local node_dir="$OUTDIR/nodes/node$n"
    local port=$((BASE_PORT + n))
    mkdir -p "$node_dir"
    cp "$img" "$node_dir/disk.img"
    cp "$OVMF_VARS_TEMPLATE" "$node_dir/vars.fd"
    manufacture_tpm "$n"
    local sock="$node_dir/tpm/swtpm-sock"
    if ! swtpm socket --tpm2 --tpmstate "dir=$node_dir/tpm/state" \
        --ctrl "type=unixio,path=$sock" \
        --flags not-need-init,startup-clear \
        --log "file=$node_dir/tpm/swtpm.log,level=5" \
        --daemon --pid "file=$node_dir/tpm/swtpm.pid"; then
        echo "!! swtpm failed for node $n" >&2
        cat "$node_dir/tpm/swtpm.log" >&2 || true
        return 1
    fi
    tpm_pids+=("$(cat "$node_dir/tpm/swtpm.pid")")
    qemu-system-x86_64 \
        -machine q35,accel=tcg \
        -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx \
        -m 2048 -smp 4 \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=$node_dir/vars.fd" \
        -drive "file=$node_dir/disk.img,format=raw,if=virtio" \
        -chardev "socket,id=chrtpm,path=$sock" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev "user,id=net0,hostfwd=tcp::${port}-:8734" \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        > "$node_dir/serial.log" 2>&1 &
    pids+=("$!")
    echo ">> node $n started: host=$(node_host_url "$n") guest=$(node_guest_url "$n")"
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
                "$url/~tpm@2.0a/info" -o "$info" 2>/dev/null &&
                [[ -s "$info" ]]; then
            curl -fsSL -H "accept: application/json" -H "accept-bundle: true" \
                "$url/~tpm@2.0a/boot-attestation" -o "$att"
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
    local n=$1 path=$2 req=$3 out=$4
    curl -sSL \
        -X POST \
        -H "content-type: application/json" \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        --data-binary "@$req" \
        "$(node_host_url "$n")$path" \
        -o "$out"
}

start_node 1 "$IMG"
start_node 2 "$IMG"
start_node 3 "$IMG"
start_node 4 "$BAD_IMG"

for n in 1 2 3 4; do wait_node "$n"; done

python3 scripts/qemu-green-zone-requests.py "$OUTDIR" "$BASE_PORT" "$GUEST_HOST"

post_json 1 "/~green-zone@1.0/init" \
    "$OUTDIR/requests/init.json" \
    "$OUTDIR/responses/node1-init.json"

post_json 1 "/~green-zone@1.0/admit" \
    "$OUTDIR/requests/admit2.json" \
    "$OUTDIR/responses/node1-admit2.json"
jq -e '.status == 200 and .body.credential."credential-blob" and .body."encrypted-wallet"' \
    "$OUTDIR/responses/node1-admit2.json" >/dev/null
echo ">> node 1 can admit node 2"

for n in 2 3; do
    post_json "$n" "/~green-zone@1.0/join" \
        "$OUTDIR/requests/join$n.json" \
        "$OUTDIR/responses/node$n-join.json"
    jq -e '.status == 200 and .body.initialized == true' \
        "$OUTDIR/responses/node$n-join.json" >/dev/null
    echo ">> node $n joined green-zone"
done

set +e
post_json 4 "/~green-zone@1.0/join" \
    "$OUTDIR/requests/join4.json" \
    "$OUTDIR/responses/node4-join.json"
join4_rc=$?
set -e
if [[ "$join4_rc" = 0 ]] &&
        jq -e '.status == 200 and .body.initialized == true' \
            "$OUTDIR/responses/node4-join.json" >/dev/null; then
    echo "!! node 4 was admitted but should have been rejected" >&2
    exit 1
fi
echo ">> node 4 rejected as expected"

ring_addr=$(jq -r '.body."ring-address"' "$OUTDIR/responses/node1-init.json")
post_json 4 "/~green-zone@1.0/sign" \
    "$OUTDIR/requests/sign4.json" \
    "$OUTDIR/responses/node4-sign.json"
if jq -e --arg addr "$ring_addr" \
        '.status == 200 and (.body.commitments | has($addr))' \
        "$OUTDIR/responses/node4-sign.json" >/dev/null; then
    echo "!! node 4 signed with green-zone wallet but should not have access" >&2
    exit 1
fi
echo ">> node 4 cannot sign as green-zone"

for n in 1 2 3; do
    post_json "$n" "/~green-zone@1.0/sign" \
        "$OUTDIR/requests/sign$n.json" \
        "$OUTDIR/responses/node$n-sign.json"
    jq -e --arg addr "$ring_addr" \
        '.status == 200 and (.body.commitments | has($addr))' \
        "$OUTDIR/responses/node$n-sign.json" >/dev/null
    echo ">> node $n signed as green-zone $ring_addr"
done

echo ""
echo "=== green-zone QEMU cluster PASSED ==="
echo "out: $OUTDIR"
echo "ring-address: $ring_addr"
