#!/usr/bin/env python3
"""Generate JSON requests for the QEMU zone cluster harness."""

import copy
import json
import os
import pathlib
import sys


def main() -> int:
    out = pathlib.Path(sys.argv[1])
    base_port = int(sys.argv[2])
    guest_host = sys.argv[3]

    att = json.loads((out / "responses/node1-boot-attestation.json").read_text())
    measurement = measurement_message(att)
    body = measurement["body"]
    evidence = measurement["evidence"]
    cmdline = body["system"]["kernel"]["cmdline"]
    node = body["node"]
    signals = evidence.get("signals", {})
    secure_boot = signals.get("secure-boot", {})
    secure_boot_policy = signals.get("secure-boot-policy", {})
    publisher = signals.get("publisher", {})
    loaded_image = signals.get("loaded-image", {})
    snp_report = evidence.get("report", {})
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

    template_mode = os.environ.get("ZONE_TEMPLATE_MODE", "device")
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
        signer_digest = secure_boot_policy.get("image-signers-digest")
        signer_count = secure_boot_policy.get("image-signer-count", 0)
        publisher_digest = publisher.get("signers-digest")
        publisher_count = publisher.get("signer-count", 0)
        snp_measurement = snp_report.get("measurement")
        secure_boot_enabled = secure_boot.get("enabled") in (True, "true")
        if signer_digest and signer_count > 0 and secure_boot_enabled:
            evidence_template = {
                "signals": {
                    "secure-boot": {"enabled": True},
                    "secure-boot-policy": {
                        "image-signers-digest": signer_digest
                    },
                }
            }
        elif signer_digest:
            raise SystemExit(
                "release template requires Secure Boot enabled "
                "when matching measured signer policy")
        elif publisher_digest and publisher_count > 0:
            evidence_template = {
                "signals": {
                    "publisher": {
                        "signers-digest": publisher_digest
                    },
                },
            }
        elif snp_measurement:
            evidence_template = {"report": {"measurement": snp_measurement}}
        else:
            raise SystemExit(
                "release template requires measured Secure Boot policy "
                "or publisher/SNP measurement evidence")
        template = {
            "evidence": evidence_template,
            "body": {
                "system": {
                    "kernel": {"cmdline": cmdline},
                },
                "node": {
                    "initialized": node["initialized"],
                    "access-remote-cache-for-client":
                        node["access-remote-cache-for-client"],
                    "trusted-device-signers": node["trusted-device-signers"],
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

    init_template_key = "templates" if os.environ.get("ZONE_TEMPLATE_LIST") else "template"
    init_template_value = template
    if init_template_key == "templates":
        init_template_value = [
            {"body": {"system": {"firmware": {"dmi": {
                "fields": {"product-name": "definitely-not-this-node"}
            }}}}},
            template,
        ]

    (out / "requests/init.json").write_text(json.dumps({
        "name": "book-shelf",
        init_template_key: init_template_value,
    }))
    if template_mode in ("release", "release-common"):
        wrong_template = copy.deepcopy(init_template_value)
        tamper_boot_evidence(wrong_template)
        (out / "requests/init-wrong-boot-evidence.json").write_text(json.dumps({
            "name": "book-shelf",
            init_template_key: wrong_template,
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

    # Node 3 joins via node 2 -- not via node 1 -- so the harness
    # exercises the multi-hop members propagation path that the
    # `add_member_to_members` bug used to silently break (the
    # admission's `zone.members` would have lost the new
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
        (out / f"requests/join{n}.json").write_text(json.dumps(join))
        (out / f"requests/admit{n}.json").write_text(json.dumps(admit))

    verify = {
        "url": f"http://{guest_host}:{base_port + 2}",
    }
    (out / "requests/verify2.json").write_text(json.dumps(verify))

    return 0


def measurement_message(att: dict) -> dict:
    body = att.get("body")
    if isinstance(body, dict) and body.get("type") == "lapee-measurement":
        return body
    if att.get("type") == "lapee-measurement":
        return att
    raise SystemExit("boot attestation did not contain a measurement message")


def tamper_boot_evidence(template):
    if isinstance(template, list):
        for item in template:
            tamper_boot_evidence(item)
        return
    if not isinstance(template, dict):
        return
    evidence = template.get("evidence", {})
    policy = evidence.get("signals", {}).get("secure-boot-policy", {})
    if "image-signers-digest" in policy:
        policy["image-signers-digest"] = (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        return
    publisher = evidence.get("signals", {}).get("publisher", {})
    if "signers-digest" in publisher:
        publisher["signers-digest"] = (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        return
    loaded_image = evidence.get("signals", {}).get("loaded-image", {})
    if "components-digest" in loaded_image:
        loaded_image["components-digest"] = (
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        return
    report = evidence.get("report", {})
    if "measurement" in report:
        report["measurement"] = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"


if __name__ == "__main__":
    raise SystemExit(main())
