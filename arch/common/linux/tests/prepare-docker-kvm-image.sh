#!/usr/bin/env bash
# Add public operator config and the test-only image to an ESP around the exact
# production signed UKI. Neither input is embedded in or changes the UKI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SIGNED_UKI=${LAPEE_DOCKER_SIGNED_UKI:-$ROOT/build/images/lapee-runtime-no-tme-docker.signed.efi}
FIXTURE_ARCHIVE=${LAPEE_DOCKER_FIXTURE_ARCHIVE:-$ROOT/build/docker-fixture/docker-image.tar}
TEST_DISK=${LAPEE_DOCKER_TEST_DISK:-$ROOT/build/images/lapee-runtime-no-tme-docker-kvm.img}
TEST_ROOT=${LAPEE_DOCKER_TEST_ROOT:-$ROOT/build/docker-kvm-test}

[[ -f "$SIGNED_UKI" ]] || {
    echo "missing signed Docker UKI: $SIGNED_UKI" >&2
    exit 1
}
if [[ ! -f "$FIXTURE_ARCHIVE" ]]; then
    "$ROOT/arch/common/linux/tests/build-docker-fixture.sh"
fi
mkdir -p "$TEST_ROOT" "$(dirname "$TEST_DISK")"
printf '%s\n' '{"permawebos-docker-image":"permawebos-docker-fixture:1.0","permawebos-docker-storage":"128m"}' \
    > "$TEST_ROOT/config.json"

WIFI=0 \
LAPEE_OPERATOR_CONFIG="$TEST_ROOT/config.json" \
LAPEE_CAPABILITY_INPUT="$FIXTURE_ARCHIVE" \
LAPEE_CAPABILITY_INPUT_NAME=docker-image.tar \
    "$ROOT/scripts/build-usb-image.sh" \
        --uki "$SIGNED_UKI" \
        --image "$TEST_DISK"

docker run --rm \
    -v "$TEST_DISK:/disk:ro" \
    -v "$SIGNED_UKI:/signed-uki:ro" \
    "${BUILD_IMAGE:-lapee-build:local}" bash -euo pipefail -c '
        start_lba=$(parted --script --machine /disk unit s print \
            | awk -F: "/^1:/ {gsub(\"s\", \"\", \$2); print \$2}")
        test -n "$start_lba"
        offset=$((start_lba * 512))
        mcopy -i "/disk@@$offset" ::/EFI/Boot/BootX64.efi /tmp/BootX64.efi
        cmp /signed-uki /tmp/BootX64.efi
        mdir -i "/disk@@$offset" ::/EFI/Boot/docker-image.tar >/dev/null
        mdir -i "/disk@@$offset" ::/EFI/Boot/config.json >/dev/null
    '

printf 'signed UKI: %s\nKVM test disk: %s\n' "$SIGNED_UKI" "$TEST_DISK"
