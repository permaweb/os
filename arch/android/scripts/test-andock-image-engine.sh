#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"
source "$ROOT/scripts/andock-lwext4-source.sh"

BUILDER_IMAGE=ghcr.io/termux/package-builder@sha256:fa23eb4238ef8eda877cd991a06152ce76e9f274d1cae0d42f28fee3e5cd6016
OUT="$BUILD_DIR/andock-image-engine-test"

require_tool docker
prepare_andock_lwext4

rm -rf "$OUT"
mkdir -p "$OUT"

docker run --rm --platform linux/amd64 \
    --env LWEXT4_REF="$LWEXT4_REF" \
    --volume "$ROOT/../..:/work" \
    --workdir /work/arch/android \
    "$BUILDER_IMAGE" sh -euxc '
        out=build/andock-image-engine-test
        source="build/sources/lwext4-$LWEXT4_REF"
        truncate -s 128M "$out/member.ext4"
        # lwext4 deliberately supports the conservative ext4 feature set used
        # by the Android member-image builder, not host-mkfs-only additions.
        mkfs.ext4 -F -q -b 4096 \
            -O ^64bit,^metadata_csum,^metadata_csum_seed,^orphan_file \
            "$out/member.ext4"
        head -c 1024 /dev/zero | tr "\000" "\245" \
            | dd of="$out/member.ext4" conv=notrunc status=none
        head -c 20480 /dev/zero | tr "\000" "\132" >"$out/sparse-full"
        head -c 4219 /dev/zero | tr "\000" "\124" >"$out/sparse-tail"
        debugfs -w -R "write $out/sparse-full /sparse-full" \
            "$out/member.ext4"
        debugfs -w -R "punch /sparse-full 1 3" "$out/member.ext4"
        debugfs -w -R "write $out/sparse-tail /sparse-tail" \
            "$out/member.ext4"
        debugfs -w -R "punch /sparse-tail 1 1" "$out/member.ext4"
        cc -std=c11 -O2 -g \
            -DCONFIG_USE_DEFAULT_CFG=0 \
            -I execution/lwext4/include \
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
        cc -std=c11 -O2 -g \
            -I execution/proot-overlay/src \
            -Wall -Wextra -Werror \
            execution/tests/andock_mapping_test.c \
            execution/proot-overlay/src/extension/andock_image/andock_mapping.c \
            -o "$out/andock-mapping-test"
        "$out/andock-mapping-test" | tee "$out/mapping-result.txt"
        "$out/andock-image-engine-test" "$out/member.ext4" \
            | tee "$out/result.txt"
        debugfs -R "stat /work/large-sparse" "$out/member.ext4" \
            >"$out/large-sparse.stat"
        block_count=$(awk "/Blockcount:/ { for (i = 1; i <= NF; i++) \
            if (\$i == \"Blockcount:\") print \$(i + 1) }" \
            "$out/large-sparse.stat")
        test -n "$block_count"
        test "$block_count" -le 192
    '

grep -qx ANDOCK_MAPPING_TEST_OK "$OUT/mapping-result.txt"
grep -qx ANDOCK_IMAGE_ENGINE_TEST_OK "$OUT/result.txt"
shasum -a 256 "$OUT/andock-image-engine-test" \
    "$OUT/andock-mapping-test" "$OUT/member.ext4"
