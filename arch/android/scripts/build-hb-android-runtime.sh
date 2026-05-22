#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$ROOT/android/app/src/main/assets/handee-runtime.zip"
WORK="$BUILD_DIR/handee-runtime"
JNI_DIR="$ROOT/android/app/src/main/jniLibs"
NDK_ROOT="${ANDROID_NDK_ROOT:-}"

if [ -z "$NDK_ROOT" ]; then
    NDK_ROOT="$ANDROID_SDK_ROOT/ndk/$(ls -1 "$ANDROID_SDK_ROOT/ndk" | sort | tail -1)"
fi
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"

require_tool zip
require_tool python3
require_tool rebar3
require_tool erlc

for clang in aarch64-linux-android29-clang x86_64-linux-android29-clang llvm-strip; do
    if [ ! -x "$TOOLCHAIN/$clang" ]; then
        echo "missing Android NDK tool: $TOOLCHAIN/$clang" >&2
        exit 1
    fi
done

ABI=arm64-v8a "$ROOT/scripts/build-android-erts.sh"
ABI=x86_64 "$ROOT/scripts/build-android-erts.sh"

rm -rf "$WORK" "$JNI_DIR/arm64-v8a" "$JNI_DIR/x86_64"
mkdir -p "$WORK/config" "$WORK/native-links" "$(dirname "$OUT")" \
    "$JNI_DIR/arm64-v8a" "$JNI_DIR/x86_64"
rm -f "$OUT"

cp "$HANDEE_CONFIG" "$WORK/config/handee.json"
if [ -d "$HANDEE_DEVICE_ROOT/priv" ]; then
    cp -a "$HANDEE_DEVICE_ROOT/priv" "$WORK/priv"
fi
(cd "$HANDEE_DEVICE_ROOT" && rebar3 compile)

"$TOOLCHAIN/aarch64-linux-android29-clang" \
    -D_POSIX_C_SOURCE=200809L -fPIE -pie -O2 -Wall -Wextra \
    "$HANDEE_RUNTIME_SRC/handee_hyperbeam_launcher.c" \
    -o "$JNI_DIR/arm64-v8a/libhandee_hyperbeam.so"
