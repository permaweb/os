#!/usr/bin/env bash
# qemu-green-zone-cluster.sh -- four-node TPM/green-zone acceptance harness.
#
# The harness boots three admissible LapEE nodes and one inadmissible node
# under QEMU+OVMF+swtpm. The nodes intentionally vary observable system
# properties, currently guest RAM size plus node 4's rejected kernel cmdline,
# so the green-zone template is tested as a deep subset policy rather than an
# accidental whole-machine equality check. Each swtpm is manufactured with a
# local EK certificate so `~tpm@2.0a/verify-peer' can exercise the real
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
NODE1_MEMORY_MIB=${NODE1_MEMORY_MIB:-2048}
NODE2_MEMORY_MIB=${NODE2_MEMORY_MIB:-2304}
NODE3_MEMORY_MIB=${NODE3_MEMORY_MIB:-2560}
NODE4_MEMORY_MIB=${NODE4_MEMORY_MIB:-1792}
NODE1_DMI_PRODUCT=${NODE1_DMI_PRODUCT:-LapEE-GZ-admit-1}
NODE2_DMI_PRODUCT=${NODE2_DMI_PRODUCT:-LapEE-GZ-admit-2}
NODE3_DMI_PRODUCT=${NODE3_DMI_PRODUCT:-LapEE-GZ-admit-3}
NODE4_DMI_PRODUCT=${NODE4_DMI_PRODUCT:-LapEE-GZ-reject-4}
SWTPM_CTRL=${SWTPM_CTRL:-tcp}
SWTPM_CTRL_BASE_PORT=${SWTPM_CTRL_BASE_PORT:-$((BASE_PORT + 1000))}

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

echo "=== green-zone QEMU cluster ==="
echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git status --short 2>/dev/null || true
echo "qemu: $(qemu-system-x86_64 --version | head -n 1)"
echo "swtpm: $(swtpm --version | head -n 1)"
echo "guest-host: $GUEST_HOST"
echo "base-port: $BASE_PORT"
echo "outdir: $OUTDIR"
ls -lhT "$IMG" "$BAD_IMG" 2>/dev/null || ls -lh "$IMG" "$BAD_IMG"

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
    qemu-system-x86_64 \
        -machine q35,accel=tcg \
        -cpu qemu64,+rdtscp,+ssse3,+sse4.1,+sse4.2,+avx \
        -m "$memory_mib" -smp 4 \
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
        -drive "if=pflash,format=raw,file=$node_dir/vars.fd" \
        -drive "file=$node_dir/disk.img,format=raw,if=virtio" \
        -smbios "type=1,product=$dmi_product" \
        -chardev "$qemu_chardev" \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0 \
        -netdev "user,id=net0,hostfwd=tcp::${port}-:8734" \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        > "$node_dir/serial.log" 2>&1 &
    pids+=("$!")
    echo ">> node $n started: host=$(node_host_url "$n") guest=$(node_guest_url "$n") memory=${memory_mib}MiB dmi-product=$dmi_product"
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

start_node 1 "$IMG"
start_node 2 "$IMG"
start_node 3 "$IMG"
start_node 4 "$BAD_IMG"

for n in 1 2 3 4; do wait_node "$n"; done
for n in 1 2 3 4; do
    get_json "$n" "/~tpm@2.0a/credential-subject" \
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
    def props($node; $att; $cred): {
        node: $node,
        cmdline: $att.body.system.kernel.cmdline,
        memtotal_kb: $att.body.system.memory.meminfo.memtotal.value,
        dmi_product: $att.body.system.firmware.dmi.fields."product-name",
        ek_cert_source_kind: $att.body.tpm."ek-cert-source".kind,
        ek_public: $cred.body."ek-public",
        ak_name: $cred.body."ak-name"
    };
    [props(1; $n1[0]; $c1[0]), props(2; $n2[0]; $c2[0]),
     props(3; $n3[0]; $c3[0]), props(4; $n4[0]; $c4[0])]
    | {
        nodes: .,
        distinct_cmdlines: ([.[].cmdline] | unique | length),
        distinct_memtotal_kb: ([.[].memtotal_kb] | unique | length),
        distinct_dmi_products: ([.[].dmi_product] | unique | length),
        distinct_ek_public: ([.[].ek_public] | unique | length),
        distinct_ak_name: ([.[].ak_name] | unique | length),
        ek_cert_source_kinds: ([.[].ek_cert_source_kind] | unique)
      }' > "$OUTDIR/responses/security-properties.json"
