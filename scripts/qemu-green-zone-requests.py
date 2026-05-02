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
    publisher = att["body"]["node"]["address"]
    (out / "requests/init.json").write_text(json.dumps({
        "trusted-publishers": [publisher],
        "template": {
            "system": {"kernel": {"cmdline": cmdline}},
            "tpm": {"ek-cert-source": {"kind": "tpm-nv"}},
        }
    }))

    ca_bundle = (
        (out / "ca/issuercert.pem").read_text()
        + (out / "ca/swtpm-localca-rootca-cert.pem").read_text()
    ).encode()
    trusted_ca = base64.urlsafe_b64encode(ca_bundle).decode().rstrip("=")

    for n in (2, 3, 4):
        (out / f"requests/join{n}.json").write_text(json.dumps({
            "peer-url": f"http://{guest_host}:{base_port + 1}",
            "self-url": f"http://{guest_host}:{base_port + n}",
            "trusted-ca": trusted_ca,
        }))
        (out / f"requests/admit{n}.json").write_text(json.dumps({
            "joiner-url": f"http://{guest_host}:{base_port + n}",
            "trusted-ca": trusted_ca,
        }))

    (out / "requests/verify2.json").write_text(json.dumps({
        "url": f"http://{guest_host}:{base_port + 2}",
        "trusted-ca": trusted_ca,
    }))

    for n in (1, 2, 3, 4):
        (out / f"requests/sign{n}.json").write_text(json.dumps({
            "body": {
                "type": "green-zone-acceptance-signature",
                "node": n,
                "message": "LapEE green-zone acceptance",
            }
        }))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
