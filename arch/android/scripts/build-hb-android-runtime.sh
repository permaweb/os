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

if [ -z "$NDK_ROOT" ]; then
    NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$NDK_VERSION"
fi
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"

require_tool zip
require_tool python3
require_tool erlc
require_tool cargo
require_tool rustc

"$ROOT/scripts/stage-android-devices.sh"

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

if [ -d "$ANDEE_DEVICE_ROOT/priv" ]; then
    cp -a "$ANDEE_DEVICE_ROOT/priv" "$WORK/priv"
fi
(cd "$ANDEE_DEVICE_ROOT" && "$REBAR3" compile)
rm -rf "$WORK/_build"
build_andee_preloaded_store "$WORK/_build/preloaded-store"
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
        if name in prune_names:
            ignored.add(name)
    return ignored

for abi in abis:
    release = build_dir / "android-erts" / abi / "erlang"
    if not (release / "releases").is_dir():
        raise SystemExit(f"missing Android ERTS release for {abi}: {release}")
    target = work / "erlang" / abi
    shutil.copytree(release, target, ignore=ignore_release_dir)
    link_lines = []
    for path in sorted(target.rglob("*")):
        if not path.is_file():
            continue
        if not (is_elf(path) or path.suffix == ".so"):
            continue
        rel = path.relative_to(work).as_posix()
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
    erlc -o "$APP_LIB/b64rs/ebin" "$ANDEE_RUNTIME_SRC/erlang-overrides/b64rs.erl"
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

(cd "$WORK" && zip -qr "$OUT" .)
python3 - <<'PY' "$OUT" "$BUILD_DIR/andee-runtime/manifest.json" "$JNI_DIR" "$WORK"
import hashlib, json, pathlib, sys
zip_path = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
jni_dir = pathlib.Path(sys.argv[3])
work = pathlib.Path(sys.argv[4])
native = sorted(str(p.relative_to(jni_dir)) for p in jni_dir.glob("*/*.so"))
links = {
    p.stem: len([line for line in p.read_text().splitlines() if line.strip()])
    for p in sorted((work / "native-links").glob("*.txt"))
}
manifest.parent.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps({
    "artifact": str(zip_path),
    "sha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
    "kind": "android-hyperbeam-erts-andee-runtime",
    "native-payload-count": len(native),
    "native-link-counts": links,
    "native-libraries": native,
}, indent=2) + "\n")
PY
echo "runtime zip: $OUT"
echo "native payloads: $JNI_DIR"