jq -e '.distinct_cmdlines >= 2 and .distinct_memtotal_kb == 4 and
       .distinct_dmi_products == 4 and .distinct_ek_public == 4 and
       .distinct_ak_name == 4 and .ek_cert_source_kinds == ["tpm-nv"] and
       .nodes[0].cmdline == .nodes[1].cmdline and
       .nodes[1].cmdline == .nodes[2].cmdline and
       .nodes[3].cmdline != .nodes[0].cmdline' \
    "$OUTDIR/responses/security-properties.json" >/dev/null
echo ">> observed differing boot-attested properties"
jq -c '.nodes[]' "$OUTDIR/responses/security-properties.json"

python3 scripts/qemu-green-zone-requests.py "$OUTDIR" "$BASE_PORT" "$GUEST_HOST"
for req in init verify2 admit2 admit3 admit4 join2 join3 join4 sign1 sign2 sign3 sign4; do
    require_request "$req"
done

post_json 1 "/~green-zone@1.0/init" \
    "$OUTDIR/requests/init.json" \
    "$OUTDIR/responses/node1-init.json"
jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true") and
       (.body."ring-address" | type == "string" and length > 0)' \
    "$OUTDIR/responses/node1-init.json" >/dev/null
ring_addr=$(jq -r '.body."ring-address"' "$OUTDIR/responses/node1-init.json")
ring_scope=$(jq -c '.body."ring-scope"' "$OUTDIR/responses/node1-init.json")
jq --argjson scope "$ring_scope" \
    '. + {"peer-attestation-scope": $scope}' \
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

post_json 1 "/~tpm@2.0a/verify-peer" \
    "$OUTDIR/requests/verify2.json" \
    "$OUTDIR/responses/node1-verify2.json"
jq -e '.status == 200 and .body.type == "lapee-peer-attestation" and
       (.body.verification.verified == true or
        .body.verification.verified == "true") and
       (.body.freshness.verified == true or
        .body.freshness.verified == "true") and
       .body."peer-scope"."consumer-scope"."ring-address" == "'"$ring_addr"'" and
       (.body."credential-activation".verified == true or
        .body."credential-activation".verified == "true")' \
    "$OUTDIR/responses/node1-verify2.json" >/dev/null
jq -n \
    --slurpfile att "$OUTDIR/responses/node1-verify2.json" \
    '{"peer-attestation": $att[0]}' \
    > "$OUTDIR/requests/admit2-published.json"
require_request admit2-published
post_json 1 "/~green-zone@1.0/admit" \
    "$OUTDIR/requests/admit2-published.json" \
    "$OUTDIR/responses/node1-admit2-published.json"
jq -e '.status == 200 and .body.credential."credential-blob" and
       .body."encrypted-wallet"' \
    "$OUTDIR/responses/node1-admit2-published.json" >/dev/null
echo ">> node 1 can reuse its signed peer attestation for node 2"

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
            .body."mismatch-path" == "/system/kernel/cmdline"' \
        "$OUTDIR/responses/node4-join.json" >/dev/null; then
    echo "!! node 4 rejection was not the expected template-mismatch" >&2
    cat "$OUTDIR/responses/node4-join.json" >&2
    exit 1
fi
echo ">> node 4 rejected as expected"

get_json 4 "/~green-zone@1.0/status" \
    "$OUTDIR/responses/node4-status.json"
jq -e --arg addr "$ring_addr" \
    '.status == 200 and (.body.initialized == false or .body.initialized == "false") and
     (.body."ring-address" != $addr)' \
    "$OUTDIR/responses/node4-status.json" >/dev/null
echo ">> node 4 status has no green-zone wallet"

post_json 4 "/~green-zone@1.0/sign" \
    "$OUTDIR/requests/sign4.json" \
    "$OUTDIR/responses/node4-sign.json"
jq -e '.status == 400 and .body.error == "green-zone-not-initialized"' \
    "$OUTDIR/responses/node4-sign.json" >/dev/null
if jq -e --arg addr "$ring_addr" \
        '.status == 200 and
         any([(.body.commitments? // {}), (.body.body.commitments? // {})][] |
             to_entries[]?; .value.committer == $addr)' \
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
        '.status == 200 and
         any([(.body.commitments? // {}), (.body.body.commitments? // {})][] |
             to_entries[]?; .value.committer == $addr)' \
        "$OUTDIR/responses/node$n-sign.json" >/dev/null
    echo ">> node $n signed as green-zone $ring_addr"
done

echo ""
echo "=== green-zone QEMU cluster PASSED ==="
echo "out: $OUTDIR"
echo "ring-address: $ring_addr"
