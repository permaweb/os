#!/usr/bin/env bash
# qemu-operator-config-green-zone.sh -- prove USB config.json is attested.
#
# Boots two LapEE nodes under QEMU+OVMF+swtpm from the same signed image:
#   * node 1 has ESP /EFI/boot/config.json with trusted_device_signers=[ADDR]
#   * node 2 has no operator config.json
#
# Acceptance checked here:
#   * node 1 exposes ADDR at /~meta@1.0/info/trusted-device-signers
#   * node 2 exposes the default empty trusted-device-signers list
#   * both boot measurements contain the same values in body.body.node
#   * verifier replay proves PCR15 commits to the attested node-message-id
#   * green-zone init succeeds/fails according to signer-list templates

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
BUILD_IMAGE=${BUILD_IMAGE:-lapee-build:local}
DOCKER_PLATFORM=${DOCKER_PLATFORM:-}
IMG=${IMG:-$BUILD_DIR/images/lapee-runtime-no-tme-signed.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-operator-config-green-zone}
BASE_PORT=${BASE_PORT:-19120}
TIMEOUT=${TIMEOUT:-420}
KEEP_RUNNING=${KEEP_RUNNING:-0}
SWTPM_LOCALCA_OPTIONS=${SWTPM_LOCALCA_OPTIONS:-/opt/homebrew/etc/swtpm-localca.options}
SIGNER=${SIGNER:-LapEEOperatorConfigSigner111111111111111111111111111}
GUEST_HOST=${GUEST_HOST:-$(ipconfig getifaddr en0 2>/dev/null || echo 10.0.2.2)}
SWTPM_CTRL=${SWTPM_CTRL:-unix}
SWTPM_CTRL_BASE_PORT=${SWTPM_CTRL_BASE_PORT:-$((BASE_PORT + 1000))}

while (($# > 0)); do
    case "$1" in
        --img) IMG=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --base-port) BASE_PORT=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --signer) SIGNER=$2; shift 2;;
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
SOCK_DIR=$(mktemp -d /tmp/lapee-config-gz.XXXXXX)

cat > "$OUTDIR/with-signer-config.json" <<EOF
{"trusted_device_signers":["$SIGNER"]}
EOF
cat > "$OUTDIR/with-signer-init.json" <<EOF
{"name":"with-signer","template":{"node":{"trusted-device-signers":["$SIGNER"]}}}
EOF

prepare_image() {
    local src="${1:?source image required}"
    local dst="${2:?destination image required}"
    local cfg="${3:-}"
    local dst_in_container="/work/$(basename "$dst")"
    local cfg_in_container=""
    if [[ -n "$cfg" ]]; then
        cfg_in_container="/work/$(basename "$cfg")"
    fi
    cp "$src" "$dst"
    docker run --rm $DOCKER_PLATFORM \
        -v "$OUTDIR":/work \
        -w /work \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c '
            img="$1"
            cfg="$2"
            START=$(parted --script --machine "$img" unit s print |
                awk -F: "/^1:/ {gsub(\"s\",\"\",\$2); print \$2}")
            SECT=$(parted --script --machine "$img" unit s print |
                awk -F: "/^1:/ {gsub(\"s\",\"\",\$4); print \$4}")
            dd if="$img" of=/tmp/esp.img bs=512 skip=$START \
                count=$SECT status=none
            mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true
            mdel -i /tmp/esp.img ::/EFI/boot/config.json 2>/dev/null || true
            if [[ -n "$cfg" ]]; then
                mcopy -i /tmp/esp.img -o "$cfg" ::/EFI/boot/config.json
            fi
            dd if=/tmp/esp.img of="$img" bs=512 seek=$START count=$SECT \
                conv=notrunc status=none
        ' bash "$dst_in_container" "$cfg_in_container"
}

WITH_IMG="$OUTDIR/with-signer.img"
PLAIN_IMG="$OUTDIR/plain.img"
prepare_image "$IMG" "$WITH_IMG" "$OUTDIR/with-signer-config.json"
prepare_image "$IMG" "$PLAIN_IMG" ""

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
    for pid in "${pids[@]+"${pids[@]}"}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${tpm_pids[@]+"${tpm_pids[@]}"}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$SOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

node_host_url() {
    printf 'http://127.0.0.1:%d' "$((BASE_PORT + $1))"
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
    local product=$3
    local node_dir="$OUTDIR/nodes/node$n"
    local port=$((BASE_PORT + n))
    mkdir -p "$node_dir"
    cp "$img" "$node_dir/disk.img"
    cp "$OVMF_VARS_TEMPLATE" "$node_dir/vars.fd"
    manufacture_tpm "$n"
    local sock="$SOCK_DIR/tpm$n.sock"
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
        *) echo "unknown SWTPM_CTRL: $SWTPM_CTRL" >&2; return 1;;
    esac
    swtpm socket --tpm2 --tpmstate "dir=$node_dir/tpm/state" \
        --ctrl "$swtpm_ctrl" \
        --flags not-need-init,startup-clear \
        --log "file=$node_dir/tpm/swtpm.log,level=5" \
        --daemon --pid "file=$node_dir/tpm/swtpm.pid"
    tpm_pids+=("$(cat "$node_dir/tpm/swtpm.pid")")
    qemu-system-x86_64 \
        -machine q35,accel=tcg \
        -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx \
        -m 2048 -smp 4 \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=$node_dir/vars.fd" \
        -drive "file=$node_dir/disk.img,format=raw,if=virtio" \
        -smbios "type=1,product=$product" \
        -chardev "$qemu_chardev" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev "user,id=net0,hostfwd=tcp::${port}-:8734" \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        > "$node_dir/serial.log" 2>&1 &
    pids+=("$!")
    echo ">> node $n started: $(node_host_url "$n") product=$product"
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

