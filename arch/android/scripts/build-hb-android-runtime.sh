#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"
source "$ROOT/scripts/andee-preloaded-store.sh"

OUT="$ROOT/android/app/src/main/assets/andee-runtime.zip"
WORK="$BUILD_DIR/andee-runtime"
JNI_DIR="$ROOT/android/app/src/main/jniLibs"
NDK_ROOT="${ANDROID_NDK_ROOT:-}"
NDK_VERSION="${NDK_VERSION:-29.0.14206865}"
REBAR3="$ROOT/scripts/verified-rebar3.sh"
PRUNE_OTP_APPS="${PRUNE_OTP_APPS:-common_test debugger dialyzer diameter edoc eldap erl_interface et eunit ftp megaco mnesia observer reltool snmp ssh tftp tools}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN || echo 4)}"
EXPECTED_HYPERBEAM_VERSION="8b9105d7c1a8b2bd93fc050dfd093fa49b80b0be"

if [ -z "$NDK_ROOT" ]; then
    NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
fi
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"

require_tool zip
require_tool python3
require_tool cargo
require_tool cc
require_tool cmake
require_tool erl
require_tool git
require_tool make
require_tool rustc

"$ROOT/scripts/stage-android-devices.sh"

HB_REF_MARKER="$ANDEE_DEVICE_ROOT/_build/default/.andee-hyperbeam-ref"
if [ "$(cat "$HB_REF_MARKER" 2>/dev/null || true)" != "$EXPECTED_HYPERBEAM_VERSION" ]; then
    rm -rf "$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
fi

for clang in aarch64-linux-android29-clang x86_64-linux-android29-clang llvm-strip; do
    if [ ! -x "$TOOLCHAIN/$clang" ]; then
        echo "missing Android NDK tool: $TOOLCHAIN/$clang" >&2
        exit 1
    fi
done

rust_target_for_abi() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android" ;;
        x86_64) echo "x86_64-linux-android" ;;
        *)
            echo "unsupported Android ABI for Rust: $1" >&2
            exit 1
            ;;
    esac
}

clang_for_abi() {
    case "$1" in
        arm64-v8a) echo "aarch64-linux-android29-clang" ;;
        x86_64) echo "x86_64-linux-android29-clang" ;;
        *)
            echo "unsupported Android ABI for clang: $1" >&2
            exit 1
            ;;
    esac
}

target_arch_for_abi() {
    case "$1" in
        arm64-v8a) echo "aarch64" ;;
        x86_64) echo "x86_64" ;;
        *)
            echo "unsupported Android ABI: $1" >&2
            exit 1
            ;;
    esac
}

wamr_target_for_abi() {
    case "$1" in
        arm64-v8a) echo "AARCH64" ;;
        x86_64) echo "X86_64" ;;
        *)
            echo "unsupported Android ABI: $1" >&2
            exit 1
            ;;
    esac
}

sanitize_native_name() {
    printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9_' '_'
}

build_android_elmdb_nif() {
    local abi="$1"
    local target clang target_var target_upper rust_libdir rust_src
    target="$(rust_target_for_abi "$abi")"
    clang="$(clang_for_abi "$abi")"
    target_var="$(printf '%s' "$target" | tr '-' '_')"
    target_upper="$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')"
    rust_libdir="$(rustc --print sysroot)/lib/rustlib/$target/lib"
    rust_src="$(rustc --print sysroot)/lib/rustlib/src/rust/library/std"

    local cargo_extra=()
    local rust_env=()
    if [ ! -e "$rust_libdir/libcore.rlib" ]; then
        if [ ! -d "$rust_src" ]; then
            echo "missing Rust std for $target and no rust-src fallback at $rust_src" >&2
            exit 1
        fi
        cargo_extra=(-Z build-std=std,panic_abort)
        rust_env=(RUSTC_BOOTSTRAP=1)
    fi

    (
        cd "$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb/native/elmdb_nif"
        env "${rust_env[@]}" \
            "CC_${target_var}=$TOOLCHAIN/$clang" \
            "AR_${target_var}=$TOOLCHAIN/llvm-ar" \
            "CARGO_TARGET_${target_upper}_LINKER=$TOOLCHAIN/$clang" \
            cargo build "${cargo_extra[@]}" --release --locked --target "$target"
    )
}

