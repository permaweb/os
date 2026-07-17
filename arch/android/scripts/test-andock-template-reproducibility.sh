#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andock-template/reproducibility"
FIRST="$OUT/andock-ubuntu-arm64-first.ext4"
SECOND="$OUT/andock-ubuntu-arm64-second.ext4"
FIRST_SIMG="$FIRST.simg"
SECOND_SIMG="$SECOND.simg"
EXPANDED="$OUT/andock-ubuntu-arm64-expanded.ext4"
mkdir -p "$OUT"

"$ROOT/scripts/build-andock-template.sh" "$FIRST"
"$ROOT/scripts/build-andock-template.sh" "$SECOND"
cmp -s "$FIRST" "$SECOND"
cmp -s "$FIRST_SIMG" "$SECOND_SIMG"
cmp -s "$FIRST.manifest.json" "$SECOND.manifest.json"
cmp -s "$FIRST.source.inventory.ndjson" "$SECOND.source.inventory.ndjson"
cmp -s "$FIRST.source.inventory.ndjson" "$FIRST.image.inventory.ndjson"
cmp -s "$SECOND.source.inventory.ndjson" "$SECOND.image.inventory.ndjson"
python3 "$ROOT/scripts/andock-android-sparse.py" \
    expand "$FIRST_SIMG" "$EXPANDED"
cmp -s "$FIRST" "$EXPANDED"

printf 'reproducible-image-sha256=%s\n' \
    "$(shasum -a 256 "$FIRST" | awk '{print $1}')"
printf 'metadata-inventory-sha256=%s\n' "$(python3 - "$FIRST.manifest.json" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["metadata-inventory-sha256"])
PY
)"
printf 'reproducible-android-sparse-sha256=%s\n' \
    "$(shasum -a 256 "$FIRST_SIMG" | awk '{print $1}')"
printf 'template-reproducibility-gate=ok\n'
