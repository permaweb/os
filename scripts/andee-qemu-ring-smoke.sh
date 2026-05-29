#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
LAPEE_BUILD_DIR=${LAPEE_BUILD_DIR:-$ROOT/build}
OUT=${OUTDIR:-$LAPEE_BUILD_DIR/andee-qemu-ring}
QEMU_OUT="$OUT/qemu"
BASE_PORT=${BASE_PORT:-19280}
ANDEE_HOST_PORT=${ANDEE_HOST_PORT:-28738}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-240}
TIMEOUT=${TIMEOUT:-1200}
ANDROID_HOST_ALIAS=${ANDROID_HOST_ALIAS:-10.0.2.2}
QEMU_HOST_ALIAS=${QEMU_HOST_ALIAS:-10.0.2.2}
GUEST_HOST=${GUEST_HOST:-$(ipconfig getifaddr en0 2>/dev/null || echo 10.0.2.2)}
ZONE_NAME=${ZONE_NAME:-andee-qemu-ring}
MARKER="andee-qemu-ring-$(date +%Y%m%d%H%M%S)"
DEFAULT_IMG="$LAPEE_BUILD_DIR/images/lapee-runtime-no-tme-mixed-signed.img"
IMG=${IMG:-$DEFAULT_IMG}
REBUILD_QEMU_IMAGE=${REBUILD_QEMU_IMAGE:-1}
REBUILD_ANDROID=${REBUILD_ANDROID:-1}

ANDROID_ROOT="$ROOT/arch/android"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/homebrew/share/android-commandlinetools}"
ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$JAVA_HOME/bin:$PATH"
ADB=${ADB:-$ANDROID_SDK_ROOT/platform-tools/adb}
APK=${APK:-$ANDROID_ROOT/android/app/build/outputs/apk/debug/app-debug.apk}
PACKAGE=org.permaweb.andee
REMOTE_CONFIG=/data/local/tmp/andee-qemu-ring-config.json
QEMU_PID=

cleanup() {
    if [[ -n "${QEMU_PID:-}" ]]; then
        kill "$QEMU_PID" >/dev/null 2>&1 || true
        wait "$QEMU_PID" >/dev/null 2>&1 || true
    fi
    "$ADB" forward --remove "tcp:$ANDEE_HOST_PORT" >/dev/null 2>&1 || true
    "$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required tool: $1" >&2
        exit 1
    }
}

