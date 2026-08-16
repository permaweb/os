#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BASE_URL=${1:?usage: docker-kvm-acceptance.sh BASE_URL}
NETWORK_URL=${LAPEE_DOCKER_NETWORK_URL:?LAPEE_DOCKER_NETWORK_URL is required}
EVIDENCE=${LAPEE_DOCKER_EVIDENCE:-$ROOT/build/qemu-docker-kvm/docker-route-evidence.json}

python3 "$ROOT/arch/common/linux/tests/docker-device-route-smoke.py" \
    --base-url "$BASE_URL" \
    --network-url "$NETWORK_URL" \
    --evidence "$EVIDENCE"
