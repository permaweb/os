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
DEFAULT_TEMPLATE = ROOT / "sample-configs" / "andee-ouroboros-smoke.json"
DEFAULT_OUTPUT = (
    ROOT / "arch" / "android" / "build" / "deployment" /
    "andee-ouroboros-smoke.json"
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Create an ignored AndEE operator config with provider keys."
    )
    parser.add_argument("--secrets", type=pathlib.Path, required=True)
    parser.add_argument("--template", type=pathlib.Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--location-url")
    return parser.parse_args()


def read_object(path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise SystemExit(f"expected one JSON object: {path}")
    return value


def provider_key(source, provider):
    candidates = (
        source.get("inference-providers", {}).get(provider, {})
            .get("priv", {}).get("api-key"),
        source.get("priv-ouroboros-keys", {}).get(provider, {})
            .get("api-key"),
        source.get(provider, {}).get("api-key"),
    )
    for value in candidates:
        if isinstance(value, str) and value.strip() and value != "****":
            return value
    return None


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
    source = read_object(args.secrets.expanduser().resolve())
    output = args.output.expanduser().resolve()
    require_ignored(output)

    providers = template.get("inference-providers")
    if not isinstance(providers, dict):
        raise SystemExit("template is missing inference-providers")

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
        template["location-url"] = args.location_url.rstrip("/")
        template["node-host"] = location.hostname

    configured = []
    for provider in sorted(tuple(providers)):
        if isinstance(providers[provider].get("inference-device"), str):
            continue
        key = provider_key(source, provider)
        if key is None:
            del providers[provider]
            continue
        private = providers[provider].setdefault("priv", {})
        private["api-key"] = key
        configured.append(provider)

    hue_key = source.get("priv-hue-key")
    if isinstance(hue_key, str) and hue_key.strip() and hue_key != "****":
        template["priv-hue-key"] = hue_key
    else:
        template.pop("priv-hue-key", None)
        template.pop("priv-hue-address", None)

    priority = template.get("inference-provider-priority", [])
    template["inference-provider-priority"] = [
        provider for provider in priority
        if provider == "local-andee" or provider in providers
    ]
    if contains_placeholder(template):
        raise SystemExit("deployment config still contains redaction placeholders")
    if not configured:
        raise SystemExit("no remote inference provider keys found")

    write_private(output, template)
    print(f"deployment config: {output}")
    print(f"remote providers: {', '.join(configured)}")


if __name__ == "__main__":
    main()
