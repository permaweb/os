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

cleanup_forward() {
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
}

cleanup() {
    cleanup_forward
    adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    if [ "$RESET_APP_DATA" = "1" ]; then
        adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

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
  "priv-ouroboros-keys": {
    "test-provider": {
      "api-key": "andee-private-test-key",
      "base-url": "https://provider.example"
    }
  },
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

cleanup_forward
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

python3 - <<'PY' "$OUT" "$MARKER" "$STARTED" "$BASE_URL"
import json
import pathlib
import sys
import urllib.parse
import urllib.request

out = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
started = sys.argv[3] == "1"
base_url = sys.argv[4]

def fail(message):
    raise SystemExit(message)

def read_json(name):
    return json.loads((out / name).read_text())

def fetch_json(path):
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode())

def fetch_body(path):
    value = fetch_json(path)
    while isinstance(value, dict) and (
        "body" in value or "body+link" in value
    ):
        value = linked_value(value, "body")
    return value

effective = read_json("effective.json")
boot_raw = read_json("boot.body")
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
)
operator_only_needles = (
    "operator-requested-persistent-store",
    "operator-requested-private-store",
    "operator-requested",
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
    return value == [
        {
            "store-module": "hb_store_volatile",
            "name": name,
            "ao-types": 'store-module="atom"',
        }
    ]

def is_runtime_store(value):
    volatile = {
        "store-module": "hb_store_volatile",
        "name": "andee-volatile-store",
        "ao-types": 'store-module="atom"',
    }
    return value == [
        volatile,
        {
            "store-module": "hb_store_gateway",
            "access": ["read"],
            "ao-types": 'store-module="atom"',
            "local-store": [volatile],
        },
    ]

def is_volatile_arweave_index_store(value):
    return value == {
        "store-module": "hb_store_arweave",
        "ao-types": 'store-module="atom"',
        "index-store": [
            {
                "store-module": "hb_store_volatile",
                "name": "andee-volatile-arweave-index-store",
                "ao-types": 'store-module="atom"',
            }
        ],
    }

def assert_base_volatile_stores(node, label):
    if not is_runtime_store(node.get("store")):
        fail(f"{label} did not enforce volatile runtime store plus gateway reads")
    if not is_volatile_store(node.get("match-index"), "andee-volatile-match-index"):
        fail(f"{label} did not enforce volatile match index")
    if not is_volatile_arweave_index_store(node.get("arweave-index-store")):
        fail(f"{label} did not enforce volatile Arweave index store")
    if not is_volatile_store(node.get("priv-store"), "andee-volatile-priv-store"):
        fail(f"{label} did not enforce volatile private store")

def linked_value(message, key):
    link = message.get(f"{key}+link")
    if isinstance(link, str):
        return fetch_json(link)
    return message.get(key)

def assert_attested_public_volatile_store(node_link, key, name):
    value = fetch_json(f"{node_link}/{key}")
    if value.get("status") != 200:
        fail(f"attested node {key} did not resolve with HTTP 200")
    item = linked_value(value, "1")
    if not isinstance(item, dict):
        fail(f"attested node {key} did not resolve to a singleton store list")
    if value.get("2") is not None or value.get("2+link") is not None:
        fail(f"attested node {key} included more than one store entry")
    if item.get("store-module") != "hb_store_volatile":
        fail(f"attested node {key} did not enforce volatile store module")
    if item.get("name") != name:
        fail(f"attested node {key} did not enforce volatile store name")

def assert_attested_public_runtime_store(node_link):
    if fetch_body(f"{node_link}/store/1/store-module") != "hb_store_volatile":
        fail("attested node store first entry was not volatile")
    if fetch_body(f"{node_link}/store/1/name") != "andee-volatile-store":
        fail("attested node store first entry did not enforce volatile store name")
    if fetch_body(f"{node_link}/store/2/store-module") != "hb_store_gateway":
        fail("attested node store second entry was not gateway")
    if fetch_body(f"{node_link}/store/2/access/1") != "read":
        fail("attested node gateway store was not read-only")
    if (
        fetch_body(f"{node_link}/store/2/local-store/1/store-module")
        != "hb_store_volatile"
    ):
        fail("attested node gateway local store was not volatile")
    if (
        fetch_body(f"{node_link}/store/2/local-store/1/name")
        != "andee-volatile-store"
    ):
        fail("attested node gateway store did not cache into volatile store")

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
if effective.get("trusted-device-signers") != ["operator-requested-signer"]:
    fail("effective config did not preserve trusted remote device signers")
if effective.get("name-resolvers") != ["https://andee-next-boot.example/resolver"]:
    fail("effective config did not preserve measured remote name resolvers")
if effective.get("priv-ouroboros-keys") != {
    "test-provider": {
        "api-key": "andee-private-test-key",
        "base-url": "https://provider.example",
    }
}:
    fail("effective config did not preserve normal private node options")
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
if meta_node.get("name-resolvers") != ["https://andee-next-boot.example/resolver"]:
    fail("stock meta info did not include measured remote name resolvers")
if "priv-ouroboros-keys" in meta_node:
    fail("stock meta info exposed private node options")
if attested_node.get("andee-test-marker") != marker:
    fail("attested node message did not include selected marker")
if attested_node.get("measurement-device") != "andee@1.0":
    fail("attested node message did not enforce andee measurement device")
if attested_node.get("access-remote-cache-for-client") not in (None, False, "false"):
    fail("attested node message preserved operator access-remote-cache-for-client override")
if attested_node.get("load-remote-devices") not in (None, False, "false"):
    fail("attested node message preserved operator load-remote-devices override")
if attested_node.get("trusted-device-signers") != ["operator-requested-signer"]:
    fail("attested node message did not commit to trusted remote device signers")
if attested_node.get("name-resolvers") != ["https://andee-next-boot.example/resolver"]:
    fail("attested node message did not commit to measured remote name resolvers")
if "priv-ouroboros-keys" in attested_node:
    fail("attested public node exposed private node options")
if "cache-control" in attested_node:
    fail("attested node message preserved operator top-level cache-control override")
if "store-defaults" in attested_node:
    fail("attested node message preserved operator store-defaults override")
attested_body = linked_value(boot_raw, "body")
if not isinstance(attested_body, dict):
    fail("boot measurement body did not resolve")
attested_node_link = attested_body.get("node+link")
if not isinstance(attested_node_link, str):
    fail("boot measurement body did not include an attested node link")
assert_attested_public_runtime_store(attested_node_link)
assert_attested_public_volatile_store(
    attested_node_link,
    "match-index",
    "andee-volatile-match-index",
)
arweave_index_store = fetch_json(f"{attested_node_link}/arweave-index-store")
if arweave_index_store.get("store-module") != "hb_store_arweave":
    fail("attested node Arweave index store did not use hb_store_arweave")
if (
    fetch_body(f"{attested_node_link}/arweave-index-store/index-store/1/store-module")
    != "hb_store_volatile"
):
    fail("attested node Arweave index store was not volatile")
if (
    fetch_body(f"{attested_node_link}/arweave-index-store/index-store/1/name")
    != "andee-volatile-arweave-index-store"
):
    fail("attested node Arweave index store did not enforce volatile store name")
if "priv-store" in attested_node:
    fail("attested public node unexpectedly exposed private store config")
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
# The ornament view polls the app-private boot config every 5s once the node is
# ready; wait long enough for a directly staged next.json to flip the button.
sleep 7
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
cleanup
trap - EXIT

echo "next boot config evidence: $OUT"
