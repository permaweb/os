#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andock-proot-launcher-test"
BUILDER_IMAGE=ghcr.io/termux/package-builder@sha256:fa23eb4238ef8eda877cd991a06152ce76e9f274d1cae0d42f28fee3e5cd6016

mkdir -p "$OUT"
require_tool docker
docker run --rm --platform linux/amd64 --user root --workdir /work \
    --volume "$ROOT:/work:ro" --volume "$OUT:/out" \
    "$BUILDER_IMAGE" sh -euxc '
        cc -std=c11 -O2 -g -DANDOCK_PROOT_LAUNCHER_NO_MAIN \
            -Wall -Wextra -Werror \
            runtime-src/andock_proot_launcher.c \
            execution/tests/andock_proot_launcher_test.c \
            -pthread -o /out/andock-proot-launcher-test
        cc -std=c11 -O2 -g -Wall -Wextra -Werror \
            runtime-src/andock_proot_launcher.c \
            -o /out/andock-proot-launcher
        /out/andock-proot-launcher-test /out/andock-proot-launcher
        sha256sum \
            /out/andock-proot-launcher \
            /out/andock-proot-launcher-test
    '
