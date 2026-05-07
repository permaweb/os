#!/usr/bin/env python3
"""Generate JSON requests for the QEMU green-zone cluster harness."""

import base64
import json
import pathlib
import sys


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    base_port = int(sys.argv[2])
    guest_host = sys.argv[3]

    att = json.loads((out / "responses/node1-boot-attestation.json").read_text())
    cmdline = att["body"]["system"]["kernel"]["cmdline"]
    dmi_product = (
        att["body"]["system"]["firmware"]["dmi"]["fields"]["product-name"]
    )
    (out / "requests/init.json").write_text(json.dumps({
        "name": "book-shelf",
        "template": {
            "system": {
                "kernel": {"cmdline": cmdline},
                "firmware": {
                    "dmi": {"fields": {"product-name": dmi_product}},
                },
            },
            "tpm": {"ek-cert-source": {"kind": "tpm-nv"}},
        }
    }))

    ca_bundle = (
        (out / "ca/issuercert.pem").read_text()
        + (out / "ca/swtpm-localca-rootca-cert.pem").read_text()
    ).encode()
    trusted_ca = base64.urlsafe_b64encode(ca_bundle).decode().rstrip("=")

    # Node 3 joins via node 2 -- not via node 1 -- so the harness
    # exercises the multi-hop members propagation path that the
    # `add_member_to_members` bug used to silently break (the
    # admission's `green-zone.members` would have lost the new
    # joiner's wallet through stale-commitment cache linkification).
    join_via = {2: 1, 3: 2, 4: 1}
    for n in (2, 3, 4):
        (out / f"requests/join{n}.json").write_text(json.dumps({
            "name": "book-shelf",
            "peer-url": f"http://{guest_host}:{base_port + join_via[n]}",
            "self-url": f"http://{guest_host}:{base_port + n}",
            "trusted-ca": trusted_ca,
        }))
        (out / f"requests/admit{n}.json").write_text(json.dumps({
            "name": "book-shelf",
            "joiner-url": f"http://{guest_host}:{base_port + n}",
            "trusted-ca": trusted_ca,
        }))

    (out / "requests/verify2.json").write_text(json.dumps({
        "url": f"http://{guest_host}:{base_port + 2}",
        "trusted-ca": trusted_ca,
    }))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
