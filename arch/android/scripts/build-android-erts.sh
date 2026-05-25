#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OTP_VERSION="${OTP_VERSION:-28.5}"
OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.6}"
OTP_SHA256="${OTP_SHA256:-2c7e8ca23e6864eb20eff5d44738bfa123aed8cd21ed6d98e533d751eee28d9c}"
OPENSSL_SHA256="${OPENSSL_SHA256:-deae7c80cba99c4b4f940ecadb3c3338b13cb77418409238e57d7f31f2a3b736}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
ABI="${ABI:-arm64-v8a}"
API_LEVEL="${API_LEVEL:-29}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)}"
OTP_URL="${OTP_URL:-https://github.com/erlang/otp/releases/download/OTP-$OTP_VERSION/otp_src_$OTP_VERSION.tar.gz}"
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz}"

NDK_ROOT="${ANDROID_NDK_ROOT:-}"
if [ -z "$NDK_ROOT" ]; then
    NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
fi
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"

require_tool curl
require_tool make
require_tool perl
require_tool python3
require_tool tar

verify_sha256() {
    local path="$1"
    local expected="$2"
    python3 - "$path" "$expected" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected = sys.argv[2].lower()
actual = hashlib.sha256(path.read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit(f"{path}: sha256 mismatch: got {actual}, expected {expected}")
PY
}

case "$ABI" in
    arm64-v8a)
        OTP_XCOMP="erl-xcomp-arm64-android.conf"
        OPENSSL_TARGET="android-arm64"
        ;;
    x86_64)
        OTP_XCOMP="erl-xcomp-x86_64-android.conf"
        OPENSSL_TARGET="android-x86_64"
        ;;
    all)
        ABI=arm64-v8a "$0"
        ABI=x86_64 "$0"
        exit 0
        ;;
    *)
        echo "unsupported ABI: $ABI" >&2
        exit 1
        ;;
esac

if [ ! -x "$TOOLCHAIN/llvm-ar" ]; then
    echo "missing Android NDK LLVM toolchain under $TOOLCHAIN" >&2
    exit 1
fi

ROOT_OUT="$BUILD_DIR/android-erts"
SRC_CACHE="$ROOT_OUT/source"
ABI_OUT="$ROOT_OUT/$ABI"
OPENSSL_PREFIX="$ABI_OUT/openssl"
OPENSSL_MANIFEST="$OPENSSL_PREFIX/andee-openssl-manifest.json"
OTP_RELEASE="$ABI_OUT/erlang"
OTP_MANIFEST="$ABI_OUT/manifest.json"
mkdir -p "$SRC_CACHE" "$ABI_OUT"

OTP_TARBALL="$SRC_CACHE/otp_src_$OTP_VERSION.tar.gz"
OPENSSL_TARBALL="$SRC_CACHE/openssl-$OPENSSL_VERSION.tar.gz"

if [ ! -f "$OTP_TARBALL" ]; then
    curl -fL --retry 3 "$OTP_URL" -o "$OTP_TARBALL"
fi
verify_sha256 "$OTP_TARBALL" "$OTP_SHA256"
if [ ! -f "$OPENSSL_TARBALL" ]; then
    curl -fL --retry 3 "$OPENSSL_URL" -o "$OPENSSL_TARBALL"
fi
verify_sha256 "$OPENSSL_TARBALL" "$OPENSSL_SHA256"

OPENSSL_WORK="$ABI_OUT/openssl-$OPENSSL_VERSION-src"
rm -rf "$OPENSSL_WORK" "$OPENSSL_PREFIX"
tar -xzf "$OPENSSL_TARBALL" -C "$ABI_OUT"
mv "$ABI_OUT/openssl-$OPENSSL_VERSION" "$OPENSSL_WORK"
(
    cd "$OPENSSL_WORK"
    export ANDROID_NDK_ROOT="$NDK_ROOT"
    export PATH="$TOOLCHAIN:$PATH"
    ./Configure "$OPENSSL_TARGET" no-shared no-tests no-module \
        --prefix="$OPENSSL_PREFIX" \
        --openssldir="$OPENSSL_PREFIX/ssl" \
        -D__ANDROID_API__="$API_LEVEL"
    make -j "$JOBS"
    make install_sw
)
python3 - <<'PY' "$OPENSSL_PREFIX" "$OPENSSL_MANIFEST" "$ABI" "$OPENSSL_VERSION" "$OPENSSL_SHA256" "$API_LEVEL"
import hashlib
import json
import pathlib
import sys

prefix = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
libcrypto = prefix / "lib" / "libcrypto.a"
manifest.write_text(json.dumps({
    "abi": sys.argv[3],
    "openssl-version": sys.argv[4],
    "openssl-sha256": sys.argv[5],
    "api-level": sys.argv[6],
    "libcrypto": str(libcrypto),
    "libcrypto-sha256": hashlib.sha256(libcrypto.read_bytes()).hexdigest(),
}, indent=2) + "\n")
PY

OTP_WORK="$ABI_OUT/otp_src_$OTP_VERSION"
rm -rf "$OTP_WORK" "$OTP_RELEASE"
tar -xzf "$OTP_TARBALL" -C "$ABI_OUT"

XCOMP_CONF="$OTP_WORK/xcomp/andee-$OTP_XCOMP"
sed \
    -e 's/^LD=.*/LD="$CC"/' \
    "$OTP_WORK/xcomp/$OTP_XCOMP" > "$XCOMP_CONF"
cat >> "$XCOMP_CONF" <<'EOF'
AR=llvm-ar
RANLIB=llvm-ranlib
DED_LD="$CC"
DED_LDFLAGS="-shared"
DED_LD_FLAG_RUNTIME_LIBRARY_PATH=
EOF

(
    cd "$OTP_WORK"
    export NDK_ROOT="$NDK_ROOT"
    export NDK_ABI_PLAT="android$API_LEVEL"
    export PATH="$TOOLCHAIN:$PATH"
    ./otp_build configure \
        --xcomp-conf="$XCOMP_CONF" \
        --with-ssl="$OPENSSL_PREFIX" \
        --disable-dynamic-ssl-lib \
        --without-javac \
        --without-odbc
    make -j "$JOBS"
    make RELEASE_ROOT="$OTP_RELEASE" release
)

python3 - <<'PY' "$OTP_RELEASE" "$OTP_MANIFEST" "$ABI" "$OPENSSL_PREFIX" "$OTP_VERSION" "$OTP_SHA256" "$OPENSSL_VERSION" "$OPENSSL_SHA256" "$API_LEVEL"
import hashlib, json, pathlib, sys
release = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
abi = sys.argv[3]
openssl_prefix = pathlib.Path(sys.argv[4])
erts_bins = sorted(release.glob("erts-*/bin/*"))
beam = next((p for p in erts_bins if p.name == "beam.smp"), None)
manifest.write_text(json.dumps({
    "abi": abi,
    "otp-version": sys.argv[5],
    "otp-sha256": sys.argv[6],
    "openssl-version": sys.argv[7],
    "openssl-sha256": sys.argv[8],
    "api-level": sys.argv[9],
    "release": str(release),
    "openssl": str(openssl_prefix),
    "beam_smp": str(beam) if beam else None,
    "beam_smp_sha256": hashlib.sha256(beam.read_bytes()).hexdigest() if beam else None,
}, indent=2) + "\n")
PY

echo "Android ERTS release: $OTP_RELEASE"
