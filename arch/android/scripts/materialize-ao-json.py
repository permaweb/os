#!/usr/bin/env python3
"""Materialize HyperBEAM JSON `+link` fields through an HTTP node."""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from typing import Any


def fetch_json(base_url: str, message_id: str) -> Any:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", message_id)
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode())


def materialize(value: Any, base_url: str, stack: set[str], cache: dict[str, Any]) -> Any:
    if isinstance(value, list):
        return [materialize(item, base_url, stack, cache) for item in value]
    if not isinstance(value, dict):
        return value

    out: dict[str, Any] = {}
    for key, item in value.items():
        if key.endswith("+link") and isinstance(item, str):
            target_key = key[:-5]
            if item in cache:
                out[target_key] = cache[item]
            elif item in stack:
                out[target_key] = {"link": item, "cycle": True}
            else:
                stack.add(item)
                out[target_key] = materialize(fetch_json(base_url, item), base_url, stack, cache)
                cache[item] = out[target_key]
                stack.remove(item)
            continue
        out[key] = materialize(item, base_url, stack, cache)
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=argparse.FileType("r"))
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--output", type=argparse.FileType("w"), default=sys.stdout)
    args = parser.parse_args()

    payload = json.load(args.input)
    json.dump(materialize(payload, args.base_url, set(), {}), args.output, indent=2)
    args.output.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
