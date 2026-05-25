#!/usr/bin/env bash
# qemu-zone-remote-snp.sh -- four real SEV-SNP nodes on a remote host.
#
# This is the real-SNP companion to qemu-zone-cluster.sh. The local
# harness prepares four signed LapEE disk images, copies them to a remote SNP
# host, boots them as SEV-SNP guests, and runs the same zone admission
# flow over guest-visible URLs.

set -euo pipefail
cd "$(dirname "$0")/.."

BUILD_DIR=${LAPEE_BUILD_DIR:-build}
BUILD_IMAGE=${BUILD_IMAGE:-lapee-build:local}
DOCKER_PLATFORM=${DOCKER_PLATFORM:-}
IMAGE=${IMAGE:-$BUILD_DIR/images/lapee-runtime-no-tme-signed.img}
OUTDIR=${OUTDIR:-$BUILD_DIR/qemu-zone-remote-snp}
TARGET=${TARGET:-ssh://hb@dev-1.forward.computer}
REMOTE_WORKDIR=${REMOTE_WORKDIR:-/home/hb/lapee-measurement-tests/zone-snp}
REMOTE_QEMU=${REMOTE_QEMU:-/home/hb/hb-os/build/snp-release/usr/local/bin/qemu-system-x86_64}
REMOTE_OVMF=${REMOTE_OVMF:-/home/hb/hb-os/release/DIRECT_BOOT_OVMF.fd}
REMOTE_CBITPOS=${REMOTE_CBITPOS:-51}
REMOTE_MEMORY_MIB=${REMOTE_MEMORY_MIB:-2048}
BASE_PORT=${BASE_PORT:-19840}
TIMEOUT=${TIMEOUT:-900}
GUEST_HOST=${GUEST_HOST:-10.0.2.2}
KEEP_RUNNING=${KEEP_RUNNING:-0}
MEASUREMENT_TIMEOUT_MS=${MEASUREMENT_TIMEOUT_MS:-}
MEASUREMENT_TRACE=${MEASUREMENT_TRACE:-0}
ALLOW_REJECTED_PEER_ATTESTATION=${ALLOW_REJECTED_PEER_ATTESTATION:-0}
ZONE_TEMPLATE_MODE=${ZONE_TEMPLATE_MODE:-device}
SNP_CERT_CHAIN_PEM_FILE=${SNP_CERT_CHAIN_PEM_FILE:-}
SNP_VCEK_DER_FILE=${SNP_VCEK_DER_FILE:-}
SNP_VCEK_DER_B64=${SNP_VCEK_DER_B64:-}
NODE1_DMI_PRODUCT=${NODE1_DMI_PRODUCT:-LapEE-SNP-Zone-admit}
NODE2_DMI_PRODUCT=${NODE2_DMI_PRODUCT:-LapEE-SNP-Zone-admit}
NODE3_DMI_PRODUCT=${NODE3_DMI_PRODUCT:-LapEE-SNP-Zone-admit}
NODE4_DMI_PRODUCT=${NODE4_DMI_PRODUCT:-LapEE-SNP-Zone-reject-4}

usage() { echo "usage: TARGET=ssh://user@host IMAGE=build/images/lapee-runtime-no-tme-signed.img $0" >&2; }

while (($# > 0)); do
    case "$1" in
        --target) TARGET=$2; shift 2;;
        --image) IMAGE=$2; shift 2;;
        --outdir) OUTDIR=$2; shift 2;;
        --base-port) BASE_PORT=$2; shift 2;;
        --timeout) TIMEOUT=$2; shift 2;;
        --keep-running) KEEP_RUNNING=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "unknown arg: $1" >&2; usage; exit 2;;
    esac
done

[[ -f "$IMAGE" ]] || { echo "missing image: $IMAGE" >&2; exit 1; }
for cmd in docker jq ssh scp; do command -v "$cmd" >/dev/null 2>&1 || { echo "missing $cmd" >&2; exit 1; }; done

