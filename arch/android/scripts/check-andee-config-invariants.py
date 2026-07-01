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


def is_volatile_store(value: Any, name: str) -> bool:
    return value == [
        {
            "store-module": "hb_store_volatile",
            "name": name,
            "ao-types": 'store-module="atom"',
        }
    ]


def is_runtime_store(value: Any) -> bool:
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


def is_volatile_arweave_index_store(value: Any) -> bool:
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


def main() -> int:
    config = load(BASE_CONFIG)
    hooks = start_hooks(config)
    if not hooks:
        fail("base config must define on.start")
    if not is_measurement_boot_hook(hooks[0]):
        fail("first on.start hook must be measurement@1.0 boot POST over hook-body")
    if config.get("measurement-device") != "andee@1.0":
        fail("measurement-device must be andee@1.0")
    for key in (
        "access-remote-cache-for-client",
        "cache-control",
        "default-codec",
        "default-index",
        "http-extra-opts",
        "load-remote-devices",
        "loaded-device-store",
        "name-resolvers",
        "port",
        "preloaded-devices-index",
        "preloaded-store",
        "process-sampler",
        "prometheus",
        "protocol",
        "routes",
        "store-defaults",
        "trusted-device-signers",
        "trusted-devices",
    ):
        if key in config:
            fail(f"base config should inherit common HyperBEAM default for {key}")
    if not is_runtime_store(config.get("store")):
        fail("base config must use volatile Android runtime store plus gateway reads")
    if not is_volatile_store(config.get("match-index"), "andee-volatile-match-index"):
        fail("base config must use volatile Android match index")
    if not is_volatile_arweave_index_store(config.get("arweave-index-store")):
        fail("base config must use volatile Android Arweave index store")
    if not is_volatile_store(config.get("priv-store"), "andee-volatile-priv-store"):
        fail("base config must use volatile Android private store")
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
    for key in ("store", "match-index", "arweave-index-store", "priv-store"):
        if f'copyBaseValue(base, merged, "{key}")' not in store_text:
            fail(f"boot config store must preserve base {key} after operator sanitization")
    for key in (
        "access-remote-cache-for-client",
        "arweave-index-store",
        "cache-control",
        "forge-bootstrap",
        "http-extra-opts",
        "load-remote-devices",
        "loaded-device-store",
        "match-index",
        "name-resolvers",
        "preloaded-devices-index",
        "preloaded-store",
        "priv-store",
        "store",
        "store-defaults",
        "trusted-device-signers",
    ):
        if f'"{key}"' not in store_text:
            fail(f"operator config sanitizer must reserve {key}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