build_android_hb_keccak_nif() {
    local abi="$1"
    local clang hb_app erts_include out
    clang="$(clang_for_abi "$abi")"
    hb_app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    erts_include="$BUILD_DIR/android-erts/$abi/erlang/usr/include"
    out="$WORK/erlang/$abi/lib/hb/priv/hb_keccak.so"

    if [ ! -d "$erts_include" ]; then
        echo "missing Android ERTS include dir for $abi: $erts_include" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$out")"
    "$TOOLCHAIN/$clang" \
        -shared -fPIC -O2 -Wall -Wextra \
        -I "$erts_include" \
        -I "$hb_app/native/hb_keccak" \
        -o "$out" \
        "$hb_app/native/hb_keccak/hb_keccak.c" \
        "$hb_app/native/hb_keccak/hb_keccak_nif.c"
}

build_android_b64veryfast_nif() {
    local abi="$1"
    local clang target_arch b64_app b64_build erts_include out
    clang="$(clang_for_abi "$abi")"
    target_arch="$(target_arch_for_abi "$abi")"
    b64_app="$ANDEE_DEVICE_ROOT/_build/default/lib/b64veryfast"
    b64_build="$BUILD_DIR/android-native/$abi/b64veryfast"
    erts_include="$BUILD_DIR/android-erts/$abi/erlang/usr/include"
    out="$WORK/erlang/$abi/lib/b64veryfast/priv/b64veryfast.so"

    if [ ! -d "$erts_include" ]; then
        echo "missing Android ERTS include dir for $abi: $erts_include" >&2
        exit 1
    fi
    rm -rf "$b64_build"
    mkdir -p "$b64_build"
    cp -a "$b64_app/." "$b64_build/"
    (
        cd "$b64_build"
        make clean
        make -j "$JOBS" \
            CC="$TOOLCHAIN/$clang" \
            ERL_INCLUDE="$erts_include" \
            SO_LDFLAGS=-shared \
            TARGET_ARCH="$target_arch" \
            all
    )
    mkdir -p "$(dirname "$out")"
    cp "$b64_build/priv/b64veryfast.so" "$out"
}

build_android_hb_util_string_nif() {
    local abi="$1"
    local clang hb_app erts_include out
    clang="$(clang_for_abi "$abi")"
    hb_app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    erts_include="$BUILD_DIR/android-erts/$abi/erlang/usr/include"
    out="$WORK/erlang/$abi/lib/hb/priv/hb_util_string.so"

    if [ ! -d "$erts_include" ]; then
        echo "missing Android ERTS include dir for $abi: $erts_include" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$out")"
    "$TOOLCHAIN/$clang" \
        -std=c99 -shared -fPIC -O3 -Wall -Wextra \
        -I "$erts_include" \
        -o "$out" \
        "$hb_app/native/hb_util_string/hb_util_string.c"
}

build_android_secp256k1_nif() {
    local abi="$1"
    local clang hb_app erts_include secp_src secp_build secp_lib out
    clang="$(clang_for_abi "$abi")"
    hb_app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    erts_include="$BUILD_DIR/android-erts/$abi/erlang/usr/include"
    secp_src="$hb_app/native/lib/secp256k1"
    secp_build="$BUILD_DIR/android-native/$abi/secp256k1"
    secp_lib="$secp_build/lib/libsecp256k1.a"
    out="$WORK/erlang/$abi/lib/hb/priv/secp256k1_arweave.so"

    if [ ! -f "$secp_src/CMakeLists.txt" ]; then
        echo "missing pinned HyperBEAM secp256k1 submodule" >&2
        exit 1
    fi
    rm -rf "$secp_build"
    cmake \
        -S "$secp_src" \
        -B "$secp_build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM=29 \
        -DBUILD_SHARED_LIBS=OFF \
        -DSECP256K1_BUILD_BENCHMARK=OFF \
        -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
        -DSECP256K1_BUILD_TESTS=OFF \
        -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
        -DSECP256K1_ENABLE_MODULE_MUSIG=OFF \
        -DSECP256K1_ENABLE_MODULE_EXTRAKEYS=OFF \
        -DSECP256K1_ENABLE_MODULE_ELLSWIFT=OFF \
        -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=OFF \
        -DSECP256K1_APPEND_CFLAGS=-fPIC
    cmake --build "$secp_build" --parallel "$JOBS"
    if [ ! -f "$secp_lib" ]; then
        echo "missing Android secp256k1 static library for $abi: $secp_lib" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$out")"
    "$TOOLCHAIN/$clang" \
        -std=c99 -shared -fPIC -O3 -Wall -Wextra -Wmissing-prototypes \
        -I "$erts_include" \
        -I "$hb_app/native/hb_nif" \
        -I "$secp_src/include" \
        -o "$out" \
        "$hb_app/native/secp256k1/secp256k1_nif.c" \
        "$hb_app/native/hb_nif/hb_nif.c" \
        "$secp_lib"
}