case "$TARGET" in
    ssh://*) HOST=${TARGET#ssh://};;
    *) echo "TARGET must be ssh://user@host" >&2; exit 2;;
esac

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"/{nodes,requests,responses}
OUTDIR="$(cd "$OUTDIR" && pwd)"
TIMINGS="$OUTDIR/timings.tsv"
printf 'step\tstart_unix\tend_unix\tseconds\n' > "$TIMINGS"

time_step() {
    local name=$1
    shift
    local start end
    start=$(date +%s)
    echo ">> [$start] $name"
    "$@"
    end=$(date +%s)
    printf '%s\t%s\t%s\t%s\n' "$name" "$start" "$end" "$((end - start))" \
        >> "$TIMINGS"
    echo ">> [$end] $name finished in $((end - start))s"
}

node_dmi_product() {
    local var="NODE${1}_DMI_PRODUCT"
    printf '%s\n' "${!var:-LapEE-SNP-Zone-node-$1}"
}

node_host_url() { printf 'http://127.0.0.1:%d' "$((BASE_PORT + $1))"; }

node_guest_url() { printf 'http://%s:%d' "$GUEST_HOST" "$((BASE_PORT + $1))"; }

prepare_image() {
    local dst="$OUTDIR/nodes/node1/disk.img"
    local cfg="$OUTDIR/nodes/node1/config.json"
    local trace_json=false
    local allow_rejected=false
    local snp_cert_chain_pem=""
    local snp_vcek_der="$SNP_VCEK_DER_B64"
    mkdir -p "$OUTDIR/nodes/node1"
    [[ "$MEASUREMENT_TRACE" == "1" ]] && trace_json=true
    [[ "$ALLOW_REJECTED_PEER_ATTESTATION" == "1" ]] && allow_rejected=true
    if [[ -n "$SNP_CERT_CHAIN_PEM_FILE" ]]; then
        [[ -f "$SNP_CERT_CHAIN_PEM_FILE" ]] || {
            echo "missing SNP_CERT_CHAIN_PEM_FILE: $SNP_CERT_CHAIN_PEM_FILE" >&2
            exit 1
        }
        snp_cert_chain_pem=$(cat "$SNP_CERT_CHAIN_PEM_FILE")
    fi
    if [[ -n "$SNP_VCEK_DER_FILE" ]]; then
        [[ -f "$SNP_VCEK_DER_FILE" ]] || {
            echo "missing SNP_VCEK_DER_FILE: $SNP_VCEK_DER_FILE" >&2
            exit 1
        }
        snp_vcek_der=$(
            python3 - "$SNP_VCEK_DER_FILE" <<'PY'
import base64, pathlib, sys
print(base64.urlsafe_b64encode(pathlib.Path(sys.argv[1]).read_bytes()).decode().rstrip("="))
PY
        )
    fi
    cp "$IMAGE" "$dst"
    jq -n \
        --argjson trace "$trace_json" \
        --argjson allow_rejected "$allow_rejected" \
        --arg snp_cert_chain_pem "$snp_cert_chain_pem" \
        --arg snp_vcek_der "$snp_vcek_der" \
        --arg measurement_timeout_ms "$MEASUREMENT_TIMEOUT_MS" '
        {
          "measurement-device": "snp@1.0",
          "allow-rejected-peer-attestation": $allow_rejected,
          "peer-http-connect-timeout-ms": 600000,
          "peer-http-timeout-ms": 600000,
          "zone-init-allow": true
        }
        + (if $measurement_timeout_ms != "" then
             {"measurement-timeout-ms": ($measurement_timeout_ms | tonumber)}
           else {} end)
        + (if $snp_cert_chain_pem != "" then
             {"snp-cert-chain-pem": $snp_cert_chain_pem}
           else {} end)
        + (if $snp_vcek_der != "" then
             {"snp-vcek-der": $snp_vcek_der}
           else {} end)
        + (if $trace then {"measurement-trace": true} else {} end)
    ' > "$cfg"
    docker run --rm $DOCKER_PLATFORM \
        -v "$OUTDIR":/work \
        -w /work \
        "$BUILD_IMAGE" \
        bash -euo pipefail -c '
            DISK=/work/nodes/node1/disk.img
            CFG=/work/nodes/node1/config.json
            START=$(parted --script --machine "$DISK" \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$2); print \$2}")
            SECT=$(parted --script --machine "$DISK" \
                unit s print | awk -F: "/^1:/ {gsub(\"s\",\"\",\$4); print \$4}")
            dd if="$DISK" of=/tmp/esp.img \
                bs=512 skip=$START count=$SECT status=none
            mmd -i /tmp/esp.img -D s ::/EFI/boot 2>/dev/null || true
            mcopy -i /tmp/esp.img -o "$CFG" ::/EFI/boot/config.json
            dd if=/tmp/esp.img of="$DISK" \
                bs=512 seek=$START count=$SECT conv=notrunc status=none
        '
}

