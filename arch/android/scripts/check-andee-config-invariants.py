#!/usr/bin/env python3
"""Check security invariants for shipped AndEE HyperBEAM config."""

from __future__ import annotations

import json
import pathlib
import sys
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE_CONFIG = ROOT / "config" / "andee.json"
BOOT_CONFIG_STORE = (
    ROOT
    / "android"
    / "app"
    / "src"
    / "main"
    / "java"
    / "org"
    / "permaweb"
    / "andee"
    / "AndeeBootConfigStore.kt"
)


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
        and hook.get("measurement-body-source") == "hook-body"
    )


def main() -> int:
    config = load(BASE_CONFIG)
    hooks = start_hooks(config)
    if not hooks:
        fail("base config must define on.start")
    if not is_measurement_boot_hook(hooks[0]):
        fail("first on.start hook must be measurement@1.0 boot POST over hook-body")
    if config.get("measurement-device") != "andee@1.0":
        fail("measurement-device must be andee@1.0")
    if config.get("load-remote-devices") is not False:
        fail("load-remote-devices must be false")
    stores = config.get("store")
    if not isinstance(stores, list) or not stores:
        fail("store must be a non-empty list")
    if stores[0].get("store-module") != "hb_store_volatile":
        fail("default store must be hb_store_volatile")
    store_text = BOOT_CONFIG_STORE.read_text()
    if '"measurement-body-source"' not in store_text:
        fail("operator config sanitizer must reserve measurement-body-source")
    operator_loop = 'hookList(operator.optJSONObject("on")?.opt("start"))'
    base_loop = 'hookList(base.optJSONObject("on")?.opt("start"))'
    if not (operator_loop in store_text and base_loop in store_text):
        fail("boot config store must merge operator and base on.start hooks")
    if store_text.index(operator_loop) > store_text.index(base_loop):
        fail("operator on.start hooks must run before base hooks")
    if "copyOperatorValue(hook)" not in store_text:
        fail("operator on.start hooks must be sanitized before merge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
