#!/usr/bin/env bash

LWEXT4_REF=58bcf89a121b72d4fb66334f1693d3b30e4cb9c5
LWEXT4_SHA256=8f7cce20f5dad2719cb22982e64c75069af51741555c98d34a247a5d8f154890
LWEXT4_URL="https://codeload.github.com/gkostka/lwext4/tar.gz/$LWEXT4_REF"
LWEXT4_DOWNLOAD="$BUILD_DIR/downloads/lwext4-$LWEXT4_REF.tar.gz"
LWEXT4_SOURCE="$BUILD_DIR/sources/lwext4-$LWEXT4_REF"

apply_andock_lwext4_patch() {
    local patch_file="$1"

    patch --batch --forward --fuzz=0 --dry-run \
        -d "$LWEXT4_SOURCE" -p1 < "$patch_file"
    patch --batch --forward --fuzz=0 \
        -d "$LWEXT4_SOURCE" -p1 < "$patch_file"
}

prepare_andock_lwext4() {
    require_tool curl
    require_tool patch

    mkdir -p "$(dirname "$LWEXT4_DOWNLOAD")" "$(dirname "$LWEXT4_SOURCE")"
    if [[ ! -f "$LWEXT4_DOWNLOAD" ]]; then
        curl --fail --location --retry 3 \
            --output "$LWEXT4_DOWNLOAD" "$LWEXT4_URL"
    fi
    printf '%s  %s\n' "$LWEXT4_SHA256" "$LWEXT4_DOWNLOAD" \
        | shasum -a 256 -c -

    rm -rf "$LWEXT4_SOURCE"
    tar -xzf "$LWEXT4_DOWNLOAD" -C "$(dirname "$LWEXT4_SOURCE")"
    [[ -f "$LWEXT4_SOURCE/src/ext4.c" ]]

    apply_andock_lwext4_patch \
        "$ROOT/execution/lwext4/patches/xattr-list-size.patch"
    apply_andock_lwext4_patch \
        "$ROOT/execution/lwext4-open-inode.patch"
    apply_andock_lwext4_patch \
        "$ROOT/execution/lwext4-atomic-replace.patch"
    apply_andock_lwext4_patch \
        "$ROOT/execution/lwext4-nondirectory-replace.patch"
    apply_andock_lwext4_patch \
        "$ROOT/execution/lwext4-sparse-read.patch"
}
