#!/usr/bin/env bash
# Build the amd64-only acceptance fixture outside the production UKI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
CONTEXT="$ROOT/arch/common/linux/tests/docker-fixture"
IMAGE=${LAPEE_DOCKER_FIXTURE_IMAGE:-permawebos-docker-fixture:1.0}
ARCHIVE=${LAPEE_DOCKER_FIXTURE_ARCHIVE:-$ROOT/build/docker-fixture/docker-image.tar}

mkdir -p "$(dirname "$ARCHIVE")"
docker build --platform linux/amd64 --tag "$IMAGE" "$CONTEXT"
[[ "$(docker image inspect --format '{{.Architecture}}' "$IMAGE")" == amd64 ]]
docker run --rm --platform linux/amd64 "$IMAGE" bash -lc '
    test "$(uname -m)" = x86_64
    command -v bash python3 rg timeout find grep resource-probe >/dev/null
'
docker save --output "$ARCHIVE" "$IMAGE"
printf 'fixture image: %s\nfixture archive: %s (%s bytes)\n' \
    "$IMAGE" "$ARCHIVE" "$(stat -c %s "$ARCHIVE" 2>/dev/null || stat -f %z "$ARCHIVE")"