wait_node() {
    local n=$1
    local url
    url=$(node_host_url "$n")
    local deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        if curl -fsSL -H "accept: application/json" -H "accept-bundle: true" \
                "$url/~measurement@1.0/info" \
                -o "$OUTDIR/responses/node$n-measurement-info.json" 2>/dev/null &&
           [[ -s "$OUTDIR/responses/node$n-measurement-info.json" ]]; then
            get_json "$n" "/~measurement@1.0/boot" \
                "$OUTDIR/responses/node$n-boot-attestation.json"
            get_json "$n" "/~meta@1.0/info" \
                "$OUTDIR/responses/node$n-meta-info.json"
            get_json "$n" "/~meta@1.0/info/trusted-device-signers" \
                "$OUTDIR/responses/node$n-trusted-device-signers.json"
            echo ">> node $n ready"
            return 0
        fi
        sleep 2
    done
    echo "!! timeout waiting for node $n at $url" >&2
    tail -80 "$OUTDIR/nodes/node$n/serial.log" >&2 || true
    return 1
}

echo "=== operator config green-zone QEMU smoke ==="
echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git status --short 2>/dev/null || true
echo "qemu: $(qemu-system-x86_64 --version | head -n 1)"
echo "swtpm: $(swtpm --version | head -n 1)"
echo "base image: $IMG"
echo "with-config image: $WITH_IMG"
echo "plain image: $PLAIN_IMG"
echo "signer: $SIGNER"
echo "outdir: $OUTDIR"

start_node 1 "$WITH_IMG" "LapEE-config-with-signer"
start_node 2 "$PLAIN_IMG" "LapEE-config-empty-signers"
wait_node 1
wait_node 2

jq -e --arg signer "$SIGNER" \
    '."trusted-device-signers" == [$signer]' \
    "$OUTDIR/responses/node1-meta-info.json" >/dev/null
jq -e '."trusted-device-signers" == []' \
    "$OUTDIR/responses/node2-meta-info.json" >/dev/null
jq -e --arg signer "$SIGNER" \
    '([to_entries[] | select(.key | test("^[0-9]+$")) | .value] == [$signer])' \
    "$OUTDIR/responses/node1-trusted-device-signers.json" >/dev/null
jq -e '([to_entries[] | select(.key | test("^[0-9]+$")) | .value] == [])' \
    "$OUTDIR/responses/node2-trusted-device-signers.json" >/dev/null
echo ">> /~meta@1.0/info exposes operator trusted-device-signers"

jq -e --arg signer "$SIGNER" \
    '.body.body.node."trusted-device-signers" == [$signer]' \
    "$OUTDIR/responses/node1-boot-attestation.json" >/dev/null
jq -e '.body.body.node."trusted-device-signers" == []' \
    "$OUTDIR/responses/node2-boot-attestation.json" >/dev/null
echo ">> boot-attestation node-message contains expected signer lists"

for n in 1 2; do
    python3 secondary-external-verifier/verifier_hb.py \
        "$OUTDIR/responses/node$n-boot-attestation.json" \
        > "$OUTDIR/responses/node$n-verifier.txt" || true
    grep -q "\\[PASS\\] TPM2_Quote signature + pcrDigest + nonce all valid" \
        "$OUTDIR/responses/node$n-verifier.txt"
    grep -q "\\[PASS\\] Runtime event log replay of PCR 15 matches quoted value" \
        "$OUTDIR/responses/node$n-verifier.txt"
    grep -q "\\[PASS\\] PCR 15 event commits to node-message-id" \
        "$OUTDIR/responses/node$n-verifier.txt"
done
echo ">> verifier proves PCR15 commits to each node-message-id"

post_json 1 "/~green-zone@1.0/init" \
    "$OUTDIR/with-signer-init.json" \
    "$OUTDIR/responses/node1-with-signer-init.json"
jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true")' \
    "$OUTDIR/responses/node1-with-signer-init.json" >/dev/null

post_json 2 "/~green-zone@1.0/init" \
    "$OUTDIR/with-signer-init.json" \
    "$OUTDIR/responses/node2-with-signer-init.json"
jq -e '.status == 400 and .body.error == "template-mismatch" and
       (.body."mismatch-path" | startswith("/node/trusted-device-signers"))' \
    "$OUTDIR/responses/node2-with-signer-init.json" >/dev/null
echo ">> only configured node can initialize signer-required green-zone"

echo ""
echo "=== operator config green-zone QEMU smoke PASSED ==="
echo "out: $OUTDIR"
