#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED = {
    "architecture": "arm64",
    "image-logical-bytes": 32 * 1024 * 1024 * 1024,
    "image-sha256":
        "29a8d9f031e76a0c42cf5b6013e92309925368378d5e944019f1a2985464228b",
    "image-uuid": "4b7e4af2-25cd-4ae5-a14d-8f8628b88f5d",
    "metadata-inventory-sha256":
        "4bb273ba4f81618fd8bcf99819770d633e11bddd43df704bea6a015b43cb5049",
    "node-sha256":
        "0294e8b915ab75f92c7513d2fcb830ae06e10684e6c603e99a87dbf8835389c1",
    "node-version": "22.23.1",
    "permagit-sha256":
        "6cc1763c3af3072e102ef0d09aaba29fe8c6dd996329d1050c0491dec73d7854",
    "permagit-version": "0.11.3",
    "provision-revision": "andock-ubuntu-ext4-1",
    "source-date-epoch": 1735689600,
    "sparse-image-format": "android-sparse-v1",
    "sparse-image-sha256":
        "063d3500242a9ab384ad2030c53bf254d0563862cabafd4a05815119a8276e94",
    "ubuntu-builder-image":
        "ubuntu@sha256:c4a8d5503dfb2a3eb8ab5f807da5bc69a85730fb49b5cfca2330194ebcc41c7b",
    "ubuntu-snapshot": "20260714T000000Z",
}
INPUTS = {
    "package-lock-sha256": ROOT / "execution/andock-ubuntu-packages.lock",
    "provisioner-sha256": ROOT / "execution/andock-provision-base.sh",
    "template-builder-sha256": ROOT / "scripts/andock-build-template-inner.sh",
    "inventory-script-sha256": ROOT / "scripts/andock-metadata-inventory.py",
    "xattr-replayer-sha256": ROOT / "scripts/andock-replay-xattrs.py",
    "sparse-converter-sha256": ROOT / "scripts/andock-android-sparse.py",
}


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            value.update(chunk)
    return value.hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-andock-template.py TEMPLATE_DIR")
    directory = pathlib.Path(sys.argv[1])
    image = directory / "andock-ubuntu-arm64.ext4.simg"
    manifest_path = directory / "andock-ubuntu-arm64.ext4.manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as failure:
        raise SystemExit(f"invalid Andock template manifest: {failure}")
    for key, value in EXPECTED.items():
        if manifest.get(key) != value:
            raise SystemExit(f"unexpected Andock template {key}")
    for key, path in INPUTS.items():
        if manifest.get(key) != digest(path):
            raise SystemExit(f"stale Andock template input: {path}")
    if not image.is_file() or image.stat().st_size != manifest.get("sparse-image-bytes"):
        raise SystemExit("missing or incorrectly sized Andock sparse image")
    if digest(image) != manifest.get("sparse-image-sha256"):
        raise SystemExit("Andock sparse image digest mismatch")


if __name__ == "__main__":
    main()
