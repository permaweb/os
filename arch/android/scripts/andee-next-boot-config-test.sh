#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andee-next-boot-config"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28736}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-240}"
PACKAGE="org.permaweb.andee"
RESET_APP_DATA="${RESET_APP_DATA:-0}"
REMOTE_CONFIG="/data/local/tmp/andee-next-boot-config.json"
MARKER="andee-next-boot-config-$(date +%Y%m%d%H%M%S)"

rm -rf "$OUT"
mkdir -p "$OUT"

if [ ! -f "$APK" ]; then
    echo "APK missing: $APK" >&2
    exit 1
fi

cat > "$OUT/next-boot-config.json" <<JSON
{
  "public-url": "https://andee-next-boot.example/$MARKER",
  "andee-test-marker": "$MARKER",
  "measurement-device": "not-andee@1.0",
  "access-remote-cache-for-client": true,
  "cache-control": ["always"],
  "http-extra-opts": {
    "cache-control": ["always"]
  },
  "load-remote-devices": true,
  "match-index": [],
  "name-resolvers": ["https://andee-next-boot.example/resolver"],
  "store": [
    {
      "store-module": "hb_store_fs",
      "name": "operator-requested-persistent-store"
    }
  ],
  "priv-store": [
    {
      "store-module": "hb_store_fs",
      "name": "operator-requested-private-store"
    }
  ],
  "store-defaults": {
    "scope": "operator-requested"
  },
  "trusted-device-signers": ["operator-requested-signer"],
  "on": {
    "request": []
  }
}
JSON

adb shell "run-as $PACKAGE sh -c 'kill \$(pidof beam.smp 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof erlexec 2>/dev/null) 2>/dev/null || true; \
    kill \$(pidof libandee_hyperbeam.so 2>/dev/null) 2>/dev/null || true'" \
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
adb push "$OUT/next-boot-config.json" "$REMOTE_CONFIG" > "$OUT/push.txt"
adb shell "run-as $PACKAGE sh -c 'mkdir -p no_backup/boot-config; \
    cp $REMOTE_CONFIG no_backup/boot-config/next.json; \
    rm -f no_backup/boot-config/active.json no_backup/boot-config/effective.json; \
    rm -f no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr'" \
    > "$OUT/stage.txt"
adb shell rm -f "$REMOTE_CONFIG" >/dev/null 2>&1 || true

adb shell am start -W -n "$PACKAGE/.OrnamentActivity" > "$OUT/activity.txt"

STARTED=0
for _ in $(seq 1 45); do
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        > "$OUT/hyperbeam.stdout" 2>/dev/null || true
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
        > "$OUT/hyperbeam.stderr" 2>/dev/null || true
    if grep -q "AndEE HyperBEAM node started" "$OUT/hyperbeam.stdout"; then
        STARTED=1
        break
    fi
    sleep 1
done

adb shell run-as "$PACKAGE" cat no_backup/boot-config/effective.json \
    > "$OUT/effective.json"
adb shell run-as "$PACKAGE" test ! -f no_backup/boot-config/next.json \
    > "$OUT/pending-consumed.txt"
adb shell run-as "$PACKAGE" test -f no_backup/boot-config/active.json \
    > "$OUT/active-present.txt"

adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
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

probe meta "/~meta@1.0/info"
probe boot "/~measurement@1.0/boot"

BASE_URL="http://127.0.0.1:$HOST_PORT"
for name in meta boot; do
    if [ "$(cat "$OUT/$name.status")" = "200" ]; then
        python3 "$ROOT/scripts/materialize-ao-json.py" \
            --base-url "$BASE_URL" \
            --output "$OUT/$name.materialized.json" \
            "$OUT/$name.body"
    fi
done

python3 - <<'PY' "$OUT" "$MARKER" "$STARTED"
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
started = sys.argv[3] == "1"

def fail(message):
    raise SystemExit(message)

def read_json(name):
    return json.loads((out / name).read_text())

effective = read_json("effective.json")
meta = read_json("meta.materialized.json")
boot = read_json("boot.materialized.json")
meta_node = meta.get("body", meta)
measurement = boot.get("body", boot)
attested_node = measurement.get("node") or {}
hooks = effective.get("on", {}).get("start")
if isinstance(hooks, dict):
    hooks = [hooks]

reserved_runtime_keys = (
    "access-remote-cache-for-client",
    "cache-control",
    "http-extra-opts",
    "load-remote-devices",
    "name-resolvers",
    "trusted-device-signers",
)
operator_only_needles = (
    "operator-requested-persistent-store",
    "operator-requested-private-store",
    "operator-requested",
    "operator-requested-signer",
    "https://andee-next-boot.example/resolver",
)

def contains_value(value, needle):
    if value == needle:
        return True
    if isinstance(value, dict):
        return any(contains_value(child, needle) for child in value.values())
    if isinstance(value, list):
        return any(contains_value(child, needle) for child in value)
    return False

def is_volatile_store(value, name):
    return value == [{"store-module": "hb_store_volatile", "name": name}]

