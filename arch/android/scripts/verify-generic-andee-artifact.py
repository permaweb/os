#!/usr/bin/env python3
"""Reject application-coupled AndEE runtime ZIPs and APKs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path
from typing import BinaryIO


FORBIDDEN_TOKENS = (b"ouroboros",)
ABIS = ("arm64-v8a", "x86_64")
DEVICE_BEAMS = (
    "dev_andock.beam",
    "lib_andock.beam",
    "dev_inference.beam",
    "lib_andee_inference.beam",
    "lib_permawebos_bash_session.beam",
    "lib_permawebos_execution.beam",
    "lib_permawebos_execution_tools.beam",
)
DEVICE_PRIV_FILES = (
    "lapee-p4/hyper-token-p4.lua",
    "lapee-p4/hyper-token.lua",
)
APK_ANDOCK_NATIVE = (
    "lib/arm64-v8a/libandee_proot.so",
    "lib/arm64-v8a/libandee_andock_launcher.so",
    "lib/arm64-v8a/libandee_proot_loader.so",
)
APK_INFERENCE_NATIVE = (
    "lib/arm64-v8a/libLiteRtDispatch_GoogleTensor.so",
    "lib/arm64-v8a/liblitertlm_jni.so",
    "lib/x86_64/liblitertlm_jni.so",
    "lib/arm64-v8a/libandee_llama_server.so",
    "lib/arm64-v8a/libllama-server-impl.so",
    "lib/arm64-v8a/libllama-common.so",
    "lib/arm64-v8a/libmtmd.so",
    "lib/arm64-v8a/libllama.so",
    "lib/arm64-v8a/libggml.so",
    "lib/arm64-v8a/libggml-base.so",
    "lib/arm64-v8a/libggml-cpu-android_armv8.0_1.so",
    "lib/arm64-v8a/libggml-cpu-android_armv8.2_1.so",
    "lib/arm64-v8a/libggml-cpu-android_armv8.2_2.so",
    "lib/arm64-v8a/libggml-cpu-android_armv8.6_1.so",
    "lib/arm64-v8a/libggml-cpu-android_armv9.0_1.so",
    "lib/arm64-v8a/libggml-cpu-android_armv9.2_1.so",
    "lib/arm64-v8a/libggml-cpu-android_armv9.2_2.so",
)
APK_INFERENCE_NOTICES = (
    "assets/litertlm-android-0.16.1/LICENSE",
    "assets/litertlm-android-0.16.1/THIRD_PARTY_NOTICE.txt",
    "assets/llama-cpp-b10502/LICENSE",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def scan_stream(handle: BinaryIO, label: str) -> None:
    overlap = max(map(len, FORBIDDEN_TOKENS)) - 1
    previous = b""
    while chunk := handle.read(1024 * 1024):
        data = (previous + chunk).lower()
        for token in FORBIDDEN_TOKENS:
            if token in data:
                raise SystemExit(f"application content in {label}")
        previous = data[-overlap:]


def scan_archive(archive: zipfile.ZipFile, label: str) -> None:
    for info in archive.infolist():
        name = info.filename.lower().encode()
        if any(token in name for token in FORBIDDEN_TOKENS):
            raise SystemExit(f"application-specific archive entry in {label}")
        if name.endswith((b".litertlm", b".gguf")):
            raise SystemExit(f"inference model embedded in {label}")
        if info.is_dir():
            continue
        with archive.open(info) as handle:
            scan_stream(handle, f"{label}:{info.filename}")


def inspect_runtime(archive: zipfile.ZipFile) -> dict[str, object]:
    names = set(archive.namelist())
    beams: dict[str, dict[str, str]] = {}
    for abi in ABIS:
        abi_beams: dict[str, str] = {}
        for beam in DEVICE_BEAMS:
            name = f"erlang/{abi}/lib/andee_devices/ebin/{beam}"
            if name not in names:
                raise SystemExit(f"missing generic Andock device module: {name}")
            abi_beams[beam] = hashlib.sha256(archive.read(name)).hexdigest()
        beams[abi] = abi_beams
        for relative in DEVICE_PRIV_FILES:
            name = f"erlang/{abi}/lib/andee_devices/priv/{relative}"
            if name not in names:
                raise SystemExit(f"missing Android device priv asset: {name}")
    scan_archive(archive, "runtime")
    return {
        "entry-count": len(names),
        "andock-device-beams": beams,
        "application-negative-scan": {
            "entries-scanned": len(names),
            "forbidden-token-count": len(FORBIDDEN_TOKENS),
            "result": "clean",
        },
    }


def inspect_runtime_path(path: Path) -> dict[str, object]:
    with zipfile.ZipFile(path) as archive:
        result = inspect_runtime(archive)
    result["runtime-sha256"] = sha256(path)
    return result


def inspect_apk(
    path: Path,
    aapt2: Path | None,
    apksigner: Path | None,
) -> dict[str, object]:
    with zipfile.ZipFile(path) as apk:
        names = set(apk.namelist())
        for native in APK_ANDOCK_NATIVE:
            if native not in names:
                raise SystemExit(f"missing generic Andock native capability: {native}")
        for native in APK_INFERENCE_NATIVE:
            if native not in names:
                raise SystemExit(f"missing generic inference native capability: {native}")
        for notice in APK_INFERENCE_NOTICES:
            if notice not in names:
                raise SystemExit(f"missing LiteRT legal notice: {notice}")
        runtime_name = "assets/andee-runtime.zip"
        if runtime_name not in names:
            raise SystemExit("APK does not contain assets/andee-runtime.zip")
        scan_archive(apk, "apk")
        with tempfile.TemporaryFile() as nested:
            with apk.open(runtime_name) as source:
                while chunk := source.read(1024 * 1024):
                    nested.write(chunk)
            nested.seek(0)
            runtime_sha256 = hashlib.sha256(nested.read()).hexdigest()
            nested.seek(0)
            with zipfile.ZipFile(nested) as runtime:
                runtime_evidence = inspect_runtime(runtime)
    evidence = {
        "artifact": str(path.resolve()),
        "apk-sha256": sha256(path),
        "entry-count": len(names),
        "andock-native-capabilities": list(APK_ANDOCK_NATIVE),
        "inference-native-capabilities": list(APK_INFERENCE_NATIVE),
        "inference-legal-notices": list(APK_INFERENCE_NOTICES),
        "runtime-sha256": runtime_sha256,
        "runtime": runtime_evidence,
        "application-negative-scan": {
            "apk-and-nested-runtime": "clean",
            "forbidden-token-count": len(FORBIDDEN_TOKENS),
        },
    }
    if aapt2:
        badging = subprocess.run(
            [str(aapt2), "dump", "badging", str(path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        package_match = re.search(r"^package: name='([^']+)'", badging, re.MULTILINE)
        if not package_match or package_match.group(1) != "org.permaweb.andee":
            raise SystemExit("unexpected Android package identity")
        evidence["package-name"] = package_match.group(1)
    if apksigner:
        signature = subprocess.run(
            [str(apksigner), "verify", "--print-certs", str(path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        certificate_lines = [
            line.strip()
            for line in signature.splitlines()
            if line.strip().startswith("Signer #")
        ]
        if not certificate_lines:
            raise SystemExit("APK signature verification returned no signer certificate")
        evidence["signature-verification"] = "verified"
        evidence["signer-certificates"] = certificate_lines
    return evidence


def main() -> None:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--runtime", type=Path)
    group.add_argument("--apk", type=Path)
    parser.add_argument("--expected-runtime-sha256")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--aapt2", type=Path)
    parser.add_argument("--apksigner", type=Path)
    args = parser.parse_args()

    if args.runtime:
        evidence = inspect_runtime_path(args.runtime)
    else:
        evidence = inspect_apk(args.apk, args.aapt2, args.apksigner)
    if (
        args.expected_runtime_sha256
        and evidence["runtime-sha256"] != args.expected_runtime_sha256
    ):
        raise SystemExit("APK runtime ZIP does not match the built runtime ZIP")
    output = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    if args.evidence:
        args.evidence.parent.mkdir(parents=True, exist_ok=True)
        args.evidence.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
