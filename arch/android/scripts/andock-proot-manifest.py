#!/usr/bin/env python3

import hashlib
import json
import pathlib
import sys


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs(root):
    paths = [
        root / "scripts/build-andock-proot-image.sh",
        root / "scripts/andock-lwext4-source.sh",
        root / "scripts/andock-proot-manifest.py",
        root / "execution/termux-proot-prefix.patch",
        root / "execution/termux-proot-launcher.patch",
        root / "execution/termux-tar-wrapper",
        root / "execution/andock-proot-image.patch",
        root / "execution/lwext4-open-inode.patch",
        root / "execution/lwext4-inode-times.patch",
        root / "execution/lwext4-atomic-replace.patch",
        root / "execution/lwext4-nondirectory-replace.patch",
        root / "execution/lwext4-sparse-read.patch",
        root / "execution/lwext4/include/generated/ext4_config.h",
        root / "execution/lwext4/patches/xattr-list-size.patch",
        root / "runtime-src/andock_proot_launcher.c",
    ]
    paths.extend(sorted(
        path for path in
        (root / "execution/proot-overlay/src/extension/andock_image").glob("*")
        if path.is_file()
    ))
    return {
        str(path.relative_to(root)): digest(path)
        for path in paths
    }


def manifest(out, root, termux_revision, builder_image, lwext4_revision):
    selected = [
        out / "usr/bin/proot",
        out / "usr/libexec/andock/proot-launcher",
        out / "usr/libexec/proot/loader",
    ]
    return {
        "architecture": "arm64",
        "proot-version": "5.1.107.84",
        "proot-source-sha256":
            "a44ddbf18bc72c9780d56948b03aeda6d285392503ece0cae17cfc02e7bc7928",
        "termux-packages-revision": termux_revision,
        "termux-builder-image": builder_image,
        "lwext4-revision": lwext4_revision,
        "toolchain-revision": f"termux-{termux_revision}+andock-image-3",
        "android-package-prefix": "/data/data/org.permaweb.andee/files/usr",
        "files": {
            str(path.relative_to(out)): digest(path)
            for path in selected
        },
        "inputs": inputs(root),
    }


def main():
    if len(sys.argv) != 7 or sys.argv[1] not in {"validate", "write"}:
        raise SystemExit(
            "usage: andock-proot-manifest.py validate|write "
            "OUT ROOT TERMUX_REVISION BUILDER_IMAGE LWEXT4_REVISION"
        )
    action = sys.argv[1]
    out = pathlib.Path(sys.argv[2])
    manifest_path = out / "manifest.json"
    if action == "validate":
        try:
            current = json.loads(manifest_path.read_text())
            expected = manifest(
                out, pathlib.Path(sys.argv[3]), *sys.argv[4:]
            )
        except (json.JSONDecodeError, OSError):
            raise SystemExit(1)
        raise SystemExit(0 if current == expected else 1)
    expected = manifest(out, pathlib.Path(sys.argv[3]), *sys.argv[4:])
    manifest_path.write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
