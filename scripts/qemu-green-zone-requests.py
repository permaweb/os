#!/usr/bin/env python3
"""Generate JSON requests for the QEMU green-zone cluster harness."""

import base64
import json
import os
import pathlib
import sys


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    base_port = int(sys.argv[2])
    guest_host = sys.argv[3]

    att = json.loads((out / "responses/node1-boot-attestation.json").read_text())
    measurement = att["body"]
    body = measurement["body"]
    evidence = measurement["evidence"]
    cmdline = body["system"]["kernel"]["cmdline"]
    node = body["node"]
    loaded_uki = body.get("system", {}).get("boot", {}).get("loaded-uki", {})
    dmi_product = (
        body["system"]["firmware"]["dmi"]["fields"]["product-name"]
    )
    if "ek-cert-source" in evidence:
        evidence_template = {
            "ek-cert-source": {"kind": evidence["ek-cert-source"]["kind"]}
        }
    elif "type" in evidence:
        evidence_template = {"type": evidence["type"]}
    else:
        evidence_template = {}

    template_mode = os.environ.get("GREEN_ZONE_TEMPLATE_MODE", "device")
    template = {
        "body": {
            "system": {
                "kernel": {"cmdline": cmdline},
                "firmware": {
                    "dmi": {"fields": {"product-name": dmi_product}},
                },
            },
        },
    }

    if template_mode in ("release", "release-common"):
        loaded_uki_sha256 = loaded_uki.get("sha256")
        if not loaded_uki_sha256:
            raise SystemExit("release template requires body.boot.loaded-uki.sha256")
        template = {
            "body": {
                "system": {
                    "boot": {
                        "loaded-uki": {"sha256": loaded_uki_sha256},
                    },
                    "kernel": {"cmdline": cmdline},
                },
                "node": {
                    "ao-types":
                        "access-remote-cache-for-client=\"atom\", "
                        "initialized=\"atom\", "
                        "load-remote-devices=\"atom\"",
                    "initialized": node["initialized"],
                    "access-remote-cache-for-client":
                        node["access-remote-cache-for-client"],
                    "load-remote-devices": node["load-remote-devices"],
                },
            },
        }
        if template_mode == "release":
            template["body"]["system"]["firmware"] = {
                "dmi": {"fields": {"product-name": dmi_product}},
            }
    elif template_mode == "device":
        template.update({
            "measurement-device": measurement["measurement-device"],
            "evidence": evidence_template,
        })

    (out / "requests/init.json").write_text(json.dumps({
        "name": "book-shelf",
        "template": template,
    }))
    (out / "requests/init-device-specific.json").write_text(json.dumps({
        "name": "book-shelf",
        "template": {
            "measurement-device": measurement["measurement-device"],
            "body": {
                "system": {
                    "kernel": {"cmdline": cmdline},
                    "firmware": {
                        "dmi": {"fields": {"product-name": dmi_product}},
                    },
                },
            },
            "evidence": evidence_template,
        }
    }))

    ca_files = [out / "ca/issuercert.pem", out / "ca/swtpm-localca-rootca-cert.pem"]
    if all(path.exists() for path in ca_files):
        ca_bundle = "".join(path.read_text() for path in ca_files).encode()
        trusted_ca = base64.urlsafe_b64encode(ca_bundle).decode().rstrip("=")
    else:
        trusted_ca = None

    # Node 3 joins via node 2 -- not via node 1 -- so the harness
    # exercises the multi-hop members propagation path that the
    # `add_member_to_members` bug used to silently break (the
    # admission's `green-zone.members` would have lost the new
    # joiner's wallet through stale-commitment cache linkification).
    join_via = {2: 1, 3: 2, 4: 1}
    for n in (2, 3, 4):
        join = {
            "name": "book-shelf",
            "peer-url": f"http://{guest_host}:{base_port + join_via[n]}",
            "self-url": f"http://{guest_host}:{base_port + n}",
        }
        admit = {
            "name": "book-shelf",
            "joiner-url": f"http://{guest_host}:{base_port + n}",
        }
        if trusted_ca:
            join["trusted-ca"] = trusted_ca
            admit["trusted-ca"] = trusted_ca
        (out / f"requests/join{n}.json").write_text(json.dumps(join))
        (out / f"requests/admit{n}.json").write_text(json.dumps(admit))

    verify = {
        "url": f"http://{guest_host}:{base_port + 2}",
    }
    if trusted_ca:
        verify["trusted-ca"] = trusted_ca
    (out / "requests/verify2.json").write_text(json.dumps(verify))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