build_android_hb_beamr_driver() {
    local abi="$1"
    local clang hb_app erts_release erts_include ei_lib wamr_src wamr_build
    local wamr_lib wamr_target out
    clang="$(clang_for_abi "$abi")"
    hb_app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    erts_release="$BUILD_DIR/android-erts/$abi/erlang"
    erts_include="$erts_release/usr/include"
    ei_lib="$(find "$erts_release" -type f -name libei.a -print -quit)"
    wamr_src="$hb_app/_build/wamr"
    wamr_build="$BUILD_DIR/android-native/$abi/wamr"
    wamr_lib="$wamr_build/libvmlib.a"
    wamr_target="$(wamr_target_for_abi "$abi")"
    out="$WORK/erlang/$abi/lib/hb/priv/hb_beamr.so"

    if [ ! -f "$wamr_src/CMakeLists.txt" ]; then
        echo "missing pinned WAMR source in HyperBEAM build" >&2
        exit 1
    fi
    if [ -z "$ei_lib" ]; then
        echo "missing Android ERTS libei.a for $abi" >&2
        exit 1
    fi
    rm -rf "$wamr_build"
    cmake \
        -S "$wamr_src" \
        -B "$wamr_build" \
        -DCMAKE_TOOLCHAIN_FILE="$NDK_ROOT/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$abi" \
        -DANDROID_PLATFORM=29 \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DWAMR_BUILD_TARGET="$wamr_target" \
        -DWAMR_BUILD_PLATFORM=android \
        -DWAMR_BUILD_STATIC=1 \
        -DWAMR_BUILD_SHARED=0 \
        -DWAMR_BUILD_MEMORY64=1 \
        -DWAMR_DISABLE_HW_BOUND_CHECK=1 \
        -DWAMR_BUILD_EXCE_HANDLING=1 \
        -DWAMR_BUILD_SHARED_MEMORY=0 \
        -DWAMR_BUILD_AOT=1 \
        -DWAMR_BUILD_LIBC_WASI=0 \
        -DWAMR_BUILD_FAST_INTERP=0 \
        -DWAMR_BUILD_INTERP=1 \
        -DWAMR_BUILD_JIT=0 \
        -DWAMR_BUILD_FAST_JIT=0 \
        -DWAMR_BUILD_DEBUG_AOT=1 \
        -DWAMR_BUILD_TAIL_CALL=1 \
        -DWAMR_BUILD_AOT_STACK_FRAME=1 \
        -DWAMR_BUILD_MEMORY_PROFILING=1 \
        -DWAMR_BUILD_DUMP_CALL_STACK=1
    cmake --build "$wamr_build" --parallel "$JOBS"
    if [ ! -f "$wamr_lib" ]; then
        echo "missing Android WAMR static library for $abi: $wamr_lib" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$out")"
    "$TOOLCHAIN/$clang" \
        -std=c99 -shared -fPIC -O2 -Wall -Wextra \
        -Wno-incompatible-pointer-types \
        -I "$erts_include" \
        -I "$hb_app/native/hb_beamr/include" \
        -I "$wamr_src/core/iwasm/include" \
        -o "$out" \
        "$hb_app/native/hb_beamr/hb_beamr.c" \
        "$hb_app/native/hb_beamr/hb_wasm.c" \
        "$hb_app/native/hb_beamr/hb_driver.c" \
        "$hb_app/native/hb_beamr/hb_helpers.c" \
        "$hb_app/native/hb_beamr/hb_logging.c" \
        "$wamr_lib" \
        "$ei_lib" \
        -llog -landroid -lm -ldl
}