install_remote_helper() {
    ssh "$HOST" "mkdir -p '$REMOTE_WORKDIR/nodes'"
    scp scripts/materialize-hb-json.py \
        "$HOST:$REMOTE_WORKDIR/materialize-hb-json.py" >/dev/null
    ssh "$HOST" "cat > '$REMOTE_WORKDIR/run-snp-cluster.sh'" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

cmd=${1:?start-node|stop-node|stop-all|status}
workdir=${2:?workdir}

stop_node() {
    local node=$1
    local node_dir="$workdir/nodes/node$node"
    local pidfile="$node_dir/qemu.pid"
    local monitor="$node_dir/qemu.mon"
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
    stop-node)
        stop_node "${3:?node}"
        ;;
    stop-all)
        for node in 1 2 3 4; do
            stop_node "$node"
        done
        ;;
    status)
        for node in 1 2 3 4; do
            pidfile="$workdir/nodes/node$node/qemu.pid"
            if [[ -s "$pidfile" ]] && sudo kill -0 "$(cat "$pidfile")" 2>/dev/null; then
                echo "node$node running pid=$(cat "$pidfile")"
            else
                echo "node$node stopped"
            fi
        done
        ;;
    start-node)
        node=${3:?node}
        port=${4:?port}
        qemu=${5:?qemu}
        ovmf=${6:?ovmf}
        cbitpos=${7:?cbitpos}
        memory_mib=${8:?memory}
        dmi_product=${9:?dmi-product}
        node_dir="$workdir/nodes/node$node"
        disk="$node_dir/disk.img"
        monitor="$node_dir/qemu.mon"
        serial="$node_dir/serial.log"
        mkdir -p "$node_dir"
        [[ -f "$disk" ]] || { echo "missing disk: $disk" >&2; exit 1; }
        stop_node "$node"
        rm -f "$serial" "$monitor" "$node_dir/qemu.log"
        sudo "$qemu" \
            -enable-kvm \
            -cpu EPYC-v4 \
            -machine q35,memory-encryption=sev0,vmport=off \
            -m "${memory_mib}M" \
            -smp 2,maxcpus=2 \
            -object "memory-backend-memfd,id=ram${node},size=${memory_mib}M,share=true,prealloc=false" \
            -machine "memory-backend=ram${node}" \
            -object "sev-snp-guest,id=sev0,policy=0x30000,cbitpos=${cbitpos},reduced-phys-bits=1" \
            -bios "$ovmf" \
            -smbios "type=1,product=${dmi_product}" \
            -drive "file=$disk,if=none,id=disk0,format=raw" \
            -device virtio-scsi-pci,id=scsi0,disable-legacy=on,iommu_platform=true \
            -device scsi-hd,drive=disk0,bootindex=1 \
            -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${port}-:8734" \
            -device virtio-net-pci,disable-legacy=on,iommu_platform=true,netdev=net0,romfile= \
            -monitor "unix:$monitor,server,nowait" \
            -serial "file:$serial" \
            -display none \
            -no-reboot \
            > "$node_dir/qemu.log" 2>&1 &
        echo $! > "$node_dir/qemu.pid"
        ;;
    *)
        echo "unknown command: $cmd" >&2
        exit 2
        ;;
