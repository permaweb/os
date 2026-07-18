#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"
source "$ROOT/scripts/andee-preloaded-store.sh"

"$ROOT/scripts/stage-android-devices.sh"

out="$BUILD_DIR/test-andee-preloaded-store-reproducibility"
build_andee_preloaded_store "$out/first"
first_hash="$ANDEE_PRELOADED_STORE_SHA256"
build_andee_preloaded_store "$out/second"

if [ "$first_hash" != "$ANDEE_PRELOADED_STORE_SHA256" ]; then
    echo "preloaded-store digest changed across identical builds" >&2
    exit 1
fi
cmp "$out/first/data.mdb" "$out/second/data.mdb"
printf 'ANDEE_PRELOADED_STORE_REPRODUCIBILITY_OK sha256=%s signer=%s\n' \
    "$first_hash" "$ANDEE_PRELOADED_STORE_SIGNER"
