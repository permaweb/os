#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andee-smoke"
rm -rf "$OUT"
mkdir -p "$OUT"
APK="${APK:-$ROOT/android/app/build/outputs/apk/debug/app-debug.apk}"
PACKAGE="org.permaweb.andee"
KEEP_ANDEE_RUNNING="${KEEP_ANDEE_RUNNING:-0}"

cleanup_app() {
    if [ "$KEEP_ANDEE_RUNNING" != "1" ]; then
        adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    fi
}
trap cleanup_app EXIT

if [ ! -f "$APK" ]; then
    echo "APK missing: $APK" >&2
    exit 1
fi

adb logcat -c || true
adb uninstall "$PACKAGE" >/dev/null 2>&1 || true
adb install -r "$APK" | tee "$OUT/install.txt"
adb shell am start -n "$PACKAGE/.OrnamentActivity" | tee "$OUT/activity.txt"
adb shell am start-foreground-service -n "$PACKAGE/.AndeeService" \
    > "$OUT/service-start.txt" 2>&1 || true
for _ in $(seq 1 90); do
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stdout \
        > "$OUT/hyperbeam.stdout" 2>/dev/null || true
    adb shell run-as "$PACKAGE" cat no_backup/run/hyperbeam.stderr \
        > "$OUT/hyperbeam.stderr" 2>/dev/null || true
    if grep -q "AndEE HyperBEAM node started" "$OUT/hyperbeam.stdout"; then
        break
    fi
    sleep 1
done
adb shell dumpsys activity services "$PACKAGE" > "$OUT/services.txt" || true
adb shell cmd package list packages -U "$PACKAGE" \
    > "$OUT/package-uid.txt" 2>/dev/null || true
adb shell ps -A -o USER,UID,PID,NAME > "$OUT/app-ps.txt" 2>/dev/null || true
adb shell run-as "$PACKAGE" ls -R no_backup > "$OUT/no-backup.txt" 2>/dev/null || true
adb logcat -d -s AndeeService RuntimeExtractor AndeeCryptoAgent HyperbeamRuntime \
    > "$OUT/logcat.txt" || true
python3 - <<'PY' "$OUT/policy-frame.bin"
import json, pathlib, struct, sys
payload = json.dumps({"action": "policy-status"}, separators=(",", ":")).encode()
pathlib.Path(sys.argv[1]).write_bytes(struct.pack(">I", len(payload)) + payload)
PY
adb push "$OUT/policy-frame.bin" /data/local/tmp/andee-policy-frame.bin >/dev/null 2>&1 || true
adb shell chmod 644 /data/local/tmp/andee-policy-frame.bin >/dev/null 2>&1 || true
if adb exec-out run-as "$PACKAGE" sh -c \
    'toybox nc -U no_backup/run/andee-crypto.sock < /data/local/tmp/andee-policy-frame.bin' \
    > "$OUT/policy-response.bin" 2>/dev/null; then
    python3 - <<'PY' "$OUT/policy-response.bin" "$OUT/policy-response.json"
import json, pathlib, struct, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
if len(raw) >= 4:
    size = struct.unpack(">I", raw[:4])[0]
    if len(raw) >= 4 + size:
        pathlib.Path(sys.argv[2]).write_text(
            json.dumps(json.loads(raw[4:4 + size]), indent=2) + "\n"
        )
PY
fi

python3 - <<'PY' "$OUT"
import json, pathlib, re, sys, time
out = pathlib.Path(sys.argv[1])
services = (out / "services.txt").read_text(errors="ignore")
runtime = (out / "no-backup.txt").read_text(errors="ignore")
logcat = (out / "logcat.txt").read_text(errors="ignore")
stdout = (out / "hyperbeam.stdout").read_text(errors="ignore")
stderr = (out / "hyperbeam.stderr").read_text(errors="ignore")
app_ps = (out / "app-ps.txt").read_text(errors="ignore")
package_uid = (out / "package-uid.txt").read_text(errors="ignore")
policy = (out / "policy-response.json").read_text(errors="ignore") if (out / "policy-response.json").exists() else ""
policy_rejected = "policy rejected" in logcat
match = re.search(r"uid[:=](\d+)", package_uid)
uid = match.group(1) if match else None
runtime_started = (
    "AndEE HyperBEAM node started" in stdout and
    "Runtime terminating during boot" not in stderr
)
runtime_extracted = (
    "andee-runtime" in runtime or
    "runtime extracted" in logcat or
    "runtime ready" in logcat
)
agent_policy_seen = '"policy-snapshot"' in policy
verdict = {
    "scenario": "single-android-andee-smoke",
    "issued_at_unix": int(time.time()),
    "service_seen": "AndeeService" in services,
    "runtime_extracted": runtime_extracted,
    "runtime_started": runtime_started,
    "policy_rejected": policy_rejected,
    "agent_policy_response": agent_policy_seen,
    "hardware_attestation": "emulator-limited",
}
verdict["passed"] = (
    verdict["service_seen"] and
    verdict["runtime_extracted"] and
    verdict["runtime_started"]
)
(out / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
if not verdict["passed"]:
    raise SystemExit(1)
PY
echo "smoke evidence: $OUT"
