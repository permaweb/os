#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

JNI_DIR="${1:?usage: $0 JNI_DIR LLVM_STRIP}"
LLVM_STRIP="${2:?usage: $0 JNI_DIR LLVM_STRIP}"
VERSION='b10502'
COMMIT='0adcc3bb571011bff8b91335d0728a82845c421b'
ARCHIVE_SHA256='2d96aedb009c01005de117e4f514ca0811a0ba21fde7b9c1e6cdd1f44235ce62'
ARCHIVE="$BUILD_DIR/downloads/llama-${VERSION}-bin-android-arm64.tar.gz"
URL="https://github.com/ggml-org/llama.cpp/releases/download/${VERSION}/llama-${VERSION}-bin-android-arm64.tar.gz"
OUT="$JNI_DIR/arm64-v8a"
NOTICE_OUT="$BUILD_DIR/llama-cpp-runtime/notices/llama-cpp-${VERSION}"
MANIFEST="$BUILD_DIR/llama-cpp-runtime/manifest.json"

require_tool curl
require_tool python3
require_tool shasum
require_tool tar
if [ ! -x "$LLVM_STRIP" ]; then
    echo "missing llvm-strip: $LLVM_STRIP" >&2
    exit 1
fi

mkdir -p "$(dirname "$ARCHIVE")" "$OUT" "$NOTICE_OUT" "$(dirname "$MANIFEST")"
if [ ! -f "$ARCHIVE" ] ||
        [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$ARCHIVE_SHA256" ]; then
    curl --fail --location --retry 3 --output "$ARCHIVE" "$URL"
fi
if [ "$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')" != "$ARCHIVE_SHA256" ]; then
    echo "llama.cpp Android archive checksum mismatch: $ARCHIVE" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/andee-llama-cpp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/llama-${VERSION}"

python3 - "$SOURCE" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    "LICENSE": "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d",
    "llama-server": "db82377125f69e87c06b402bba1af072e2a4c4cc9945946e4d6378cc213a84d7",
    "libllama-server-impl.so": "daf9edd8e9f80d784d9d7f59e82267bbe0ab9354e160e8f153e0387b65b1be05",
    "libllama-common.so": "9462624a5c127bb84b2c1127196c3c83e933b77037a862dc45515f180e06c89b",
    "libmtmd.so": "de51f48fdb35d60983ddc86fddcb0f8aede239adb3cefb9a58b8058db84f693c",
    "libllama.so": "6f561bee7431347e4a84d05769cccf0e27ac306d1bf6994384ceb5f6368b22ae",
    "libggml.so": "d3e96504ba9db85486e6ea519f1b9c6451ab064ea9488b74283311cb1f04d8d0",
    "libggml-base.so": "5279167631d6b675656fdbb9d6b5b0016ca1fea33c161767bb200158dfe4312e",
    "libggml-cpu-android_armv8.0_1.so": "3661b1343ae218b44d3e5602277375ffb9e32b07c84eb49100803961247012cc",
    "libggml-cpu-android_armv8.2_1.so": "daba6b52c30c5e3603ca2223a915576e2582d14c4dde0ad59c61ea7c1db7e27e",
    "libggml-cpu-android_armv8.2_2.so": "17363aa2de5494bd5cdf95e35e4e334af4281fb0a600e89aaf0c9bd96ee000b1",
    "libggml-cpu-android_armv8.6_1.so": "a48216a98da7610a1cf8d33209a68f57bc134a30a86d9ce50d0d0401e12b19ca",
    "libggml-cpu-android_armv9.0_1.so": "e34b1548e9cfe36c930f8d809cf2a9ded920416f7c5145ccb99fb00983f02815",
    "libggml-cpu-android_armv9.2_1.so": "46c362586c628b567707d7f7c104338b97a870cdf2f73539838bf0c45fb61481",
    "libggml-cpu-android_armv9.2_2.so": "0e5989182add4a5b96036ee025c0a436c3204107edb822609ff73716ed83ea15",
}
for name, digest in expected.items():
    path = root / name
    if not path.is_file():
        raise SystemExit(f"missing llama.cpp runtime file: {name}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"llama.cpp runtime checksum mismatch: {name}")
PY

cp "$SOURCE/LICENSE" "$NOTICE_OUT/LICENSE"
for name in \
    libllama-server-impl.so \
    libllama-common.so \
    libmtmd.so \
    libllama.so \
    libggml.so \
    libggml-base.so \
    libggml-cpu-android_armv8.0_1.so \
    libggml-cpu-android_armv8.2_1.so \
    libggml-cpu-android_armv8.2_2.so \
    libggml-cpu-android_armv8.6_1.so \
    libggml-cpu-android_armv9.0_1.so \
    libggml-cpu-android_armv9.2_1.so \
    libggml-cpu-android_armv9.2_2.so; do
    cp "$SOURCE/$name" "$OUT/$name"
    "$LLVM_STRIP" --strip-debug "$OUT/$name"
done
cp "$SOURCE/llama-server" "$OUT/libandee_llama_server.so"
"$LLVM_STRIP" --strip-debug "$OUT/libandee_llama_server.so"
chmod 0755 "$OUT/libandee_llama_server.so"

LLAMA_CPP_VERSION="$VERSION" \
LLAMA_CPP_COMMIT="$COMMIT" \
LLAMA_CPP_ARCHIVE_SHA256="$ARCHIVE_SHA256" \
python3 - "$OUT" "$MANIFEST" <<'PY'
import hashlib
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
files = {
    path.name: {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    for path in sorted(root.glob("libggml*.so"))
}
for name in (
    "libandee_llama_server.so",
    "libllama-server-impl.so",
    "libllama-common.so",
    "libmtmd.so",
    "libllama.so",
):
    path = root / name
    files[name] = {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
manifest.write_text(json.dumps({
    "version": os.environ["LLAMA_CPP_VERSION"],
    "commit": os.environ["LLAMA_CPP_COMMIT"],
    "archive-sha256": os.environ["LLAMA_CPP_ARCHIVE_SHA256"],
    "abi": "arm64-v8a",
    "files": dict(sorted(files.items())),
}, indent=2) + "\n")
PY

echo "llama.cpp Android runtime: $OUT/libandee_llama_server.so"
