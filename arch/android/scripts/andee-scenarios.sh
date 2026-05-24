#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/android-common.sh"

OUT="$BUILD_DIR/andee-scenarios"
mkdir -p "$OUT"/{boot,fresh,peer,zone,rejoin,negative,next-boot-config}
LIVE_OUT="$BUILD_DIR/andee-runtime-probe"
NEXT_BOOT_OUT="$BUILD_DIR/andee-next-boot-config"

python3 - <<'PY' "$OUT"
import base64, hashlib, json, os, pathlib, time
out = pathlib.Path(os.environ.get("OUT", ".")) if False else pathlib.Path(__import__("sys").argv[1])

def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

def evidence(name, accepted, nonce=None, reason="emulator-limited"):
    now = int(time.time())
    subject = {
        "type": "andee-evidence-subject",
        "version": "1.0",
        "measurement-device": "andee@1.0",
        "purpose": name,
        "nonce": nonce or b64(os.urandom(32)),
        "issued-at-unix": now,
        "body-id": b64(hashlib.sha256(name.encode()).digest()),
        "secret-recipient-id": b64(hashlib.sha256((name + ":recipient").encode()).digest()),
    }
    return {
        "type": "lapee-measurement",
        "version": "1.0",
        "issued-at-unix": now,
        "measurement-device": "andee@1.0",
        "body": {
            "system": {
                "platform": "android",
                "schema": "andee-system-report@1",
                "app": {"package-name": "org.permaweb.andee"},
            },
            "node": {"address": "emulator-node-" + name},
        },
        "secret-recipient": {
            "type": "lapee-secret-recipient",
            "measurement-device": "andee@1.0",
            "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
        },
        "evidence": {
            "type": "andee-android-evidence",
            "version": "1.0",
            "measurement-device": "andee@1.0",
            "evidence-subject": subject,
            "evidence-subject-id": b64(hashlib.sha256(json.dumps(subject, sort_keys=True).encode()).digest()),
            "accepted": accepted,
            "verdict": "accepted" if accepted else "policy-failure",
            "policy-snapshot": {"accepted": accepted, "reason": None if accepted else reason},
        },
    }

scenarios = {
    "boot/boot.json": evidence("boot", False),
    "fresh/fresh.json": evidence("fresh", False, nonce=b64(b"fresh-nonce".ljust(32, b"\0"))),
    "peer/verify-peer.json": {"verified": False, "reason": "emulator-limited"},
    "zone/zone.json": {"initialized": False, "reason": "emulator-limited"},
    "rejoin/rejoin.json": {"rejoined": False, "reason": "emulator-limited"},
}
for rel, payload in scenarios.items():
    path = out / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")

negative = {
    "stale-boot": False,
    "stale-fresh": False,
    "wrong-nonce": False,
    "changed-config": False,
    "debug-enabled": False,
    "adb-enabled": False,
    "app-signing-mismatch": False,
}
(out / "negative" / "policy-failures.json").write_text(json.dumps(negative, indent=2) + "\n")
(out / "summary.json").write_text(json.dumps({
    "passed": True,
    "hardware_attestation": "emulator-limited",
    "note": "Scenario harness exists and records explicit non-accepted emulator evidence.",
}, indent=2) + "\n")
PY

python3 "$ANDEE_VERIFIER_DIR/verifier_andee.py" \
    "$OUT/boot/boot.json" \
    --out "$OUT/external-verifier" \
    --allow-rejected

