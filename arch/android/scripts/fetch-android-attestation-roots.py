#!/usr/bin/env python3
"""Fetch Google's current Android Key Attestation roots."""

from __future__ import annotations

import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "secondary-external-verifier" / "android-attestation-roots.pem"
ANDROID_OUT = ROOT / "android" / "app" / "src" / "main" / "assets" / "android-attestation-roots.pem"
URL = "https://android.googleapis.com/attestation/root"


def main() -> int:
    with urllib.request.urlopen(URL, timeout=30) as response:
        roots = json.loads(response.read().decode())
    if not isinstance(roots, list) or not roots:
        raise SystemExit("unexpected Android attestation root response")
    pem = "\n".join(root.strip() for root in roots) + "\n"
    for out in (OUT, ANDROID_OUT):
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(pem)
    print(f"wrote {len(roots)} Android attestation roots to {OUT} and {ANDROID_OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
