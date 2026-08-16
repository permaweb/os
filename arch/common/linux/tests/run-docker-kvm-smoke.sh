#!/usr/bin/env bash
# Boot the test ESP under x86 KVM and keep every assertion on the public route.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DISK=${LAPEE_DOCKER_TEST_DISK:-$ROOT/build/images/lapee-runtime-no-tme-docker-kvm.img}
OUT=${LAPEE_DOCKER_KVM_OUT:-$ROOT/build/qemu-docker-kvm}
HOST_PORT=${LAPEE_DOCKER_HOST_PORT:-29734}
NETWORK_PORT=${LAPEE_DOCKER_NETWORK_PORT:-29880}

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] || {
    echo "Docker acceptance requires an x86_64 Linux KVM host" >&2
    exit 1
}
[[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]] || {
    echo "Docker acceptance requires readable and writable /dev/kvm" >&2
    exit 1
}
[[ -f "$DISK" ]] || {
    echo "missing Docker KVM test disk: $DISK" >&2
    exit 1
}
mkdir -p "$OUT/network-fixture"
printf 'LAPEE_DOCKER_NETWORK_OK\n' > "$OUT/network-fixture/index.html"
python3 -m http.server "$NETWORK_PORT" --bind 127.0.0.1 \
    --directory "$OUT/network-fixture" > "$OUT/network-fixture.log" 2>&1 &
NETWORK_PID=$!
trap 'kill "$NETWORK_PID" 2>/dev/null || true' EXIT

QEMU_ACCEL=kvm \
QEMU_CPU=host \
QEMU_MEMORY=${QEMU_MEMORY:-12288} \
LAPEE_BUILD_DIR="$OUT" \
OUTDIR="$OUT/results" \
LAPEE_DOCKER_NETWORK_URL="http://10.0.2.2:$NETWORK_PORT/" \
LAPEE_DOCKER_EVIDENCE="$OUT/docker-route-evidence.json" \
LAPEE_BOOT_ACCEPTANCE_SCRIPT="$ROOT/arch/common/linux/tests/docker-kvm-acceptance.sh" \
    "$ROOT/scripts/boot-usb-image.sh" \
        --img "$DISK" \
        --host-port "$HOST_PORT" \
        --timeout "${LAPEE_DOCKER_BOOT_TIMEOUT:-1800}"
