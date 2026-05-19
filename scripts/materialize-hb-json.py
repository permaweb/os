#!/usr/bin/env python3
"""Inline linked AO-Core JSON fields by following `+link` IDs."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import urllib.parse
import urllib.request
import urllib.error

INLINE_LINKS = {
    "admission",
    "authorization",
    "body",
    "boot",
    "boot-verification",
    "checks",
    "consumer-scope",
    "cpu",
    "credential-activation",
    "credential",
    "current-boot",
    "dmi",
    "edac",
    "ek-cert-source",
    "encrypted-wallet",
    "evidence",
    "fields",
    "firmware",
    "freshness",
    "fresh-verification",
    "green-zone",
    "integrity",
    "iommu",
    "kernel",
    "loaded-uki",
    "measurements",
    "meminfo",
    "memory",
    "memtotal",
    "members",
    "membership",
    "migration",
    "node",
    "nonvolatile-storage",
    "peer-attestation",
    "peer-boot-attestation",
    "peer-credential-subject",
    "peer-fresh-attestation",
    "peer-scope",
    "peer-secret-subject",
    "pcr-selection",
    "pcr-values",
    "quote",
    "reason",
    "ring-reference",
    "runtime-event-log",
    "secret-recipient",
    "security",
    "signals",
    "system",
    "template",
    "tpm",
    "tpm-properties",
    "trusted-device-signers",
    "validity",
    "verification",
    "zone",
}


def payload(msg):
    if isinstance(msg, dict) and isinstance(msg.get("status"), int):
        if msg["status"] < 400 and "body" in msg:
            return msg["body"]
    return msg


def link_url(base: str, ident: str) -> str:
    return (
        base.rstrip("/")
        + "/"
        + urllib.parse.quote(ident, safe="")
        + "/serialize~json@1.0?accept=application/json"
    )


def fetch(base: str, ident: str):
    with urllib.request.urlopen(link_url(base, ident), timeout=8) as res:
        return json.load(res)


def restore_json_list(value):
    if isinstance(value, list):
        return [restore_json_list(item) for item in value]
    if not isinstance(value, dict):
        return value

    restored = {
        key: item if key == "commitments" else restore_json_list(item)
        for key, item in value.items()
    }
    if restored.get("device") != "json@1.0":
        return restored
    data_keys = [
        key for key in restored
        if key not in ("ao-types", "commitments", "device")
    ]
    if not data_keys:
        return restored
    try:
        indices = sorted(int(key) for key in data_keys)
    except ValueError:
        return restored
    if indices != list(range(1, len(indices) + 1)):
        return restored
    return [restored[str(index)] for index in indices]


def materialize(value, base: str, depth: int):
    if depth <= 0:
        return restore_json_list(value)
    if isinstance(value, list):
        return [materialize(item, base, depth - 1) for item in value]
    if not isinstance(value, dict):
        return value

    out = dict(value)
    for key, ident in list(value.items()):
        if not key.endswith("+link") or not isinstance(ident, str):
            continue
        target = key[:-5]
        if should_inline(target) and target not in out:
            try:
                out[target] = materialize(
                    payload(fetch(base, ident)),
                    base,
                    depth - 1,
                )
            except Exception as exc:
                if isinstance(exc, urllib.error.HTTPError):
                    detail = f"{exc.code} {exc.reason}"
                else:
                    detail = str(exc)
                print(f"warning: could not materialize {key}={ident}: {detail}", file=sys.stderr)
                continue
            out.pop(key, None)

    return restore_json_list({
        key: item if key == "commitments" else materialize(item, base, depth - 1)
        for key, item in out.items()
    })


def should_inline(target: str) -> bool:
    return target in INLINE_LINKS or target.isdecimal()


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: materialize-hb-json.py BASE_URL FILE", file=sys.stderr)
        return 2
    base, path = sys.argv[1:3]
    with open(path, "rb") as f:
        msg = json.load(f)
    rendered = materialize(msg, base, 6)
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".materialize.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(rendered, f, separators=(",", ":"))
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        finally:
            raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