esac
REMOTE
    ssh "$HOST" "chmod +x '$REMOTE_WORKDIR/run-snp-cluster.sh'"
}

copy_images() {
    ssh "$HOST" "mkdir -p '$REMOTE_WORKDIR/nodes/node1'"
    scp "$OUTDIR/nodes/node1/disk.img" \
        "$HOST:$REMOTE_WORKDIR/nodes/node1/disk.img" >/dev/null
    for n in 1 2 3 4; do
        ssh "$HOST" "mkdir -p '$REMOTE_WORKDIR/nodes/node$n'"
    done
    for n in 2 3 4; do
        ssh "$HOST" \
            "cp '$REMOTE_WORKDIR/nodes/node1/disk.img' '$REMOTE_WORKDIR/nodes/node$n/disk.img'"
    done
}

remote_stop_all() {
    ssh "$HOST" "'$REMOTE_WORKDIR/run-snp-cluster.sh' stop-all '$REMOTE_WORKDIR'" \
        >/dev/null 2>&1 || true
}

cleanup() {
    if [[ "$KEEP_RUNNING" = "1" ]]; then
        echo ">> KEEP_RUNNING=1; leaving remote SNP nodes up"
        return
    fi
    remote_stop_all
}
trap cleanup EXIT

remote_start_nodes() {
    remote_stop_all
    for n in 1 2 3 4; do
        ssh "$HOST" \
            "'$REMOTE_WORKDIR/run-snp-cluster.sh' start-node '$REMOTE_WORKDIR' '$n' '$((BASE_PORT + n))' '$REMOTE_QEMU' '$REMOTE_OVMF' '$REMOTE_CBITPOS' '$REMOTE_MEMORY_MIB' '$(node_dmi_product "$n")'"
        echo ">> node $n started: host=$(node_host_url "$n") guest=$(node_guest_url "$n") dmi-product=$(node_dmi_product "$n")"
    done
}

remote_get() {
    local n=$1
    local path=$2
    local out=$3
    local base
    base=$(node_host_url "$n")
    ssh "$HOST" \
        "set -euo pipefail; tmp=\$(mktemp '$REMOTE_WORKDIR/.response.XXXXXX.json'); trap 'rm -f \"\$tmp\"' EXIT; curl --max-time 300 -sSL -H 'accept: application/json' -H 'accept-bundle: true' '$base$path' > \"\$tmp\"; python3 '$REMOTE_WORKDIR/materialize-hb-json.py' '$base' \"\$tmp\"; cat \"\$tmp\"" \
        > "$out"
}

remote_post() {
    local n=$1
    local path=$2
    local req=$3
    local out=$4
    local base
    base=$(node_host_url "$n")
    ssh "$HOST" \
        "set -euo pipefail; tmp=\$(mktemp '$REMOTE_WORKDIR/.response.XXXXXX.json'); trap 'rm -f \"\$tmp\"' EXIT; curl --max-time 300 -sSL -X POST -H 'content-type: application/json' -H 'accept: application/json' -H 'accept-bundle: true' --data-binary @- '$base$path' > \"\$tmp\"; python3 '$REMOTE_WORKDIR/materialize-hb-json.py' '$base' \"\$tmp\"; cat \"\$tmp\"" \
        < "$req" > "$out"
}

wait_node() {
    local n=$1
    local deadline=$((SECONDS + TIMEOUT))
    until ssh "$HOST" \
            "curl --max-time 10 -fsS '$(node_host_url "$n")/~measurement@1.0/info' >/dev/null 2>/dev/null"
    do
        if (( SECONDS >= deadline )); then
            ssh "$HOST" "tail -200 '$REMOTE_WORKDIR/nodes/node$n/serial.log' 2>/dev/null || true" \
                > "$OUTDIR/nodes/node$n/serial-timeout.log" || true
            echo "timed out waiting for node $n; serial: $OUTDIR/nodes/node$n/serial-timeout.log" >&2
            return 1
        fi
        sleep 2
    done
    remote_get "$n" "/~measurement@1.0/info" \
        "$OUTDIR/responses/node$n-info.json"
    remote_get "$n" "/~measurement@1.0/boot" \
        "$OUTDIR/responses/node$n-boot-attestation.json"
    echo ">> node $n ready"
}