urlencode() {
    python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

materialize() {
    local base=$1 file=$2
    scripts/materialize-hb-json.py "$base" "$file"
}

post_json() {
    local base=$1 path=$2 req=$3 out=$4
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -X POST \
        -H "content-type: application/json" \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        --data-binary "@$req" \
        "$base$path" \
        -o "$out"
    materialize "$base" "$out"
}

get_json() {
    local base=$1 path=$2 out=$3
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -H "accept: application/json" \
        -H "accept-bundle: true" \
        "$base$path" \
        -o "$out"
    materialize "$base" "$out"
}

wait_for_file() {
    local file=$1 label=$2 deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        [[ -f "$file" ]] && return 0
        if [[ -n "${QEMU_PID:-}" ]] && ! kill -0 "$QEMU_PID" >/dev/null 2>&1; then
            echo "$label exited before ready" >&2
            tail -120 "$OUT/qemu-zone-boot.log" >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timeout waiting for $label" >&2
    return 1
}

wait_for_andee_http() {
    local base=$1 deadline=$((SECONDS + TIMEOUT))
    while (( SECONDS < deadline )); do
        if curl -fsS --max-time 30 \
                -H "accept: application/json" \
                "$base/~measurement@1.0/info" \
                -o "$OUT/andee-ready-probe.json" 2>/dev/null; then
            return 0
        fi
        "$ADB" shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
            > "$OUT/andee-hyperbeam.stdout" 2>/dev/null || true
        "$ADB" shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
            > "$OUT/andee-hyperbeam.stderr" 2>/dev/null || true
        sleep 2
    done
    echo "timeout waiting for AndEE HTTP at $base" >&2
    tail -80 "$OUT/andee-hyperbeam.stdout" >&2 || true
    tail -80 "$OUT/andee-hyperbeam.stderr" >&2 || true
    return 1
}

member_count() {
    jq -r '.body."zone".members
           | with_entries(select(.key != "commitments" and .key != "device"))
           | keys | length' "$1"
}

node_address() {
    jq -r '
        def measurement:
            if .body.type == "lapee-measurement" then .body
            elif .type == "lapee-measurement" then .
            else . end;
        measurement.body.node.address
    ' "$1"
}

require_tool curl
require_tool jq
require_tool python3
require_tool "$ADB"

rm -rf "$OUT"
mkdir -p "$OUT"/requests "$OUT"/responses

if [[ "$REBUILD_ANDROID" = "1" || ! -f "$APK" ]]; then
    make -C "$ANDROID_ROOT" android-build
fi
[[ -f "$APK" ]] || { echo "APK missing: $APK" >&2; exit 1; }

"$ADB" get-state >/dev/null 2>&1 || {
    echo "no active adb device/emulator; run: make -C arch/android emulator-start" >&2
    exit 1
}

if [[ "$REBUILD_QEMU_IMAGE" = "1" && "$IMG" = "$DEFAULT_IMG" ]]; then
    rm -f "$IMG"
fi

echo "=== mixed AndEE + QEMU ring ==="
echo "out: $OUT"
echo "qemu image: $IMG"
echo "qemu guest host: $GUEST_HOST"
echo "android host alias: $ANDROID_HOST_ALIAS"
echo "qemu host alias: $QEMU_HOST_ALIAS"
echo "andee host port: $ANDEE_HOST_PORT"

LAPEE_BUILD_DIR="$LAPEE_BUILD_DIR" \
OUTDIR="$QEMU_OUT" \
IMG="$IMG" \
BASE_PORT="$BASE_PORT" \
TIMEOUT="$TIMEOUT" \
GUEST_HOST="$GUEST_HOST" \
QEMU_ZONE_PHASE=boot-only \
QEMU_ZONE_NODE_COUNT=2 \
ALLOW_REJECTED_PEER_ATTESTATION=1 \
    ./scripts/qemu-zone-cluster.sh > "$OUT/qemu-zone-boot.log" 2>&1 &
QEMU_PID=$!
wait_for_file "$QEMU_OUT/ready" "QEMU zone boot"

ANDEE_GUEST_URL="http://$QEMU_HOST_ALIAS:$ANDEE_HOST_PORT"
ANDEE_HOST_URL="http://127.0.0.1:$ANDEE_HOST_PORT"
QEMU1_HOST_URL="http://127.0.0.1:$((BASE_PORT + 1))"
QEMU2_HOST_URL="http://127.0.0.1:$((BASE_PORT + 2))"
QEMU1_GUEST_URL="http://$GUEST_HOST:$((BASE_PORT + 1))"
QEMU2_GUEST_URL="http://$GUEST_HOST:$((BASE_PORT + 2))"
QEMU1_ANDROID_URL="http://$ANDROID_HOST_ALIAS:$((BASE_PORT + 1))"

python3 - <<'PY' "$OUT/andee-next-boot-config.json" "$MARKER"
import json, pathlib, sys

path, marker = sys.argv[1:]
pathlib.Path(path).write_text(json.dumps({
    "andee-test-marker": marker,
    "zone-init-allow": True,
    "allow-rejected-peer-attestation": True,
}, indent=2) + "\n")
PY

"$ADB" shell "run-as $PACKAGE sh -c 'kill \$(pidof beam.smp 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof erlexec 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof libandee_hyperbeam.so 2>/dev/null) 2>/dev/null || true'" \
    >/dev/null 2>&1 || true
"$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" uninstall "$PACKAGE" >/dev/null 2>&1 || true
if ! "$ADB" install -r "$APK" > "$OUT/andee-install.txt" 2>&1; then
    "$ADB" uninstall "$PACKAGE" >> "$OUT/andee-install.txt" 2>&1 || true
    "$ADB" install -r "$APK" >> "$OUT/andee-install.txt" 2>&1
fi
"$ADB" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
"$ADB" push "$OUT/andee-next-boot-config.json" "$REMOTE_CONFIG" \
    > "$OUT/andee-config-push.txt"
"$ADB" shell "run-as $PACKAGE sh -c 'mkdir -p no_backup/boot-config no_backup/run; \
    cp $REMOTE_CONFIG no_backup/boot-config/next.json; \
    rm -f no_backup/boot-config/active.json no_backup/boot-config/effective.json; \
    rm -f no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr'" \
    > "$OUT/andee-config-stage.txt"
"$ADB" shell rm -f "$REMOTE_CONFIG" >/dev/null 2>&1 || true
"$ADB" forward --remove "tcp:$ANDEE_HOST_PORT" >/dev/null 2>&1 || true
"$ADB" forward "tcp:$ANDEE_HOST_PORT" tcp:8734 > "$OUT/andee-adb-forward.txt"
"$ADB" shell am start -W -n "$PACKAGE/.OrnamentActivity" > "$OUT/andee-activity.txt"
"$ADB" shell am start-foreground-service -n "$PACKAGE/.AndeeService" \
    > "$OUT/andee-service-start.txt" 2>&1 || true
wait_for_andee_http "$ANDEE_HOST_URL"

get_json "$ANDEE_HOST_URL" "/~measurement@1.0/boot" \
    "$OUT/responses/andee-boot-attestation.json"

python3 - <<'PY' \
    "$QEMU_OUT" \
    "$OUT/responses/andee-boot-attestation.json" \
    "$OUT/requests" \
    "$QEMU1_GUEST_URL" \
    "$QEMU2_GUEST_URL" \
    "$QEMU1_ANDROID_URL" \
    "$ANDEE_GUEST_URL" \
    "$ZONE_NAME"
import json, pathlib, sys

qemu_out = pathlib.Path(sys.argv[1])
andee_boot_path = pathlib.Path(sys.argv[2])
requests = pathlib.Path(sys.argv[3])
qemu1_guest, qemu2_guest, qemu1_android, andee_guest, zone = sys.argv[4:]

def load(path):
    return json.loads(pathlib.Path(path).read_text())

def measurement(doc):
    body = doc.get("body")
    if isinstance(body, dict) and body.get("type") == "lapee-measurement":
        return body
    if doc.get("type") == "lapee-measurement":
        return doc
    raise SystemExit(f"{doc!r} is not a lapee measurement")

qemu = measurement(load(qemu_out / "responses/node1-boot-attestation.json"))
qemu_body = qemu["body"]
qemu_evidence = qemu.get("evidence", {})
qemu_template = {
    "measurement-device": qemu["measurement-device"],
    "body": {
        "system": {
            "firmware": {
                "dmi": {
                    "fields": {
                        "product-name": qemu_body["system"]["firmware"]["dmi"]["fields"]["product-name"]
                    }
                }
            }
        }
    },
}
if "ek-cert-source" in qemu_evidence:
    qemu_template["evidence"] = {
        "ek-cert-source": {"kind": qemu_evidence["ek-cert-source"]["kind"]}
    }
elif "type" in qemu_evidence:
    qemu_template["evidence"] = {"type": qemu_evidence["type"]}

andee = measurement(load(andee_boot_path))
andee_system = andee["body"]["system"]
andee_system_template = {
    "platform": andee_system.get("platform"),
}
andee_app = andee_system.get("app", {})
if andee_app.get("package-name"):
    andee_system_template["app"] = {
        "package-name": andee_app["package-name"]
    }
runtime = andee_system.get("runtime", {})
if runtime.get("android-abi"):
    andee_system_template["runtime"] = {
        "android-abi": runtime["android-abi"]
    }
andee_template = {
    "measurement-device": "andee@1.0",
    "evidence": {"type": andee.get("evidence", {}).get("type", "andee-android-evidence")},
    "body": {"system": andee_system_template},
}

(requests / "init.json").write_text(json.dumps({
    "name": zone,
    "self-url": qemu1_guest,
    "templates": [qemu_template, andee_template],
}))
(requests / "join-qemu2.json").write_text(json.dumps({
    "name": zone,
    "peer-url": qemu1_guest,
    "self-url": qemu2_guest,
}))
(requests / "join-andee.json").write_text(json.dumps({
    "name": zone,
    "peer-url": qemu1_android,
    "self-url": andee_guest,
    "allow-rejected-peer-attestation": True,
}))
PY

post_json "$QEMU1_HOST_URL" "/~zone@1.0/init" \
    "$OUT/requests/init.json" \
    "$OUT/responses/qemu1-init.json"
jq -e '.status == 200 and
       (.body.initialized == true or .body.initialized == "true") and
       (.body."zone"."ring-address" | type == "string" and length > 0)' \
    "$OUT/responses/qemu1-init.json" >/dev/null
RING_ADDRESS=$(jq -r '.body."zone"."ring-address"' "$OUT/responses/qemu1-init.json")
RING_REFERENCE=$(jq -c '.body."zone"."ring-reference"' "$OUT/responses/qemu1-init.json")
echo ">> QEMU node 1 initialized mixed ring $RING_ADDRESS"

for req in join-qemu2 join-andee; do
    jq --arg ring "$RING_ADDRESS" \
        '. + {"expected-ring-address": $ring}' \
        "$OUT/requests/$req.json" \
        > "$OUT/requests/$req.pinned.json"
    mv "$OUT/requests/$req.pinned.json" "$OUT/requests/$req.json"
done

jq -n \
    --arg url "$ANDEE_GUEST_URL" \
    --argjson scope "$RING_REFERENCE" \
    '{
        "url": $url,
        "peer-attestation-scope": $scope,
        "allow-rejected-peer-attestation": true
    }' > "$OUT/requests/verify-andee.json"
