#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andee-tunnel-smoke"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
HOST_PORT="${HOST_PORT:-28738}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-240}"
PACKAGE="org.permaweb.andee"
REMOTE_CONFIG="/data/local/tmp/andee-tunnel-smoke.json"
RESET_APP_DATA="${RESET_APP_DATA:-1}"
TUNNEL_DEVICE="${TUNNEL_DEVICE:-tunnel@1.0}"
TUNNEL_IMPL="${TUNNEL_IMPL:-tF8WoGCazRaFsysvkvnYsa09nzxA42pQDCsoBFQTJII}"
TUNNEL_PEER="${TUNNEL_PEER:-https://smoke.solutions}"
PUBLIC_RETRIES="${PUBLIC_RETRIES:-20}"
PUBLIC_RETRY_SLEEP="${PUBLIC_RETRY_SLEEP:-1}"
MARKER="andee-tunnel-smoke-$(date +%Y%m%d%H%M%S)"

rm -rf "$OUT"
mkdir -p "$OUT"

cleanup() {
    adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
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

curl -fsS --max-time "$PROBE_TIMEOUT" \
    "$TUNNEL_PEER/~meta@1.0/info/trusted-devices/$TUNNEL_DEVICE" \
    > "$OUT/peer-trusted-device.txt"
if [ "$(cat "$OUT/peer-trusted-device.txt")" != "$TUNNEL_IMPL" ]; then
    echo "peer does not trust expected tunnel implementation" >&2
    exit 1
fi

cat > "$OUT/next-boot-config.json" <<JSON
{
  "andee-test-marker": "$MARKER",
  "trusted-devices": {
    "$TUNNEL_DEVICE": "$TUNNEL_IMPL"
  },
  "on": {
    "start": [
      {
        "device": "$TUNNEL_DEVICE",
        "path": "connect",
        "method": "POST",
        "peer": "$TUNNEL_PEER",
        "hook": {
          "result": "ignore"
        }
      }
    ]
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
adb shell "run-as $PACKAGE sh -c 'mkdir -p no_backup/boot-config no_backup/run; \
    cp $REMOTE_CONFIG no_backup/boot-config/next.json; \
    rm -f no_backup/boot-config/active.json no_backup/boot-config/effective.json; \
    rm -f no_backup/run/hyperbeam.stdout no_backup/run/hyperbeam.stderr'" \
    > "$OUT/stage.txt"
adb shell rm -f "$REMOTE_CONFIG" >/dev/null 2>&1 || true

adb shell am start -W -n "$PACKAGE/.OrnamentActivity" > "$OUT/activity.txt"
adb shell am start-foreground-service -n "$PACKAGE/.AndeeService" \
    > "$OUT/service-start.txt" 2>&1 || true

STARTED=0
for _ in $(seq 1 180); do
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
printf '%s\n' "$STARTED" > "$OUT/started.txt"

adb shell run-as "$PACKAGE" cat no_backup/boot-config/effective.json \
    > "$OUT/effective.json"
if [ "$STARTED" != 1 ]; then
    tail -120 "$OUT/hyperbeam.stderr" >&2 || true
    exit 1
fi

adb forward --remove "tcp:$HOST_PORT" >/dev/null 2>&1 || true
adb forward "tcp:$HOST_PORT" tcp:8734 > "$OUT/adb-forward.txt"

probe() {
    local name="$1"
    local url="$2"
    curl -sS --max-time "$PROBE_TIMEOUT" \
        -H "Accept: application/json" \
        -D "$OUT/$name.headers" \
        -o "$OUT/$name.body" \
        -w "%{http_code}\n" \
        "$url" > "$OUT/$name.status"
}

is_tunnel_unavailable() {
    python3 - "$1" <<'PY'
import json
import pathlib
import sys

try:
    body = json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if body.get("reason") == "tunnel-unavailable" else 1)
PY
}

probe_public() {
    local name="$1"
    local url="$2"
    local attempt
    for attempt in $(seq 1 "$PUBLIC_RETRIES"); do
        probe "$name" "$url" || true
        printf '%s\n' "$attempt" > "$OUT/$name.attempts"
        if [ "$(cat "$OUT/$name.status")" = "200" ]; then
            return 0
        fi
        if [ "$(cat "$OUT/$name.status")" = "404" ] && is_tunnel_unavailable "$OUT/$name.body"; then
            sleep "$PUBLIC_RETRY_SLEEP"
            continue
        fi
        return 1
    done
    return 1
}

BASE_URL="http://127.0.0.1:$HOST_PORT"
probe local-address "$BASE_URL/~meta@1.0/info/address"
probe local-info "$BASE_URL/~meta@1.0/info"
probe local-tunnel-status "$BASE_URL/~tunnel@1.0/status"
python3 "$ROOT/scripts/materialize-ao-json.py" \
    --base-url "$BASE_URL" \
    --output "$OUT/local-info.materialized.json" \
    "$OUT/local-info.body"

python3 - <<'PY' "$OUT"
import base64
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
doc = json.loads((out / "local-info.materialized.json").read_text())
body = doc.get("body", doc)
address = body["address"]
(out / "address.txt").write_text(address + "\n")
raw = base64.urlsafe_b64decode(address + "=" * (-len(address) % 4))
host = base64.b32encode(raw).decode().lower().rstrip("=") + ".smoke.solutions"
(out / "public-host.txt").write_text(host + "\n")
PY

ADDRESS="$(cat "$OUT/address.txt")"
PUBLIC_HOST="$(cat "$OUT/public-host.txt")"
PUBLIC_BASE="https://$PUBLIC_HOST"

probe_public public-address "$PUBLIC_BASE/~meta@1.0/info/address"
probe_public public-info "$PUBLIC_BASE/~meta@1.0/info"
python3 - <<'PY' "$OUT" "$PUBLIC_BASE" "$PUBLIC_RETRIES" "$PUBLIC_RETRY_SLEEP"
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

out = pathlib.Path(sys.argv[1])
base_url = sys.argv[2]
retries = int(sys.argv[3])
retry_sleep = float(sys.argv[4])

attempts: dict[str, int] = {}

def fetch_json(message_id: str) -> Any:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", message_id)
    last_error = None
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, headers={"Accept": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                attempts[message_id] = attempt
                return json.loads(response.read().decode())
        except urllib.error.HTTPError as exc:
            last_error = exc
            body = exc.read().decode(errors="replace")
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                raise
            if exc.code == 404 and parsed.get("reason") == "tunnel-unavailable":
                time.sleep(retry_sleep)
                continue
            raise
    assert last_error is not None
    raise last_error

def materialize(value: Any, stack: set[str], cache: dict[str, Any]) -> Any:
    if isinstance(value, list):
        return [materialize(item, stack, cache) for item in value]
    if not isinstance(value, dict):
        return value
    out_msg: dict[str, Any] = {}
    for key, item in value.items():
        if key.endswith("+link") and isinstance(item, str):
            target_key = key[:-5]
            if item in cache:
                out_msg[target_key] = cache[item]
            elif item in stack:
                out_msg[target_key] = {"link": item, "cycle": True}
            else:
                stack.add(item)
                out_msg[target_key] = materialize(fetch_json(item), stack, cache)
                cache[item] = out_msg[target_key]
                stack.remove(item)
            continue
        out_msg[key] = materialize(item, stack, cache)
    return out_msg

payload = json.loads((out / "public-info.body").read_text())
(out / "public-info.materialized.json").write_text(
    json.dumps(materialize(payload, set(), {}), indent=2) + "\n"
)
(out / "public-materialize-attempts.json").write_text(
    json.dumps(attempts, indent=2, sort_keys=True) + "\n"
)
PY

python3 - <<'PY' "$OUT" "$MARKER" "$ADDRESS" "$PUBLIC_HOST" "$TUNNEL_DEVICE" "$TUNNEL_IMPL" "$TUNNEL_PEER"
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
address = sys.argv[3]
public_host = sys.argv[4]
tunnel_device = sys.argv[5]
tunnel_impl = sys.argv[6]
tunnel_peer = sys.argv[7]

def fail(message):
    raise SystemExit(message)

def read(name):
    path = out / name
    return path.read_text(errors="ignore").strip() if path.exists() else ""

def read_json(name):
    return json.loads((out / name).read_text())

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

effective = read_json("effective.json")
local_info = read_json("local-info.materialized.json")
public_info = read_json("public-info.materialized.json")
local_node = local_info.get("body", local_info)
public_node = public_info.get("body", public_info)
hooks = effective.get("on", {}).get("start")
if isinstance(hooks, dict):
    hooks = [hooks]

if read("started.txt") != "1":
    fail("HyperBEAM did not report startup")
if read("peer-trusted-device.txt") != tunnel_impl:
    fail("smoke peer did not report expected trusted tunnel device")
if effective.get("andee-test-marker") != marker:
    fail("effective config did not include selected tunnel marker")
if effective.get("trusted-devices", {}).get(tunnel_device) != tunnel_impl:
    fail("effective config did not include pinned tunnel archive")
if not hooks or not any(
    hook.get("device") == tunnel_device
    and hook.get("path") == "connect"
    and hook.get("peer") == tunnel_peer
    for hook in hooks
):
    fail("effective config did not include tunnel connect hook")
if not is_runtime_store(effective.get("store")):
    fail("effective config did not keep volatile store plus gateway reads")
if not is_volatile_store(effective.get("match-index"), "andee-volatile-match-index"):
    fail("effective config did not keep volatile match index")
if not is_volatile_store(effective.get("priv-store"), "andee-volatile-priv-store"):
    fail("effective config did not keep volatile private store")
for name in (
    "local-address",
    "local-info",
    "local-tunnel-status",
    "public-address",
    "public-info",
):
    if read(f"{name}.status") != "200":
        fail(f"{name} did not return HTTP 200")
if local_node.get("address") != address:
    fail("local info address mismatch")
if public_node.get("address") != address:
    fail("public info address mismatch")
public_address = read_json("public-address.body")
if public_address.get("body") != address:
    fail("public address body mismatch")
tunnel_status = read_json("local-tunnel-status.body")
if tunnel_status.get("status") != 200:
    fail("local tunnel status body mismatch")
summary = {
    "scenario": "andee-tunnel-smoke",
    "passed": True,
    "marker": marker,
    "address": address,
    "public_host": public_host,
    "tunnel_device": tunnel_device,
    "tunnel_impl": tunnel_impl,
    "peer": tunnel_peer,
    "local_address_status": "200",
    "local_info_status": "200",
    "local_tunnel_status": "200",
    "public_address_status": "200",
    "public_info_status": "200",
    "public_address_attempts": int(read("public-address.attempts") or "0"),
    "public_info_attempts": int(read("public-info.attempts") or "0"),
    "evidence": {
        "effective_config": str(out / "effective.json"),
        "local_info": str(out / "local-info.materialized.json"),
        "public_info": str(out / "public-info.materialized.json"),
        "public_materialize_attempts": str(out / "public-materialize-attempts.json"),
    },
}
(out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
PY

cleanup
trap - EXIT

echo "andee tunnel smoke evidence: $OUT"