wait_all_nodes() {
    for n in 1 2 3 4; do
        wait_node "$n"
    done
}

assert_security_properties() {
    jq -n \
        --slurpfile n1 "$OUTDIR/responses/node1-boot-attestation.json" \
        --slurpfile n2 "$OUTDIR/responses/node2-boot-attestation.json" \
        --slurpfile n3 "$OUTDIR/responses/node3-boot-attestation.json" \
        --slurpfile n4 "$OUTDIR/responses/node4-boot-attestation.json" '
        def measurement($att):
            if $att.body.type == "lapee-measurement" then $att.body
            elif $att.type == "lapee-measurement" then $att
            else $att end;
        def props($node; $att): {
            node: $node,
            cmdline: measurement($att).body.system.kernel.cmdline,
            boot_image_id: measurement($att).body.system.boot.image.id,
            boot_image_provenance:
                measurement($att).body.system.boot.image.provenance,
            node_initialized: measurement($att).body.node.initialized,
            access_remote_cache_for_client:
                measurement($att).body.node."access-remote-cache-for-client",
            load_remote_devices: measurement($att).body.node."load-remote-devices",
            memtotal_kb: measurement($att).body.system.memory.meminfo.memtotal.value,
            dmi_product: measurement($att).body.system.firmware.dmi.fields."product-name",
            measurement_device: measurement($att)."measurement-device",
            evidence_type: measurement($att).evidence.type,
            recipient_key_id: measurement($att)."secret-recipient"."key-id",
            recipient_public: (
                measurement($att)."secret-recipient"."public-material"."x25519-public-key" //
                measurement($att)."secret-recipient"."public-material+link")
        };
        [props(1; $n1[0]), props(2; $n2[0]),
         props(3; $n3[0]), props(4; $n4[0])]
        | {
            nodes: .,
            distinct_cmdlines: ([.[].cmdline] | unique | length),
            distinct_boot_image_id: ([.[].boot_image_id] | unique | length),
            distinct_memtotal_kb: ([.[].memtotal_kb] | unique | length),
            distinct_dmi_products: ([.[].dmi_product] | unique | length),
            distinct_recipient_key_id: ([.[].recipient_key_id] | unique | length),
            distinct_recipient_public: ([.[].recipient_public] | unique | length)
          }' > "$OUTDIR/responses/security-properties.json"
    jq -e '
        def falsy: . == false or . == "false";
        .distinct_cmdlines == 1 and
        .distinct_boot_image_id == 1 and
        all(.nodes[]; (.boot_image_id | type == "string" and length > 0) and
            .boot_image_provenance == "executed-kernel-cmdline" and
            .node_initialized == "permanent" and
            (.access_remote_cache_for_client | falsy) and
            (.load_remote_devices | falsy) and
            ((.cmdline | test("lapee.mode=debug|lapee.debug|LAPEE_HB_DIAG")) | not)) and
        all(.nodes[]; (.memtotal_kb | type == "number" and . > 0)) and
        .distinct_dmi_products == 2 and
        .distinct_recipient_key_id == 4 and
        .distinct_recipient_public == 4 and
        [.nodes[].measurement_device] == ["snp@1.0","snp@1.0","snp@1.0","snp@1.0"] and
        [.nodes[].evidence_type] == ["lapee-snp-evidence","lapee-snp-evidence","lapee-snp-evidence","lapee-snp-evidence"] and
        .nodes[0].dmi_product == .nodes[1].dmi_product and
        .nodes[1].dmi_product == .nodes[2].dmi_product and
        .nodes[3].dmi_product != .nodes[0].dmi_product
    ' "$OUTDIR/responses/security-properties.json" >/dev/null
    echo ">> observed real SNP boot-attested properties"
    jq -c '.nodes[]' "$OUTDIR/responses/security-properties.json"
}