post_json "$QEMU1_HOST_URL" "/~measurement@1.0/verify-peer" \
    "$OUT/requests/verify-andee.json" \
    "$OUT/responses/qemu1-verify-andee.json"
jq -e '.status == 200 and .body.type == "zone-peer-attestation"' \
    "$OUT/responses/qemu1-verify-andee.json" >/dev/null
echo ">> QEMU node 1 verified AndEE peer attestation"

post_json "$QEMU2_HOST_URL" "/~zone@1.0/join" \
    "$OUT/requests/join-qemu2.json" \
    "$OUT/responses/qemu2-join.json"
jq -e '.status == 200 and
       (.body.initialized == true or .body.initialized == "true")' \
    "$OUT/responses/qemu2-join.json" >/dev/null
echo ">> QEMU node 2 joined through QEMU node 1"

post_json "$ANDEE_HOST_URL" "/~zone@1.0/join" \
    "$OUT/requests/join-andee.json" \
    "$OUT/responses/andee-join.json"
jq -e '.status == 200 and
       (.body.initialized == true or .body.initialized == "true")' \
    "$OUT/responses/andee-join.json" >/dev/null
echo ">> AndEE joined through QEMU node 1"

ENCODED_ZONE=$(urlencode "$ZONE_NAME")
for node in qemu1 qemu2 andee; do
    case "$node" in
        qemu1) base=$QEMU1_HOST_URL ;;
        qemu2) base=$QEMU2_HOST_URL ;;
        andee) base=$ANDEE_HOST_URL ;;
    esac
    get_json "$base" "/~zone@1.0/status?name=$ENCODED_ZONE" \
        "$OUT/responses/$node-status.json"
    jq -e --arg ring "$RING_ADDRESS" --arg zone "$ZONE_NAME" \
        '.status == 200 and
         .body.name == $zone and
         .body."zone"."ring-address" == $ring' \
        "$OUT/responses/$node-status.json" >/dev/null
