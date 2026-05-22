#!/usr/bin/env python3
"""Check security invariants for shipped LapEE HyperBEAM config."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_CONFIG = (
    ROOT
    / "arch"
    / "common"
    / "linux"
    / "buildroot-external"
    / "board"
    / "lapee"
    / "rootfs-overlay"
    / "etc"
    / "lapee"
    / "lapee.json"
)


def fail(path: pathlib.Path, message: str) -> None:
    print(f"{path}: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(path, f"invalid JSON: {exc}")
    if not isinstance(data, dict):
        fail(path, "top-level config must be a JSON object")
    return data


def start_hooks(config: dict[str, Any]) -> list[Any]:
    hooks = config.get("on", {}).get("start")
    if hooks is None:
        return []
    if isinstance(hooks, list):
        return hooks
    return [hooks]


def is_measurement_boot_hook(hook: Any) -> bool:
    return (
        isinstance(hook, dict)
        and hook.get("device") == "measurement@1.0"
        and hook.get("path") == "boot"
        and hook.get("method") == "POST"
    )


def is_zone_start_hook(hook: Any) -> bool:
    return (
        isinstance(hook, dict)
        and hook.get("device") == "zone@1.0"
        and hook.get("path") == "start"
        and hook.get("method") == "POST"
    )


def main() -> int:
    config = load(BASE_CONFIG)
    hooks = start_hooks(config)
    if not hooks:
        fail(BASE_CONFIG, "base config must define on.start")
    if not is_measurement_boot_hook(hooks[0]):
        fail(
            BASE_CONFIG,
            "first on.start hook must be measurement@1.0 boot POST",
        )
    if not any(is_zone_start_hook(hook) for hook in hooks[1:]):
        fail(
            BASE_CONFIG,
            "base config must include zone@1.0 start POST after measurement",
        )
    if "load-remote-devices" in config:
        fail(BASE_CONFIG, "base config must leave load-remote-devices to operator config")
    if config.get("trusted-device-signers"):
        fail(BASE_CONFIG, "base config must not pin trusted remote device signers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