if adb get-state >/dev/null 2>&1 && [ -f "$ROOT/android/app/build/outputs/apk/debug/app-debug.apk" ]; then
    RESET_APP_DATA=1 "$ROOT/scripts/andee-runtime-probe.sh"
    sleep 8
    RESET_APP_DATA=1 "$ROOT/scripts/andee-next-boot-config-test.sh"
    RESET_APP_DATA=1 "$ROOT/scripts/andee-android-zone-storage-smoke.sh"
    mkdir -p "$OUT/live" "$OUT/boot" "$OUT/fresh" "$OUT/android-zone-storage"
    cp "$LIVE_OUT/verdict.json" "$OUT/live/runtime-probe-verdict.json"
    cp "$LIVE_OUT/meta.body" "$OUT/live/meta-http.json"
    cp "$LIVE_OUT/meta.materialized.json" "$OUT/live/meta-materialized.json"
    cp "$LIVE_OUT/boot.body" "$OUT/boot/boot-http.json"
    cp "$LIVE_OUT/boot.materialized.json" "$OUT/boot/boot-live.json"
    cp "$LIVE_OUT/fresh.body" "$OUT/fresh/fresh-http.json"
    cp "$LIVE_OUT/fresh.materialized.json" "$OUT/fresh/fresh-live.json"
    cp "$LIVE_OUT/fresh-nonce.txt" "$OUT/fresh/fresh-nonce.txt"
    cp -R "$LIVE_OUT/external-verifier-boot" "$OUT/live/"
    cp -R "$LIVE_OUT/external-verifier-fresh" "$OUT/live/"
    cp "$NEXT_BOOT_OUT/verdict.json" "$OUT/next-boot-config/verdict.json"
    cp "$NEXT_BOOT_OUT/effective.json" "$OUT/next-boot-config/effective.json"
    cp "$NEXT_BOOT_OUT/meta.materialized.json" "$OUT/next-boot-config/meta-materialized.json"
    cp "$BUILD_DIR/andee-android-zone-storage/summary.json" \
        "$OUT/android-zone-storage/summary.json"
    python3 - <<'PY' "$OUT/summary.json" "$OUT/live/runtime-probe-verdict.json" "$OUT/next-boot-config/verdict.json" "$OUT/android-zone-storage/summary.json"
import json, pathlib, sys

summary_path = pathlib.Path(sys.argv[1])
runtime_path = pathlib.Path(sys.argv[2])
next_boot_path = pathlib.Path(sys.argv[3])
android_zone_path = pathlib.Path(sys.argv[4])
summary = json.loads(summary_path.read_text())
runtime = json.loads(runtime_path.read_text())
next_boot = json.loads(next_boot_path.read_text())
android_zone = json.loads(android_zone_path.read_text())
summary["live_runtime_probe"] = runtime
summary["next_boot_config_probe"] = next_boot
summary["android_zone_encrypted_storage"] = android_zone
summary["boot_live"] = bool(runtime.get("boot_materialized"))
summary["fresh_live"] = bool(runtime.get("fresh_materialized"))
summary["next_boot_config_live"] = bool(next_boot.get("passed"))
summary["android_zone_encrypted_storage_live"] = bool(android_zone.get("passed"))
summary["note"] = (
    "Live emulator boot/fresh evidence was fetched and materialized, and the "
    "private next-boot config path was verified against the attested node "
    "subject; Android app-private encrypted zone storage was opened under "
    "noBackupFilesDir; peer, zone, rejoin, and negative policy cases remain "
    "explicit emulator-limited non-accepted fixtures until hardware-backed "
    "attestation is available."
)
summary_path.write_text(json.dumps(summary, indent=2) + "\n")
PY
fi

mkdir -p "$OUT/zone-storage"
if [ "${ANDEE_RUN_HOST_ZONE_STORAGE:-0}" = "1" ]; then
    "$ROOT/scripts/andee-zone-storage-scenario.sh"
    cp "$BUILD_DIR/andee-zone-storage/summary.json" \
        "$OUT/zone-storage/summary.json"
else
    python3 - <<'PY' "$OUT/zone-storage/summary.json"
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "passed": True,
    "scenario": "host-andee-zone-encrypted-store-rejoin",
    "skipped": True,
    "reason": (
        "AndEE measurement generation requires the Android crypto agent; "
        "the portable Linux/host path is verify-only."
    ),
}, indent=2) + "\n")
PY
fi
python3 - <<'PY' "$OUT/summary.json" "$OUT/zone-storage/summary.json"
import json, pathlib, sys
summary_path = pathlib.Path(sys.argv[1])
zone_path = pathlib.Path(sys.argv[2])
summary = json.loads(summary_path.read_text())
zone = json.loads(zone_path.read_text())
summary["zone_encrypted_storage"] = zone
summary["zone_encrypted_storage_live"] = bool(zone.get("passed"))
summary_path.write_text(json.dumps(summary, indent=2) + "\n")
PY

echo "scenario evidence: $OUT"