done

[[ "$(member_count "$OUT/responses/qemu1-status.json")" = "3" ]] || {
    echo "QEMU node 1 did not see three ring members" >&2
    jq '.body."zone".members | keys' "$OUT/responses/qemu1-status.json" >&2
    exit 1
}
[[ "$(member_count "$OUT/responses/qemu2-status.json")" = "2" ]] || {
    echo "QEMU node 2 did not preserve its two-member admission snapshot" >&2
    jq '.body."zone".members | keys' "$OUT/responses/qemu2-status.json" >&2
    exit 1
}
[[ "$(member_count "$OUT/responses/andee-status.json")" = "3" ]] || {
    echo "AndEE did not receive the three-member ring snapshot" >&2
    jq '.body."zone".members | keys' "$OUT/responses/andee-status.json" >&2
    exit 1
}

cp "$QEMU_OUT/responses/node1-boot-attestation.json" \
    "$OUT/responses/qemu1-boot-attestation.json"
cp "$QEMU_OUT/responses/node2-boot-attestation.json" \
    "$OUT/responses/qemu2-boot-attestation.json"
QEMU1_ADDRESS=$(node_address "$OUT/responses/qemu1-boot-attestation.json")
QEMU2_ADDRESS=$(node_address "$OUT/responses/qemu2-boot-attestation.json")
ANDEE_ADDRESS=$(node_address "$OUT/responses/andee-boot-attestation.json")

