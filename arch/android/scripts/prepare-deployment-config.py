#!/usr/bin/env python3

import argparse
import json
import os
import pathlib
import subprocess
import tempfile
import urllib.parse


SCRIPT = pathlib.Path(__file__).resolve()
ROOT = SCRIPT.parents[3]


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Create an ignored AndEE operator config by applying a private "
            "JSON Merge Patch to a public template."
        )
    )
    parser.add_argument("--private-overlay", type=pathlib.Path, required=True)
    parser.add_argument("--template", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--location-url")
    return parser.parse_args()


def read_object(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise SystemExit(f"expected one JSON object: {path}")
    return value


def merge_patch(target, patch):
    """Apply RFC 7396 JSON Merge Patch semantics."""
    if not isinstance(patch, dict):
        return patch
    if not isinstance(target, dict):
        target = {}
    result = dict(target)
    for key, value in patch.items():
        if value is None:
            result.pop(key, None)
        else:
            result[key] = merge_patch(result.get(key), value)
    return result


def contains_placeholder(value):
    if isinstance(value, dict):
        return any(contains_placeholder(child) for child in value.values())
    if isinstance(value, list):
        return any(contains_placeholder(child) for child in value)
    return isinstance(value, str) and (
        "****" in value or "**[base32 encoded node address]**" in value
    )


def require_ignored(path):
    result = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "--quiet", str(path)],
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(f"refusing to write credentials to a tracked path: {path}")


def write_private(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    args = parse_args()
    template = read_object(args.template.resolve())
    private_overlay = read_object(args.private_overlay.expanduser().resolve())
    output = args.output.expanduser().resolve()
    require_ignored(output)
    config = merge_patch(template, private_overlay)

    if args.location_url:
        location = urllib.parse.urlparse(args.location_url)
        if (
            location.scheme != "https"
            or not location.hostname
            or location.username
            or location.password
            or location.query
            or location.fragment
        ):
            raise SystemExit("invalid HTTPS location URL")
        config["location-url"] = args.location_url.rstrip("/")
        config["node-host"] = location.hostname

    if contains_placeholder(config):
        raise SystemExit("deployment config still contains redaction placeholders")

    write_private(output, config)
    print(f"deployment config: {output}")


if __name__ == "__main__":
    main()