require_request() {
    local name=$1
    local file="$OUTDIR/requests/$name.json"
    [[ -s "$file" ]] || {
        echo "missing generated request: $file" >&2
        exit 1
    }
}

generate_requests() {
    ZONE_TEMPLATE_MODE="$ZONE_TEMPLATE_MODE" \
    ZONE_TEMPLATE_LIST="${ZONE_TEMPLATE_LIST:-}" \
        python3 scripts/qemu-zone-requests.py \
            "$OUTDIR" "$BASE_PORT" "$GUEST_HOST"
    for req in init verify2 admit2 admit3 admit4 join2 join3 join4; do
        require_request "$req"
    done
}

pin_ring_address() {
    local ring_addr=$1
    local ring_reference=$2
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
}

run_zone_flow() {
    remote_post 1 "/~zone@1.0/init" \
        "$OUTDIR/requests/init.json" \
        "$OUTDIR/responses/node1-init.json"
    jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true") and
           (.body."zone"."ring-address" | type == "string" and length > 0)' \
        "$OUTDIR/responses/node1-init.json" >/dev/null
    local ring_addr ring_reference
    ring_addr=$(jq -r '.body."zone"."ring-address"' "$OUTDIR/responses/node1-init.json")
    ring_reference=$(jq -c '.body."zone"."ring-reference"' "$OUTDIR/responses/node1-init.json")
    pin_ring_address "$ring_addr" "$ring_reference"
    echo ">> node 1 initialized zone $ring_addr"

    remote_post 1 "/~measurement@1.0/verify-peer" \
        "$OUTDIR/requests/verify2.json" \
        "$OUTDIR/responses/node1-verify2.json"
    jq -e '.status == 200 and .body.type == "zone-peer-attestation" and
           (.body."boot-verified" == true or
            .body."boot-verified" == "true") and
           (.body."fresh-verified" == true or
            .body."fresh-verified" == "true") and
           (.body."freshness-verified" == true or
            .body."freshness-verified" == "true") and
           .body."peer-scope-ring-address" == "'"$ring_addr"'" and
           (.body."credential-activation-verified" == true or
            .body."credential-activation-verified" == "true")' \
        "$OUTDIR/responses/node1-verify2.json" >/dev/null

    remote_post 1 "/~zone@1.0/admit" \
        "$OUTDIR/requests/admit2.json" \
        "$OUTDIR/responses/node1-admit2.json"
    jq -e '.status == 200 and
           .body.credential.type == "lapee-wrapped-secret" and
           .body.credential."measurement-device" == "snp@1.0" and
           .body."encrypted-wallet".ciphertext' \
        "$OUTDIR/responses/node1-admit2.json" >/dev/null
    echo ">> node 1 can admit node 2"

    for n in 2 3; do
        remote_post "$n" "/~zone@1.0/join" \
            "$OUTDIR/requests/join$n.json" \
            "$OUTDIR/responses/node$n-join.json"
        jq -e '.status == 200 and (.body.initialized == true or .body.initialized == "true")' \
            "$OUTDIR/responses/node$n-join.json" >/dev/null
        echo ">> node $n joined zone"
    done

    jq -n '{"name":"second-zone"}' > "$OUTDIR/requests/init-second-zone.json"
    remote_post 2 "/~zone@1.0/init" \
        "$OUTDIR/requests/init-second-zone.json" \
        "$OUTDIR/responses/node2-init-second-zone.json"
    jq -e '.status == 400 and .body.error == "zone-limit-exceeded"' \
        "$OUTDIR/responses/node2-init-second-zone.json" >/dev/null
    echo ">> node 2 cannot install a second zone by default"

    remote_post 4 "/~zone@1.0/join" \
        "$OUTDIR/requests/join4.json" \
        "$OUTDIR/responses/node4-join.json"
    if ! jq -e '.status == 400 and .body.error == "template-mismatch" and
                (.body."mismatch-path" == "/body/system/firmware/dmi/fields/product-name" or
                 any(.body.mismatches[]?; ."mismatch-path" == "/body/system/firmware/dmi/fields/product-name"))' \
            "$OUTDIR/responses/node4-join.json" >/dev/null; then
        echo "node 4 rejection was not the expected template-mismatch" >&2
        cat "$OUTDIR/responses/node4-join.json" >&2
        exit 1
    fi
    echo ">> node 4 rejected as expected"

    for n in 1 2 3; do
        remote_get "$n" "/~zone@1.0/status?name=book-shelf" \
            "$OUTDIR/responses/node$n-status.json"
        jq -e --arg addr "$ring_addr" \
            '.status == 200 and
             .body.identity == "zone/book-shelf" and
             .body."zone"."ring-address" == $addr' \
            "$OUTDIR/responses/node$n-status.json" >/dev/null
    done
    remote_get 4 "/~zone@1.0/status" \
        "$OUTDIR/responses/node4-status.json"
    jq -e \
        '.status == 200 and (.body.initialized == false or .body.initialized == "false") and
         (.body."zones" | has("book-shelf") | not)' \
        "$OUTDIR/responses/node4-status.json" >/dev/null
    echo ">> node 4 status has no zone identity"

    remote_get 4 "/~zone@1.0/member=book-shelf" \
        "$OUTDIR/responses/node4-member.json"
    jq -e '.status == 400 and .body.error == "zone-not-initialized"' \
        "$OUTDIR/responses/node4-member.json" >/dev/null
    echo ">> node 4 cannot produce a zone membership proof"

    for n in 1 2 3; do
        member_addr=$(jq -r '
            def measurement:
                if .body.type == "lapee-measurement" then .body
                elif .type == "lapee-measurement" then .
                else . end;
            measurement.body.node.address
        ' \
            "$OUTDIR/responses/node$n-boot-attestation.json")
        remote_get "$n" \
            "/~zone@1.0/member=book-shelf?membership-codec-device=ans104@1.0&target=remote-snp-zone-index" \
            "$OUTDIR/responses/node$n-member.json"
        jq -e --arg zone "book-shelf" \
              --arg identity "zone/book-shelf" \
              --arg ring "$ring_addr" \
              --arg addr "$member_addr" \
              --arg target "remote-snp-zone-index" '
            .status == 200 and
            .body.type == "zone-membership-proof" and
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

    printf '%s\n' "$ring_addr" > "$OUTDIR/ring-address.txt"
}

echo "=== remote SNP zone QEMU cluster ==="
echo "git: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git status --short 2>/dev/null || true
echo "target: $TARGET"
echo "remote workdir: $REMOTE_WORKDIR"
echo "base-port: $BASE_PORT"
echo "guest-host: $GUEST_HOST"
echo "image: $IMAGE"
ls -lhT "$IMAGE" 2>/dev/null || ls -lh "$IMAGE"

total_start=$(date +%s)
time_step "prepare-local-images" prepare_image
time_step "install-remote-helper" install_remote_helper
time_step "copy-images-to-remote" copy_images
time_step "start-remote-snp-nodes" remote_start_nodes
time_step "wait-measurement-boot" wait_all_nodes
time_step "assert-security-properties" assert_security_properties
time_step "generate-zone-requests" generate_requests
time_step "zone-admission-flow" run_zone_flow
total_end=$(date +%s)
printf '%s\t%s\t%s\t%s\n' "total" "$total_start" "$total_end" \
    "$((total_end - total_start))" >> "$TIMINGS"

echo ""
echo "=== remote SNP zone QEMU cluster PASSED ==="
echo "target: $TARGET"
echo "out: $OUTDIR"
echo "ring-address: $(cat "$OUTDIR/ring-address.txt")"
echo "timings:"
cat "$TIMINGS"