for node in qemu1 qemu2 andee; do
    case "$node" in
        qemu1) base=$QEMU1_HOST_URL; expected_address=$QEMU1_ADDRESS ;;
        qemu2) base=$QEMU2_HOST_URL; expected_address=$QEMU2_ADDRESS ;;
        andee) base=$ANDEE_HOST_URL; expected_address=$ANDEE_ADDRESS ;;
    esac
    get_json "$base" \
        "/~zone@1.0/member=$ENCODED_ZONE?membership-codec-device=ans104@1.0&target=andee-qemu-ring" \
        "$OUT/responses/$node-member.json"
    jq -e --arg zone "$ZONE_NAME" \
          --arg ring "$RING_ADDRESS" \
          --arg addr "$expected_address" \
          --arg target "andee-qemu-ring" '
        .status == 200 and
        .body.type == "zone-membership-proof" and
        .body.address == $addr and
        .body."member-of" == $zone and
        .body."ring-address" == $ring and
        .body.target == $target and
        (.body.commitments // {}
            | to_entries
            | any(.value.committer == $ring and
                  .value."commitment-device" == "ans104@1.0"))' \
        "$OUT/responses/$node-member.json" >/dev/null
    echo ">> $node produced a ring-signed membership proof"
done

python3 - <<'PY' \
    "$OUT/summary.json" \
    "$ZONE_NAME" \
    "$RING_ADDRESS" \
    "$QEMU1_ADDRESS" \
    "$QEMU2_ADDRESS" \
    "$ANDEE_ADDRESS" \
    "$OUT"
import json, pathlib, sys

summary_path, zone, ring, qemu1, qemu2, andee, out = sys.argv[1:]
pathlib.Path(summary_path).write_text(json.dumps({
    "passed": True,
    "scenario": "mixed-andee-qemu-ring",
    "zone": zone,
    "ring_address": ring,
    "members": {
        "qemu1": qemu1,
        "qemu2": qemu2,
        "andee": andee,
    },
    "member_counts": {
        "qemu1": 3,
        "qemu2": 2,
        "andee": 3,
    },
    "evidence": {
        "qemu_boot_log": str(pathlib.Path(out) / "qemu-zone-boot.log"),
        "qemu1_init": str(pathlib.Path(out) / "responses/qemu1-init.json"),
        "qemu2_join": str(pathlib.Path(out) / "responses/qemu2-join.json"),
        "andee_join": str(pathlib.Path(out) / "responses/andee-join.json"),
        "qemu1_member": str(pathlib.Path(out) / "responses/qemu1-member.json"),
        "qemu2_member": str(pathlib.Path(out) / "responses/qemu2-member.json"),
        "andee_member": str(pathlib.Path(out) / "responses/andee-member.json"),
    },
}, indent=2) + "\n")
PY

echo ""
echo "=== mixed AndEE + QEMU ring PASSED ==="
echo "out: $OUT"
echo "ring-address: $RING_ADDRESS"