write_reproducible_hb_buildinfo() {
    local hb_app actual_version source_epoch source_short
    hb_app="$ANDEE_DEVICE_ROOT/_build/default/lib/hb"
    actual_version="$(git -C "$hb_app" rev-parse HEAD)"
    if [ "$actual_version" != "$EXPECTED_HYPERBEAM_VERSION" ]; then
        echo "unexpected HyperBEAM source: $actual_version" >&2
        exit 1
    fi
    source_epoch="$(git -C "$hb_app" show -s --format=%ct HEAD)"
    source_short="${actual_version:0:12}"
    mkdir -p "$hb_app/priv"
    printf '%s\n' \
        '#{' \
        "    <<\"source\">> => <<\"$actual_version\">>," \
        "    <<\"source-short\">> => <<\"$source_short\">>," \
        "    <<\"build-time\">> => $source_epoch" \
        '}.' \
        > "$hb_app/priv/hb_buildinfo"
    export ANDEE_HYPERBEAM_VERSION="$actual_version"
    export ANDEE_HYPERBEAM_SOURCE_EPOCH="$source_epoch"
}

stage_native_payload() {
    local abi="$1"
    local rel="$2"
    local source="$3"
    local native_name native_path
    native_name="libandee_$(sanitize_native_name "$abi")_$(sanitize_native_name "$rel").so"
    native_path="$JNI_DIR/$abi/$native_name"
    mkdir -p "$(dirname "$native_path")"
    cp "$source" "$native_path"
    try_strip "$native_path"
    rm -f "$source"
    printf '%s|%s\n' "$rel" "$native_name" >>"$WORK/native-links/$abi.txt"
}

try_strip() {
    local path="$1"
    if ! "$TOOLCHAIN/llvm-strip" --strip-unneeded "$path"; then
        "$TOOLCHAIN/llvm-strip" "$path"
    fi
}

ABI=arm64-v8a "$ROOT/scripts/build-android-erts.sh"
ABI=x86_64 "$ROOT/scripts/build-android-erts.sh"

rm -rf "$WORK" "$JNI_DIR/arm64-v8a" "$JNI_DIR/x86_64"
mkdir -p "$WORK/config" "$WORK/native-links" "$(dirname "$OUT")" \
    "$JNI_DIR/arm64-v8a" "$JNI_DIR/x86_64"
rm -f "$OUT"

"$ROOT/scripts/stage-andock-runtime.sh" "$WORK" "$JNI_DIR"

if [ -d "$ANDEE_DEVICE_ROOT/priv" ]; then
    cp -a "$ANDEE_DEVICE_ROOT/priv" "$WORK/priv"
fi
# A previous cross-build may have populated the persistent staged dependency
# tree with an Android object. Host compilation must never reuse that object.
B64_APP="$ANDEE_DEVICE_ROOT/_build/default/lib/b64veryfast"
if [ -f "$B64_APP/Makefile" ]; then
    make -C "$B64_APP" clean
    make -C "$B64_APP" -j "$JOBS" all
fi
(cd "$ANDEE_DEVICE_ROOT" && "$REBAR3" compile)
HB_SCHEMA="$ANDEE_DEVICE_ROOT/_build/default/lib/hb/scripts/schema.gql"
if [ ! -f "$HB_SCHEMA" ]; then
    echo "missing HyperBEAM GraphQL schema: $HB_SCHEMA" >&2
    exit 1
fi
mkdir -p "$WORK/scripts"
cp "$HB_SCHEMA" "$WORK/scripts/schema.gql"
rm -rf "$WORK/_build"
build_andee_preloaded_store "$WORK/_build/preloaded-store"
# Forge invokes the HyperBEAM compile hook while creating the store, which
# refreshes hb_buildinfo with wall-clock time. Normalize it after the final
# rebar3 invocation and before copying application priv files into the runtime.
write_reproducible_hb_buildinfo
printf '%s\n' "$ANDEE_HYPERBEAM_VERSION" > "$HB_REF_MARKER"
cp "$ANDEE_CONFIG" "$WORK/config/andee.json"
for abi in arm64-v8a x86_64; do
    build_android_elmdb_nif "$abi"
