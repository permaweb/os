#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

BUILDER_IMAGE=ghcr.io/termux/package-builder@sha256:fa23eb4238ef8eda877cd991a06152ce76e9f274d1cae0d42f28fee3e5cd6016
LWEXT4_REF=58bcf89a121b72d4fb66334f1693d3b30e4cb9c5
LWEXT4_SOURCE="$BUILD_DIR/sources/lwext4-$LWEXT4_REF"
OUT="$BUILD_DIR/andock-image-engine-test"

require_tool docker

if [[ ! -f "$LWEXT4_SOURCE/src/ext4.c" ]] ||
    ! grep -q 'int ext4_fopen_inode' "$LWEXT4_SOURCE/src/ext4.c" ||
    ! grep -q 'regular_source = ext4_inode_is_type' \
        "$LWEXT4_SOURCE/src/ext4.c"; then
    printf 'Run build-andock-proot-image.sh once to prepare pinned lwext4 sources.\n' >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

docker run --rm --platform linux/amd64 \
    --volume "$ROOT/../..:/work" \
    --workdir /work/arch/android \
    "$BUILDER_IMAGE" sh -euxc '
        out=build/andock-image-engine-test
        source=build/sources/lwext4-58bcf89a121b72d4fb66334f1693d3b30e4cb9c5
        truncate -s 128M "$out/member.ext4"
        # lwext4 deliberately supports the conservative ext4 feature set used
        # by the Android member-image builder, not host-mkfs-only additions.
        mkfs.ext4 -F -q \
            -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file \
            "$out/member.ext4"
        cc -std=c11 -O2 -g \
            -DCONFIG_USE_DEFAULT_CFG=0 \
            -I native/andock-image-engine-probe/include \
            -I "$source/include" \
            -I execution/proot-overlay/src \
            -Wall -Wextra -Werror \
            -Wno-unused-function \
            -Wno-unused-parameter \
            -Wno-unused-but-set-variable \
            -Wno-stringop-truncation \
            execution/tests/andock_image_engine_test.c \
            execution/proot-overlay/src/extension/andock_image/andock_image_engine.c \
            "$source"/src/*.c \
            -o "$out/andock-image-engine-test"
        "$out/andock-image-engine-test" "$out/member.ext4" \
            | tee "$out/result.txt"
    '

grep -qx ANDOCK_IMAGE_ENGINE_TEST_OK "$OUT/result.txt"
shasum -a 256 "$OUT/andock-image-engine-test" "$OUT/member.ext4"