def assert_base_volatile_stores(node, label):
    if not is_volatile_store(node.get("store"), "andee-volatile-store"):
        fail(f"{label} did not enforce volatile runtime store")
    if not is_volatile_store(node.get("match-index"), "andee-volatile-match-index"):
        fail(f"{label} did not enforce volatile match index")
    if not is_volatile_store(node.get("priv-store"), "andee-volatile-priv-store"):
        fail(f"{label} did not enforce volatile private store")

if not started:
    fail("HyperBEAM did not report startup")
if (out / "meta.status").read_text().strip() != "200":
    fail("~meta@1.0/info did not return HTTP 200")
if (out / "boot.status").read_text().strip() != "200":
    fail("~measurement@1.0/boot did not return HTTP 200")
if effective.get("andee-test-marker") != marker:
    fail("effective config did not include selected next-boot marker")
if effective.get("measurement-device") != "andee@1.0":
    fail("effective config did not enforce andee measurement device")
for key in reserved_runtime_keys:
    if key in effective:
        fail(f"effective config preserved reserved runtime key: {key}")
assert_base_volatile_stores(effective, "effective config")
for needle in operator_only_needles:
    if contains_value(effective, needle):
        fail(f"effective config preserved operator-only runtime value: {needle}")
if not hooks:
    fail("effective config has no on.start hook")
first_hook = hooks[0]
if not (
    first_hook.get("device") == "measurement@1.0"
    and first_hook.get("path") == "boot"
    and first_hook.get("method") == "POST"
    and first_hook.get("measurement-body-source") == "hook-body"
):
    fail("effective config did not preserve measurement boot hook over hook-body first")
if meta_node.get("andee-test-marker") != marker:
    fail("stock meta info did not include selected marker")
if attested_node.get("andee-test-marker") != marker:
    fail("attested node message did not include selected marker")
if attested_node.get("measurement-device") != "andee@1.0":
    fail("attested node message did not enforce andee measurement device")
if attested_node.get("access-remote-cache-for-client") not in (None, False, "false"):
    fail("attested node message preserved operator access-remote-cache-for-client override")
if attested_node.get("load-remote-devices") not in (None, False, "false"):
    fail("attested node message preserved operator load-remote-devices override")
if "cache-control" in attested_node:
    fail("attested node message preserved operator top-level cache-control override")
if "store-defaults" in attested_node:
    fail("attested node message preserved operator store-defaults override")
assert_base_volatile_stores(attested_node, "attested node message")
for needle in operator_only_needles:
    if contains_value(attested_node, needle):
        fail(f"attested node message preserved operator-only runtime value: {needle}")

verdict = {
    "scenario": "andee-next-boot-config",
    "passed": True,
    "marker": marker,
    "meta_status": "200",
    "boot_status": "200",
    "effective_config": "effective.json",
    "attested_marker": attested_node.get("andee-test-marker"),
}
(out / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
PY

adb push "$OUT/next-boot-config.json" "$REMOTE_CONFIG" > "$OUT/push-terminate.txt"
adb shell "run-as $PACKAGE sh -c 'cp $REMOTE_CONFIG no_backup/boot-config/next.json'" \
    > "$OUT/restage-terminate.txt"
adb shell rm -f "$REMOTE_CONFIG" >/dev/null 2>&1 || true
sleep 3
read -r SCREEN_WIDTH SCREEN_HEIGHT < <(
    adb shell wm size | tr -d '\r' | awk -F'[ x]' '/Physical size/ {print $(NF-1), $NF}'
)
TAP_X=$((SCREEN_WIDTH / 4))
TAP_Y=$((SCREEN_HEIGHT * 915 / 1000))
adb shell input tap "$TAP_X" "$TAP_Y"
TERMINATED=0
for _ in $(seq 1 30); do
    adb shell ps -A > "$OUT/post-terminate-ps.txt"
    if ! grep -Eq "($PACKAGE|beam\\.smp|erlexec|libandee_hyperbeam\\.so)" \
        "$OUT/post-terminate-ps.txt"; then
        TERMINATED=1
        break
    fi
    sleep 1
done
if [ "$TERMINATED" != "1" ]; then
    echo "AndEE app or BEAM runtime still running after TERMINATE button tap" >&2
    exit 1
fi
adb shell dumpsys activity activities > "$OUT/post-terminate-activities.txt"
if grep -q 'topResumedActivity=.*org.permaweb.andee/.OrnamentActivity' \
    "$OUT/post-terminate-activities.txt"; then
    echo "OrnamentActivity still resumed after TERMINATE button tap" >&2
    exit 1
fi
adb shell run-as "$PACKAGE" test ! -f no_backup/boot-config/next.json \
    > "$OUT/post-terminate-pending-consumed.txt"
adb shell run-as "$PACKAGE" test -f no_backup/boot-config/active.json \
    > "$OUT/post-terminate-active-present.txt"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
if [ "$RESET_APP_DATA" = "1" ]; then
    adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
fi

echo "next boot config evidence: $OUT"