done

"$TOOLCHAIN/aarch64-linux-android29-clang" \
    -D_POSIX_C_SOURCE=200809L -fPIE -pie -O2 -Wall -Wextra \
    "$ANDEE_RUNTIME_SRC/andee_hyperbeam_launcher.c" \
    -o "$JNI_DIR/arm64-v8a/libandee_hyperbeam.so"
"$TOOLCHAIN/x86_64-linux-android29-clang" \
    -D_POSIX_C_SOURCE=200809L -fPIE -pie -O2 -Wall -Wextra \
    "$ANDEE_RUNTIME_SRC/andee_hyperbeam_launcher.c" \
    -o "$JNI_DIR/x86_64/libandee_hyperbeam.so"

ANDEE_PRUNE_OTP_APPS="$PRUNE_OTP_APPS" \
python3 - <<'PY' "$ROOT" "$BUILD_DIR" "$WORK" "$JNI_DIR" "$TOOLCHAIN/llvm-strip"
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
build_dir = Path(sys.argv[2])
work = Path(sys.argv[3])
jni_dir = Path(sys.argv[4])
strip = Path(sys.argv[5])

abis = ["arm64-v8a", "x86_64"]
prune_names = {
    "src", "include", "doc", "docs", "man", "examples", "emacs",
    "c_src", "misc", "usr",
}
prune_file_suffixes = {".a"}
prune_otp_apps = set(os.environ["ANDEE_PRUNE_OTP_APPS"].split())
prune_erts_bins_by_app = {
    "common_test": {"ct_run"},
    "dialyzer": {"dialyzer", "typer"},
}