"$TOOLCHAIN/x86_64-linux-android29-clang" \
    -D_POSIX_C_SOURCE=200809L -fPIE -pie -O2 -Wall -Wextra \
    "$HANDEE_RUNTIME_SRC/handee_hyperbeam_launcher.c" \
    -o "$JNI_DIR/x86_64/libhandee_hyperbeam.so"

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
        native_name = f"libhandee_{sanitize(abi)}_{sanitize(rel)}.so"
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
    for app in "$HANDEE_DEVICE_ROOT"/_build/default/lib/*; do
        [ -d "$app/ebin" ] || continue
        name="$(basename "$app")"
        case "$name" in
            elmdb)
                continue
                ;;
        esac
        mkdir -p "$APP_LIB/$name/ebin"
        find "$app/ebin" -type f \
            ! -name 'hb_store_lmdb.beam' \
            ! -name 'hb_snp_nif.beam' \
            ! -name 'dev_snp*.beam' \
            ! -name 'dev_tpm*.beam' \
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
    HB_SRC="$HANDEE_DEVICE_ROOT/_build/default/lib/hb/src"
    HB_APP="$HANDEE_DEVICE_ROOT/_build/default/lib/hb"
    PATCHED_HB="$WORK/patched-hb-src"
    mkdir -p "$PATCHED_HB"
    python3 - <<'PY' "$HB_SRC/core/http/hb_http.erl" "$PATCHED_HB/hb_http.erl"
import pathlib, sys
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
text = src.read_text()
text = text.replace(
    "should_finalize_stream(_, _EncodedBody) -> false.",
    "should_finalize_stream(_, _EncodedBody) -> true."
)
dst.write_text(text)
PY
    erlc -pa "$HB_APP/ebin" +'{feature,maybe_expr,enable}' \
        -I "$HB_APP/include" \
        -I "$HB_SRC/core" \
        -o "$APP_LIB/hb/ebin" \
        "$PATCHED_HB/hb_http.erl" \
        "$HB_SRC/preloaded/message/dev_message.erl" \
        "$HB_SRC/preloaded/codec/dev_structured.erl" \
        "$HB_SRC/preloaded/codec/dev_flat.erl" \
        "$HB_SRC/preloaded/codec/dev_json.erl" \
        "$HB_SRC/preloaded/codec/dev_json_iface.erl" \
        "$HB_SRC/preloaded/codec/dev_httpsig_keyid.erl" \
        "$HB_SRC/preloaded/codec/dev_httpsig_siginfo.erl" \
        "$HB_SRC/preloaded/codec/dev_httpsig_conv.erl" \
        "$HB_SRC/preloaded/codec/dev_httpsig_proxy.erl" \
        "$HB_SRC/preloaded/codec/dev_httpsig.erl" \
        "$HB_SRC/preloaded/codec/lib_arweave_common.erl" \
        "$HB_SRC/preloaded/codec/dev_ans104.erl" \
        "$HB_SRC/preloaded/codec/dev_tx.erl" \
        "$HB_SRC/preloaded/auth/dev_cookie_auth.erl" \
        "$HB_SRC/preloaded/auth/dev_cookie.erl" \
        "$HB_SRC/preloaded/auth/dev_auth_hook.erl" \
        "$HB_SRC/preloaded/auth/dev_http_auth.erl" \
        "$HB_SRC/preloaded/auth/dev_secret.erl" \
        "$HB_SRC/preloaded/node/dev_meta.erl" \
        "$HB_SRC/preloaded/node/dev_hyperbuddy.erl" \
        "$HB_SRC/preloaded/node/dev_cache.erl" \
        "$HB_SRC/preloaded/node/dev_router.erl" \
        "$HB_SRC/preloaded/node/dev_node_process.erl" \
        "$HB_SRC/preloaded/node/dev_location_cache.erl" \
        "$HB_SRC/preloaded/node/dev_location.erl" \
        "$HB_SRC/preloaded/node/dev_cron.erl" \
        "$HB_SRC/preloaded/name/dev_name.erl" \
        "$HB_SRC/preloaded/name/dev_b32_name.erl" \
        "$HB_SRC/preloaded/name/dev_local_name.erl" \
        "$HB_SRC/preloaded/util/dev_relay.erl" \
        "$HB_SRC/preloaded/util/dev_stack.erl" \
        "$HB_SRC/preloaded/process/lib_process.erl" \
        "$HB_SRC/preloaded/process/dev_process_cache.erl" \
        "$HB_SRC/preloaded/process/dev_scheduler_cache.erl" \
        "$HB_SRC/preloaded/process/dev_scheduler_formats.erl" \
        "$HB_SRC/preloaded/process/dev_scheduler_registry.erl" \
        "$HB_SRC/preloaded/process/dev_scheduler_server.erl" \
        "$HB_SRC/preloaded/process/dev_process_worker.erl" \
        "$HB_SRC/preloaded/process/dev_push.erl" \
        "$HB_SRC/preloaded/process/dev_scheduler.erl" \
        "$HB_SRC/preloaded/process/dev_process.erl" \
        "$HB_SRC/preloaded/vm/dev_lua_lib.erl" \
        "$HB_SRC/preloaded/vm/dev_lua.erl" \
        "$HB_SRC/preloaded/query/dev_query.erl" \
        "$HB_SRC/preloaded/query/dev_query_graphql.erl" \
        "$HB_SRC/preloaded/query/dev_match.erl" \
        "$HB_SRC/preloaded/arweave/dev_manifest.erl" \
        "$HB_SRC/preloaded/arweave/dev_arweave.erl" \
        "$HB_SRC/preloaded/arweave/dev_bundler.erl" \
        "$HB_SRC/preloaded/arweave/dev_bundler_task.erl" \
        "$HB_SRC/preloaded/arweave/dev_bundler_cache.erl" \
        "$HB_SRC/preloaded/arweave/dev_bundler_recovery.erl" \
        "$HB_SRC/preloaded/payment/dev_p4.erl" \
        "$HB_SRC/preloaded/payment/dev_simple_pay.erl" \
        "$HB_SRC/preloaded/payment/dev_metering.erl"
    erlc -o "$APP_LIB/b64rs/ebin" "$HANDEE_RUNTIME_SRC/erlang-overrides/b64rs.erl"
done

(cd "$WORK" && zip -qr "$OUT" .)
python3 - <<'PY' "$OUT" "$BUILD_DIR/handee-runtime/manifest.json" "$JNI_DIR" "$WORK"
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
    "kind": "android-hyperbeam-erts-handee-runtime",
    "native-payload-count": len(native),
    "native-link-counts": links,
    "native-libraries": native,
}, indent=2) + "\n")
PY
echo "runtime zip: $OUT"
echo "native payloads: $JNI_DIR"
