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
ANDEE_SOURCE = BOOT_CONFIG_STORE.parent
INFERENCE_MODELS = ANDEE_SOURCE / "AndeeInferenceModels.kt"
ANDOCK_MATERIALIZER = ANDEE_SOURCE / "AndeeAndockImageMaterializer.kt"


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
    persistent = {
        "store-module": "hb_store_lmdb",
        "name": "../node-store",
        "capacity": 8589934592,
        "batch-size": 100,
        "ao-types": 'store-module="atom", capacity="integer", batch-size="integer"',
    }
    preloaded = {
        "store-module": "hb_store_lmdb",
        "name": "_build/preloaded-store",
        "capacity": 1073741824,
        "read-only": True,
        "ao-types": 'store-module="atom"',
    }
    return value == [
        persistent,
        {
            "store-module": "hb_store_arweave",
            "ao-types": 'store-module="atom"',
            "index-store": [
                {
                    "store-module": "hb_store_volatile",
                    "name": "andee-volatile-arweave-index-store",
                    "ao-types": 'store-module="atom"',
                }
            ],
            "local-store": [
                {
                    "store-module": "hb_store_volatile",
                    "name": "andee-volatile-gateway-cache",
                    "ao-types": 'store-module="atom"',
                }
            ],
            "remote-index": True,
        },
        {
            "store-module": "hb_store_gateway",
            "access": ["read"],
            "ao-types": 'store-module="atom"',
            "local-store": [
                {
                    "store-module": "hb_store_volatile",
                    "name": "andee-volatile-gateway-cache",
                    "ao-types": 'store-module="atom"',
                }
            ],
            "preloaded-store": preloaded,
        },
    ]


def is_private_store(value: Any) -> bool:
    return value == [
        {
            "store-module": "hb_store_lmdb",
            "name": "../private-store",
            "capacity": 1073741824,
            "batch-size": 100,
            "ao-types": 'store-module="atom", capacity="integer", batch-size="integer"',
        }
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
        "local-store": [
            {
                "store-module": "hb_store_volatile",
                "name": "andee-volatile-gateway-cache",
                "ao-types": 'store-module="atom"',
            }
        ],
        "remote-index": True,
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
    if config.get("idle-timeout") != 660000:
        fail("HTTP idle timeout must exceed the ten-minute inference deadline")
    andock_image = config.get("andock-default-image")
    if not isinstance(andock_image, str) or len(andock_image) != 43:
        fail("andock-default-image must be one native Arweave transaction ID")
    providers = config.get("inference-providers")
    if not isinstance(providers, dict) or list(providers) != ["local-andee"]:
        fail("base config must define only the local-andee inference provider")
    local_provider = providers["local-andee"]
    if local_provider.get("inference-device") != "andee-inference@1.0":
        fail("local-andee must resolve through andee-inference@1.0")
    if local_provider.get("default-model") != "gemma-4-e2b-it-tensor-g5":
        fail("Gemma 4 E2B Tensor G5 must be the default local model")
    models = local_provider.get("models")
    if not isinstance(models, list) or [model.get("id") for model in models] != [
        "gemma-4-e2b-it-tensor-g5",
        "functiongemma-mobile-actions",
    ]:
        fail("base local model catalogue must contain only Gemma 4 and FunctionGemma")
    if [model.get("max-context-tokens") for model in models] != [4096, 1024]:
        fail("local model context limits must match their compiled state")
    for model in models:
        if not isinstance(model.get("model-id"), str) or len(model["model-id"]) != 43:
            fail("local inference models must use Arweave model-id values")
        if any(key in model for key in ("file", "url", "sha256")):
            fail(
                "local inference models must use their Arweave ID without "
                "parallel path, URL, or digest trust fields"
            )
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
        fail(
            "base config must prefer remote-indexed Arweave reads before the "
            "volatile-cached gateway fallback"
        )
    if not is_volatile_store(config.get("match-index"), "andee-volatile-match-index"):
        fail("base config must use volatile Android match index")
    if not is_volatile_arweave_index_store(config.get("arweave-index-store")):
        fail("base config must use remote-indexed volatile Android Arweave storage")
    if not is_private_store(config.get("priv-store")):
        fail("base config must use app-private persistent storage")
    store_text = BOOT_CONFIG_STORE.read_text()
    if '"measurement-body-source"' not in store_text:
        fail("operator config must reserve top-level measurement-body-source")
    operator_loop = 'hookList(operator.optJSONObject("on")?.opt("start"))'
    base_loop = 'hookList(base.optJSONObject("on")?.opt("start"))'
    if not (operator_loop in store_text and base_loop in store_text):
        fail("boot config store must merge operator and base on.start hooks")
    if store_text.index(operator_loop) > store_text.index(base_loop):
        fail("operator on.start hooks must run before base hooks")
    if "copyValue(hook)" not in store_text:
        fail("operator on.start hooks must be copied before merge")
    for key in ("store", "match-index", "arweave-index-store", "priv-store"):
        if f'copyBaseValue(base, merged, "{key}")' not in store_text:
            fail(f"boot config store must preserve base {key} after operator merge")
    for key in (
        "access-remote-cache-for-client",
        "arweave-index-store",
        "cache-control",
        "forge-bootstrap",
        "http-extra-opts",
        "load-remote-devices",
        "loaded-device-store",
        "match-index",
        "measurement-body-source",
        "preloaded-devices-index",
        "preloaded-store",
        "priv-store",
        "store",
        "store-defaults",
    ):
        if f'"{key}"' not in store_text:
            fail(f"operator config must reserve top-level {key}")
    for key in ("priv-key-location", "priv-wallet", "private-key"):
        if f'"{key}"' in store_text:
            fail(f"operator config must preserve normal private option {key}")
    for source in (INFERENCE_MODELS, ANDOCK_MATERIALIZER):
        source_text = source.read_text()
        for token in (
            "HttpURLConnection",
            "java.net.URL",
            'setRequestProperty("Range"',
        ):
            if token in source_text:
                fail(f"{source.name} must not implement artifact downloading ({token})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