def sanitize(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", value)

def is_elf(path: Path) -> bool:
    try:
        with path.open("rb") as handle:
            return handle.read(4) == b"\x7fELF"
    except OSError:
        return False

def ignore_release_dir(directory, names):
    ignored = set()
    for name in names:
        if name in prune_names or any(
            name == app or name.startswith(f"{app}-")
            for app in prune_otp_apps
        ):
            ignored.add(name)
    return ignored

def is_pruned_otp_app(name: str) -> bool:
    return any(name == app or name.startswith(f"{app}-") for app in prune_otp_apps)

def prune_installed_application_versions(target: Path) -> None:
    for versions in target.glob("releases/*/installed_application_versions"):
        kept = [
            line
            for line in versions.read_text().splitlines()
            if not is_pruned_otp_app(line)
        ]
        versions.write_text("\n".join(kept) + ("\n" if kept else ""))

def prune_non_runtime_files(target: Path) -> None:
    for path in target.rglob("*"):
        if path.is_file() and path.suffix in prune_file_suffixes:
            path.unlink()

def is_pruned_erts_bin(rel: str) -> bool:
    if "/erts-" not in rel or "/bin/" not in rel:
        return False
    name = rel.rsplit("/", 1)[-1]
    return any(
        app in prune_otp_apps and name in bins
        for app, bins in prune_erts_bins_by_app.items()
    )

for abi in abis:
    release = build_dir / "android-erts" / abi / "erlang"
    if not (release / "releases").is_dir():
        raise SystemExit(f"missing Android ERTS release for {abi}: {release}")
    target = work / "erlang" / abi
    shutil.copytree(release, target, ignore=ignore_release_dir)
    prune_installed_application_versions(target)
    prune_non_runtime_files(target)
    link_lines = []
    for path in sorted(target.rglob("*")):
        if not path.is_file():
            continue
        if not (is_elf(path) or path.suffix == ".so"):
            continue
        rel = path.relative_to(work).as_posix()
        if is_pruned_erts_bin(rel):
            path.unlink()
            continue
        native_name = f"libandee_{sanitize(abi)}_{sanitize(rel)}.so"
        native_path = jni_dir / abi / native_name
        shutil.copy2(path, native_path)
        try:
            subprocess.run([str(strip), "--strip-unneeded", str(native_path)], check=True)
        except subprocess.CalledProcessError:
            subprocess.run([str(strip), str(native_path)], check=True)
        path.unlink()
        link_lines.append(f"{rel}|{native_name}")
    (work / "native-links" / f"{abi}.txt").write_text("\n".join(link_lines) + "\n")
PY

for abi in arm64-v8a x86_64; do
    APP_LIB="$WORK/erlang/$abi/lib"
    for app in "$ANDEE_DEVICE_ROOT"/_build/default/lib/*; do
        [ -d "$app/ebin" ] || continue
        name="$(basename "$app")"
        mkdir -p "$APP_LIB/$name/ebin"
        find "$app/ebin" -type f \
            ! -name 'hb_snp_nif.beam' \
            | while IFS= read -r ebin_file; do
                cp "$ebin_file" "$APP_LIB/$name/ebin/"
            done
        if [ -d "$app/priv" ]; then
            find "$app/priv" -type f \
                ! -path '*/crates/*' \
                ! -name '*.a' \
                ! -name '*.d' \
                ! -name '*.so' \
                ! -name '*.dylib' \
                ! -name '*.dll' \
                | while IFS= read -r priv_file; do
                    rel="${priv_file#"$app/priv/"}"
                    mkdir -p "$APP_LIB/$name/priv/$(dirname "$rel")"
                    cp "$priv_file" "$APP_LIB/$name/priv/$rel"
                done
        fi
    done
    build_android_b64veryfast_nif "$abi"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/b64veryfast/priv/b64veryfast.so" \
        "$APP_LIB/b64veryfast/priv/b64veryfast.so"
    build_android_hb_keccak_nif "$abi"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/hb/priv/hb_keccak.so" \
        "$APP_LIB/hb/priv/hb_keccak.so"
    build_android_hb_util_string_nif "$abi"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/hb/priv/hb_util_string.so" \
        "$APP_LIB/hb/priv/hb_util_string.so"
    build_android_secp256k1_nif "$abi"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/hb/priv/secp256k1_arweave.so" \
        "$APP_LIB/hb/priv/secp256k1_arweave.so"
    build_android_hb_beamr_driver "$abi"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/hb/priv/hb_beamr.so" \
        "$APP_LIB/hb/priv/hb_beamr.so"
    ELMDB_TARGET="$(rust_target_for_abi "$abi")"
    ELMDB_NIF="$ANDEE_DEVICE_ROOT/_build/default/lib/elmdb/native/elmdb_nif/target/$ELMDB_TARGET/release/libelmdb_nif.so"
    if [ ! -f "$ELMDB_NIF" ]; then
        echo "missing Android elmdb NIF for $abi: $ELMDB_NIF" >&2
        exit 1
    fi
    mkdir -p "$APP_LIB/elmdb/priv"
    cp "$ELMDB_NIF" "$APP_LIB/elmdb/priv/libelmdb_nif.so"
    stage_native_payload \
        "$abi" \
        "erlang/$abi/lib/elmdb/priv/libelmdb_nif.so" \
        "$APP_LIB/elmdb/priv/libelmdb_nif.so"
done

zip_timestamp="$(python3 - "$ANDEE_HYPERBEAM_SOURCE_EPOCH" <<'PY'
import datetime, sys
print(datetime.datetime.fromtimestamp(
    int(sys.argv[1]), datetime.timezone.utc
).strftime("%Y%m%d%H%M.%S"))
PY
)"
TZ=UTC find "$WORK" -exec touch -h -t "$zip_timestamp" {} +
(
    cd "$WORK"
    LC_ALL=C find . -mindepth 1 -print |
        LC_ALL=C sort |
        zip -qX "$OUT" -@
)
ANDEE_PRUNE_OTP_APPS="$PRUNE_OTP_APPS" \
ANDEE_HYPERBEAM_VERSION="$ANDEE_HYPERBEAM_VERSION" \
ANDEE_HYPERBEAM_SOURCE_EPOCH="$ANDEE_HYPERBEAM_SOURCE_EPOCH" \
ANDEE_LMDB_SYS_CHECKSUM="$ANDEE_LMDB_SYS_CHECKSUM" \
ANDEE_LMDB_SYS_VERSION="$ANDEE_LMDB_SYS_VERSION" \
ANDEE_PRELOADED_STORE_SHA256="$ANDEE_PRELOADED_STORE_SHA256" \
ANDEE_PRELOADED_STORE_SIGNER="$ANDEE_PRELOADED_STORE_SIGNER" \
python3 - <<'PY' "$OUT" "$BUILD_DIR/andee-runtime/manifest.json" "$JNI_DIR" "$WORK"
import hashlib, json, os, pathlib, struct, sys
zip_path = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
jni_dir = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])
prune_otp_apps = set(os.environ["ANDEE_PRUNE_OTP_APPS"].split())
native = sorted(str(p.relative_to(jni_dir)) for p in jni_dir.glob("*/*.so"))
required_native_fragments = (
    "libandee_hyperbeam.so",
    "_lib_b64veryfast_priv_b64veryfast_so.so",
    "_lib_elmdb_priv_libelmdb_nif_so.so",
    "_lib_hb_priv_hb_beamr_so.so",
    "_lib_hb_priv_hb_keccak_so.so",
    "_lib_hb_priv_hb_util_string_so.so",
    "_lib_hb_priv_secp256k1_arweave_so.so",
)
for abi, expected_machine in {"arm64-v8a": 183, "x86_64": 62}.items():
    abi_native = [p for p in (jni_dir / abi).glob("*.so")]
    names = {p.name for p in abi_native}
    for fragment in required_native_fragments:
        if not any(name == fragment or name.endswith(fragment) for name in names):
            raise SystemExit(f"missing required {abi} native payload: {fragment}")
    for path in abi_native:
        header = path.read_bytes()[:20]
        if len(header) < 20 or header[:4] != b"\x7fELF" or header[5] != 1:
            raise SystemExit(f"invalid little-endian ELF payload: {path}")
        machine = struct.unpack_from("<H", header, 18)[0]
        if machine != expected_machine:
            raise SystemExit(
                f"wrong ELF machine for {abi}: {path} ({machine})"
            )
links = {
    p.stem: len([line for line in p.read_text().splitlines() if line.strip()])
    for p in sorted((work / "native-links").glob("*.txt"))
}
andock_native = json.loads(
    (work / "execution/andock/andock-proot-arm64.manifest.json").read_text()
)
andock_template = json.loads(
    (work / "execution/andock/andock-ubuntu-arm64.ext4.manifest.json").read_text()
)
andock_files = {
    "usr/bin/proot": "libandee_proot.so",
    "usr/libexec/andock/proot-launcher": "libandee_andock_launcher.so",
    "usr/libexec/proot/loader": "libandee_proot_loader.so",
}
for source, packaged in andock_files.items():
    path = jni_dir / "arm64-v8a" / packaged
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    expected = andock_native["files"].get(source)
    if actual != expected:
        raise SystemExit(f"Andock native digest mismatch: {packaged}")
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps({
    "artifact": str(zip_path),
    "sha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
    "kind": "android-hyperbeam-erts-andee-runtime",
    "hyperbeam-version": os.environ["ANDEE_HYPERBEAM_VERSION"],
    "hyperbeam-source-epoch": int(os.environ["ANDEE_HYPERBEAM_SOURCE_EPOCH"]),
    "pruned-otp-apps": sorted(prune_otp_apps),
    "native-payload-count": len(native),
    "native-link-counts": links,
    "native-libraries": native,
    "preloaded-store": {
        "canonical-format": "lmdb-dump-load-v1",
        "lmdb-sys-checksum": os.environ["ANDEE_LMDB_SYS_CHECKSUM"],
        "lmdb-sys-version": os.environ["ANDEE_LMDB_SYS_VERSION"],
        "sha256": os.environ["ANDEE_PRELOADED_STORE_SHA256"],
        "signing-algorithm": "ed25519",
        "signer": os.environ["ANDEE_PRELOADED_STORE_SIGNER"],
    },
    "andock": {
        "architecture": andock_native["architecture"],
        "native-files": andock_native["files"],
        "proot-version": andock_native["proot-version"],
        "template-image-sha256": andock_template["image-sha256"],
        "template-provision-revision": andock_template["provision-revision"],
        "template-sparse-sha256": andock_template["sparse-image-sha256"],
        "toolchain-revision": andock_native["toolchain-revision"],
    },
}, indent=2) + "\n")
PY
echo "runtime zip: $OUT"
echo "native payloads: $JNI_DIR"
