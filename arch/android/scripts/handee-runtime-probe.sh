#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/handee-runtime-probe"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28734}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-240}"
PACKAGE="org.permaweb.handee"
RESET_APP_DATA="${RESET_APP_DATA:-0}"

rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -f "$APK" ]; then
    echo "APK missing: $APK" >&2
    exit 1
fi

adb shell "run-as $PACKAGE sh -c 'kill \$(pidof beam.smp 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof erlexec 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof libhandee_hyperbeam.so 2>/dev/null) 2>/dev/null || true'" \
    >/dev/null 2>&1 || true
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
if [ "$RESET_APP_DATA" = "1" ]; then
    adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
fi

if ! adb install -r "$APK" > "$OUT/install.txt" 2>&1; then
    adb uninstall "$PACKAGE" >> "$OUT/install.txt" 2>&1 || true
    adb install -r "$APK" >> "$OUT/install.txt" 2>&1
fi
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb shell "run-as $PACKAGE sh -c 'mkdir -p no_backup/run; \
    rm -f no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr'" \
    >/dev/null 2>&1 || true
adb shell am start -n "$PACKAGE/.OrnamentActivity" > "$OUT/activity.txt"
adb shell am start-foreground-service -n "$PACKAGE/.HandeeService" \
    > "$OUT/service-start.txt" 2>&1 || true

STARTED=0
for _ in $(seq 1 90); do
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        > "$OUT/hyperbeam.stdout" 2>/dev/null || true
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
        > "$OUT/hyperbeam.stderr" 2>/dev/null || true
    if grep -q "HandEE HyperBEAM node started" "$OUT/hyperbeam.stdout"; then
        STARTED=1
        break
    fi
    sleep 1
done

adb shell run-as "$PACKAGE" ps -A > "$OUT/app-ps.txt" 2>/dev/null || true
adb forward --remove-all >/dev/null 2>&1 || true
adb forward "tcp:$HOST_PORT" tcp:8734 > "$OUT/adb-forward.txt"

probe() {
    local name="$1"
    local path="$2"
    local url="http://127.0.0.1:$HOST_PORT$path"
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -H "Accept: application/json" \
        -D "$OUT/$name.headers" \
        -o "$OUT/$name.body" \
        -w "%{http_code}\n" \
        "$url" > "$OUT/$name.status"
}

python3 - <<'PY' > "$OUT/fresh-nonce.txt"
import base64, os
print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("="))
PY
FRESH_NONCE="$(cat "$OUT/fresh-nonce.txt")"

probe meta "/~meta@1.0/info" || true
probe boot "/~measurement@1.0/boot" || true
probe fresh "/~measurement@1.0/fresh?nonce=$FRESH_NONCE" || true

BASE_URL="http://127.0.0.1:$HOST_PORT"
for name in meta boot fresh; do
    if [ "$(cat "$OUT/$name.status" 2>/dev/null || true)" = "200" ]; then
        tmp_materialized="$OUT/$name.materialized.json.tmp"
        if python3 "$ROOT/scripts/materialize-ao-json.py" \
            --base-url "$BASE_URL" \
            --output "$tmp_materialized" \
            "$OUT/$name.body"; then
            mv "$tmp_materialized" "$OUT/$name.materialized.json"
        else
            rm -f "$tmp_materialized" "$OUT/$name.materialized.json"
        fi
    fi
done

if [ -f "$OUT/boot.materialized.json" ]; then
    python3 "$HANDEE_VERIFIER_DIR/verifier_handee.py" \
        "$OUT/boot.materialized.json" \
        --out "$OUT/external-verifier-boot" \
        --allow-rejected || true
fi
if [ -f "$OUT/fresh.materialized.json" ]; then
    python3 "$HANDEE_VERIFIER_DIR/verifier_handee.py" \
        "$OUT/fresh.materialized.json" \
        --nonce="$FRESH_NONCE" \
        --out "$OUT/external-verifier-fresh" \
        --allow-rejected || true
fi

python3 - <<'PY' "$OUT" "$STARTED"
import json, pathlib, sys

out = pathlib.Path(sys.argv[1])
started = sys.argv[2] == "1"

def read(name):
    path = out / name
    return path.read_text(errors="ignore") if path.exists() else ""

verdict = {
    "scenario": "android-app-uid-hyperbeam-runtime-probe",
    "runtime_started": started,
    "meta_status": read("meta.status").strip(),
    "boot_status": read("boot.status").strip(),
    "fresh_status": read("fresh.status").strip(),
    "meta_bytes": len((out / "meta.body").read_bytes()) if (out / "meta.body").exists() else 0,
    "boot_bytes": len((out / "boot.body").read_bytes()) if (out / "boot.body").exists() else 0,
    "fresh_bytes": len((out / "fresh.body").read_bytes()) if (out / "fresh.body").exists() else 0,
    "boot_materialized": (out / "boot.materialized.json").is_file(),
    "fresh_materialized": (out / "fresh.materialized.json").is_file(),
    "external_verifier_boot": (out / "external-verifier-boot" / "verdict.json").is_file(),
    "external_verifier_fresh": (out / "external-verifier-fresh" / "verdict.json").is_file(),
}
verdict["passed"] = (
    verdict["runtime_started"]
    and verdict["meta_status"] == "200"
    and verdict["boot_status"] == "200"
    and verdict["fresh_status"] == "200"
    and verdict["meta_bytes"] > 0
    and verdict["boot_bytes"] > 0
    and verdict["fresh_bytes"] > 0
    and verdict["boot_materialized"]
    and verdict["fresh_materialized"]
)
(out / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
if not verdict["passed"]:
    raise SystemExit(1)
PY

if [ "$RESET_APP_DATA" = "1" ]; then
    adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
fi
echo "runtime probe evidence: $OUT"
