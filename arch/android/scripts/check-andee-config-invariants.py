#!/usr/bin/env python3
"""Check security invariants for shipped AndEE HyperBEAM config."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_CONFIG = ROOT / "config" / "andee.json"


def fail(message: str) -> None:
    print(f"{BASE_CONFIG}: {message}", file=sys.stderr)
    raise SystemExit(1)


def load(path: pathlib.Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"invalid JSON: {exc}")
    if not isinstance(data, dict):
        fail("top-level config must be a JSON object")
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


def main() -> int:
    config = load(BASE_CONFIG)
    hooks = start_hooks(config)
    if not hooks:
        fail("base config must define on.start")
    if not is_measurement_boot_hook(hooks[0]):
        fail("first on.start hook must be measurement@1.0 boot POST")
    if config.get("measurement-device") != "andee@1.0":
        fail("measurement-device must be andee@1.0")
    if config.get("load-remote-devices") is not False:
        fail("load-remote-devices must be false")
    stores = config.get("store")
    if not isinstance(stores, list) or not stores:
        fail("store must be a non-empty list")
    if stores[0].get("store-module") != "hb_store_volatile":
        fail("default store must be hb_store_volatile")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
