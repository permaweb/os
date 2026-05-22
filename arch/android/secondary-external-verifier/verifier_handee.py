#!/usr/bin/env python3
"""Independent verifier for materialized HandEE measurement evidence.

This verifier intentionally defaults to rejection. Emulator evidence can prove
that the flow was exercised, but accepted Tier A evidence requires Android
attestation certificates, package/signing policy, Keystore signature, nonce
freshness, and deployment policy inputs supplied by the caller.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import sys
from typing import Any

try:
    from cryptography import x509
    from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.x509.oid import ObjectIdentifier
except Exception:  # pragma: no cover - dependency availability is checked at runtime.
    x509 = None
    ec = None
    padding = None
    rsa = None
    SHA256 = None
    ObjectIdentifier = None


ANDROID_ATTESTATION_OID = "1.3.6.1.4.1.11129.2.1.17"
DEFAULT_ROOTS = pathlib.Path(__file__).with_name("android-attestation-roots.pem")
SECURITY_LEVELS = {
    0: "SOFTWARE",
    1: "TEE",
    2: "STRONGBOX",
}
VERIFIED_BOOT_STATES = {
    0: "VERIFIED",
    1: "SELF_SIGNED",
    2: "UNVERIFIED",
    3: "FAILED",
}
DER_UNIVERSAL = 0x00
DER_CONTEXT_SPECIFIC = 0x80
DER_SEQUENCE = 16
DER_SET = 17
DER_INTEGER = 2
DER_ENUMERATED = 10
DER_OCTET_STRING = 4
DER_BOOLEAN = 1
ROOT_OF_TRUST_TAG = 704
ATTESTATION_APPLICATION_ID_TAG = 709
OS_PATCH_LEVEL_TAG = 706
VENDOR_PATCH_LEVEL_TAG = 718
BOOT_PATCH_LEVEL_TAG = 719


def b64encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def b64decode(value: str) -> bytes:
    pad = "=" * ((4 - len(value) % 4) % 4)
    return base64.urlsafe_b64decode(value + pad)


def sha256_id(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(hashlib.sha256(encoded).digest()).decode().rstrip("=")


def normalize_digest(value: str) -> str:
    stripped = value.strip()
    if len(stripped) == 64:
        try:
            return b64encode(bytes.fromhex(stripped))
        except ValueError:
            pass
    return stripped.rstrip("=")


def indexed_values(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        numeric_keys = [key for key in value if str(key).isdigit()]
        if numeric_keys:
            return [value[key] for key in sorted(numeric_keys, key=lambda item: int(item))]
        return [
            value[key]
            for key in sorted(value, key=lambda item: int(item) if str(item).isdigit() else str(item))
        ]
    return []


def payload(msg: Any) -> Any:
    while (
        isinstance(msg, dict)
        and isinstance(msg.get("status"), int)
        and "body" in msg
        and "type" not in msg
    ):
        msg = msg["body"]
    return msg


def atom_true(value: Any) -> bool:
    return value is True or value == "true"


def check(name: str, ok: bool, detail: Any = None, severity: str = "core") -> dict[str, Any]:
    out = {"name": name, "ok": bool(ok), "severity": severity}
    if detail is not None:
        out["detail"] = detail
    return out


def read_tlv(data: bytes, offset: int = 0) -> tuple[int, bytes, int]:
    if offset >= len(data):
        raise ValueError("short DER")
    tag = data[offset]
    offset += 1
    if offset >= len(data):
        raise ValueError("short DER length")
    first = data[offset]
    offset += 1
    if first & 0x80:
        count = first & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("bad DER length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    else:
        length = first
    end = offset + length
    if end > len(data):
        raise ValueError("DER length escapes buffer")
    return tag, data[offset:end], end


def der_int(data: bytes) -> int:
    if not data:
        raise ValueError("empty integer")
    return int.from_bytes(data, "big", signed=data[0] & 0x80 != 0)


def read_der_value(data: bytes, offset: int = 0) -> dict[str, Any]:
    if offset >= len(data):
        raise ValueError("short DER")
    first = data[offset]
    offset += 1
    tag_class = first & 0xC0
    tag = first & 0x1F
    if tag == 0x1F:
        tag = 0
        while True:
            if offset >= len(data):
                raise ValueError("short high-tag DER")
            nxt = data[offset]
            offset += 1
            tag = (tag << 7) | (nxt & 0x7F)
            if not (nxt & 0x80):
                break
    if offset >= len(data):
        raise ValueError("short DER length")
    first_len = data[offset]
    offset += 1
    if first_len & 0x80:
        count = first_len & 0x7F
        if count == 0 or count > 4 or offset + count > len(data):
            raise ValueError("bad DER length")
        length = int.from_bytes(data[offset:offset + count], "big")
        offset += count
    else:
        length = first_len
    end = offset + length
    if end > len(data):
        raise ValueError("DER length escapes buffer")
    return {
        "tag_class": tag_class,
        "tag": tag,
        "value": data[offset:end],
        "end": end,
    }


def der_value_int(value: dict[str, Any], expected_tag: int) -> int:
    if value["tag_class"] != DER_UNIVERSAL or value["tag"] != expected_tag:
        raise ValueError("unexpected DER integer tag")
    return der_int(value["value"])


def parse_authorization_list(value: dict[str, Any]) -> dict[int, dict[str, Any]]:
    if value["tag_class"] != DER_UNIVERSAL or value["tag"] != DER_SEQUENCE:
        raise ValueError("authorization list is not a sequence")
    out: dict[int, dict[str, Any]] = {}
    offset = 0
    body = value["value"]
    while offset < len(body):
        explicit = read_der_value(body, offset)
        offset = explicit["end"]
        if explicit["tag_class"] == DER_CONTEXT_SPECIFIC:
            out[explicit["tag"]] = read_der_value(explicit["value"], 0)
    return out


def parse_root_of_trust(value: dict[str, Any]) -> dict[str, Any]:
    if value["tag_class"] != DER_UNIVERSAL or value["tag"] != DER_SEQUENCE:
        raise ValueError("root of trust is not a sequence")
    body = value["value"]
    offset = 0
    boot_key = read_der_value(body, offset)
    offset = boot_key["end"]
    locked = read_der_value(body, offset)
    offset = locked["end"]
    boot_state = read_der_value(body, offset)
    offset = boot_state["end"]
    if locked["tag_class"] != DER_UNIVERSAL or locked["tag"] != DER_BOOLEAN:
        raise ValueError("root deviceLocked is not boolean")
    state = der_value_int(boot_state, DER_ENUMERATED)
    out = {
        "verified-boot-key": b64encode(boot_key["value"]),
        "device-locked": any(byte != 0 for byte in locked["value"]),
        "verified-boot-state": VERIFIED_BOOT_STATES.get(state, state),
    }
    if offset < len(body):
        boot_hash = read_der_value(body, offset)
        if boot_hash["tag_class"] == DER_UNIVERSAL and boot_hash["tag"] == DER_OCTET_STRING:
            out["verified-boot-hash"] = b64encode(boot_hash["value"])
    return out


def parse_attestation_application_id(value: dict[str, Any]) -> dict[str, Any]:
    if value["tag_class"] != DER_UNIVERSAL or value["tag"] != DER_OCTET_STRING:
        raise ValueError("attestationApplicationId is not an OCTET_STRING")
    top = read_der_value(value["value"])
    if top["tag_class"] != DER_UNIVERSAL or top["tag"] != DER_SEQUENCE:
        raise ValueError("attestationApplicationId is not a SEQUENCE")
    reader_offset = 0
    body = top["value"]
    package_set = read_der_value(body, reader_offset)
    reader_offset = package_set["end"]
    digest_set = read_der_value(body, reader_offset)
    if package_set["tag_class"] != DER_UNIVERSAL or package_set["tag"] != DER_SET:
        raise ValueError("attestation package infos are not a SET")
    if digest_set["tag_class"] != DER_UNIVERSAL or digest_set["tag"] != DER_SET:
        raise ValueError("attestation signature digests are not a SET")

    packages = []
    offset = 0
    while offset < len(package_set["value"]):
        item = read_der_value(package_set["value"], offset)
        offset = item["end"]
        if item["tag_class"] != DER_UNIVERSAL or item["tag"] != DER_SEQUENCE:
            raise ValueError("attestation package info is not a SEQUENCE")
        item_offset = 0
        name = read_der_value(item["value"], item_offset)
        item_offset = name["end"]
        version = read_der_value(item["value"], item_offset)
        if name["tag_class"] != DER_UNIVERSAL or name["tag"] != DER_OCTET_STRING:
            raise ValueError("attestation package name is not an OCTET_STRING")
        packages.append({
            "package-name": name["value"].decode(),
            "version": der_value_int(version, DER_INTEGER),
        })

    signature_digests = []
    offset = 0
    while offset < len(digest_set["value"]):
        item = read_der_value(digest_set["value"], offset)
        offset = item["end"]
        if item["tag_class"] != DER_UNIVERSAL or item["tag"] != DER_OCTET_STRING:
            raise ValueError("attestation signature digest is not an OCTET_STRING")
        signature_digests.append(b64encode(item["value"]))

    return {
        "package-infos": packages,
        "signature-digests": signature_digests,
    }


def parse_attestation_extension(data: bytes) -> dict[str, Any]:
    top = read_der_value(data)
    if top["tag_class"] != DER_UNIVERSAL or top["tag"] != DER_SEQUENCE or top["end"] != len(data):
        raise ValueError("attestation extension is not a single SEQUENCE")
    offset = 0
    fields: list[dict[str, Any]] = []
    body = top["value"]
    while offset < len(body) and len(fields) < 8:
        value = read_der_value(body, offset)
        fields.append(value)
        offset = value["end"]
    if len(fields) < 8:
        raise ValueError("attestation extension missing required fields")
    attestation_security = der_value_int(fields[1], DER_ENUMERATED)
    keymint_security = der_value_int(fields[3], DER_ENUMERATED)
    if fields[4]["tag_class"] != DER_UNIVERSAL or fields[4]["tag"] != DER_OCTET_STRING:
        raise ValueError("attestation challenge is not an OCTET_STRING")
    hardware_auth = parse_authorization_list(fields[7])
    software_auth = parse_authorization_list(fields[6])
    root = parse_root_of_trust(hardware_auth[ROOT_OF_TRUST_TAG]) if ROOT_OF_TRUST_TAG in hardware_auth else {}
    app_id = (
        parse_attestation_application_id(software_auth[ATTESTATION_APPLICATION_ID_TAG])
        if ATTESTATION_APPLICATION_ID_TAG in software_auth
        else {}
    )
    os_patch = hardware_auth.get(OS_PATCH_LEVEL_TAG)
    vendor_patch = hardware_auth.get(VENDOR_PATCH_LEVEL_TAG)
    boot_patch = hardware_auth.get(BOOT_PATCH_LEVEL_TAG)
    return {
        "attestation-version": der_value_int(fields[0], DER_INTEGER),
        "attestation-security-level": SECURITY_LEVELS.get(attestation_security, attestation_security),
        "keymint-version": der_value_int(fields[2], DER_INTEGER),
        "keymint-security-level": SECURITY_LEVELS.get(keymint_security, keymint_security),
        "attestation-challenge-b64": base64.urlsafe_b64encode(fields[4]["value"]).decode().rstrip("="),
        "attestation-challenge-bytes": fields[4]["value"],
        "device-locked": root.get("device-locked"),
        "verified-boot-state": root.get("verified-boot-state"),
        "verified-boot-key": root.get("verified-boot-key"),
        "verified-boot-hash": root.get("verified-boot-hash"),
        "os-patch-level": der_value_int(os_patch, DER_INTEGER) if os_patch else None,
        "vendor-patch-level": der_value_int(vendor_patch, DER_INTEGER) if vendor_patch else None,
        "boot-patch-level": der_value_int(boot_patch, DER_INTEGER) if boot_patch else None,
        "attestation-application-id": app_id,
    }


def load_certs(cert_chain: Any) -> tuple[list[Any], Any]:
    if x509 is None:
        return [], "cryptography package unavailable"
    if isinstance(cert_chain, dict):
        cert_chain = [item for item in indexed_values(cert_chain) if isinstance(item, str)]
    if not isinstance(cert_chain, list):
        return [], "certificate chain is not a list or indexed object"
    certs = []
    try:
        for encoded in cert_chain:
            certs.append(x509.load_der_x509_certificate(b64decode(encoded)))
    except Exception as exc:
        return [], f"cannot parse certificate chain: {exc}"
    return certs, None


def verify_child_signature(child: Any, issuer: Any) -> bool:
    public_key = issuer.public_key()
    if ec is not None and isinstance(public_key, ec.EllipticCurvePublicKey):
        public_key.verify(
            child.signature,
            child.tbs_certificate_bytes,
            ec.ECDSA(child.signature_hash_algorithm),
        )
        return True
    if rsa is not None and isinstance(public_key, rsa.RSAPublicKey):
        public_key.verify(
            child.signature,
            child.tbs_certificate_bytes,
            padding.PKCS1v15(),
            child.signature_hash_algorithm,
        )
        return True
    raise ValueError("unsupported certificate signature key")


def verify_chain(certs: list[Any]) -> tuple[bool, str]:
    if not certs:
        return False, "empty chain"
    try:
        for child, issuer in zip(certs, certs[1:]):
            if child.issuer != issuer.subject:
                return False, "issuer/subject mismatch"
            verify_child_signature(child, issuer)
        if len(certs) == 1:
            verify_child_signature(certs[0], certs[0])
        return True, "chain signatures valid"
    except Exception as exc:
        return False, str(exc)


def pem_blocks(data: bytes) -> list[bytes]:
    begin = b"-----BEGIN CERTIFICATE-----"
    end = b"-----END CERTIFICATE-----"
    blocks = []
    offset = 0
    while True:
        start = data.find(begin, offset)
        if start < 0:
            break
        stop = data.find(end, start)
        if stop < 0:
            break
        stop += len(end)
        blocks.append(data[start:stop] + b"\n")
        offset = stop
    return blocks


def load_trusted_roots(paths: list[pathlib.Path]) -> list[bytes]:
    roots = []
    if x509 is None:
        return roots
    for path in paths:
        for block in pem_blocks(path.read_bytes()):
            cert = x509.load_pem_x509_certificate(block)
            roots.append(cert.fingerprint(SHA256()))
    return roots


def verify_keystore_signature(certs: list[Any], subject_id: str, encoded_signature: str) -> tuple[bool, str]:
    if not certs:
        return False, "missing attestation certificate"
    try:
        signature = b64decode(encoded_signature)
        public_key = certs[0].public_key()
        if ec is not None and isinstance(public_key, ec.EllipticCurvePublicKey):
            public_key.verify(signature, subject_id.encode(), ec.ECDSA(SHA256()))
            return True, "ECDSA signature valid"
        if rsa is not None and isinstance(public_key, rsa.RSAPublicKey):
            public_key.verify(signature, subject_id.encode(), padding.PKCS1v15(), SHA256())
            return True, "RSA signature valid"
        return False, "unsupported attested public key"
    except Exception as exc:
        return False, str(exc)


def verify_measurement(measurement: dict[str, Any], args: argparse.Namespace) -> dict[str, Any]:
    evidence = measurement.get("evidence") if isinstance(measurement.get("evidence"), dict) else {}
    subject = evidence.get("evidence-subject") if isinstance(evidence.get("evidence-subject"), dict) else {}
    policy = evidence.get("policy-snapshot") if isinstance(evidence.get("policy-snapshot"), dict) else {}

    checks: list[dict[str, Any]] = [
        check("measurement shape", measurement.get("type") == "lapee-measurement"),
        check("measurement-device is handee@1.0", measurement.get("measurement-device") == "handee@1.0"),
        check("evidence shape", evidence.get("type") == "handee-android-evidence"),
        check("evidence subject shape", subject.get("type") == "handee-evidence-subject"),
        check("subject device matches", subject.get("measurement-device") == "handee@1.0"),
    ]

    if args.nonce:
        try:
            expected_nonce = base64.urlsafe_b64encode(b64decode(args.nonce)).decode().rstrip("=")
        except Exception:
            expected_nonce = args.nonce
        checks.append(check("fresh nonce matches", subject.get("nonce") == expected_nonce))

    body = measurement.get("body") if isinstance(measurement.get("body"), dict) else {}
    recipient = measurement.get("secret-recipient") if isinstance(measurement.get("secret-recipient"), dict) else {}
    checks.append(check("body present", bool(body)))
    checks.append(check("secret-recipient present", bool(recipient)))

    subject_id = evidence.get("evidence-subject-id")
    recomputed_json_id = sha256_id(subject) if subject else None
    checks.append(check(
        "evidence-subject-id present",
        isinstance(subject_id, str) and len(subject_id) > 20,
        {"json_sha256_id": recomputed_json_id},
        "informational",
    ))

    cert_chain = evidence.get("android-attestation-cert-chain")
    checks.append(check(
        "android attestation certificate chain present",
        (isinstance(cert_chain, list) and bool(cert_chain)) or
        (isinstance(cert_chain, dict) and any(str(key).isdigit() for key in cert_chain)),
    ))
    checks.append(check(
        "keystore signature present",
        isinstance(evidence.get("keystore-signature"), str)
        and bool(evidence.get("keystore-signature")),
    ))
    checks.append(check(
        "policy accepted by Android agent",
        atom_true(policy.get("accepted")) or atom_true(evidence.get("accepted")),
        policy,
    ))

    certs, cert_error = load_certs(cert_chain)
    checks.append(check(
        "android attestation certificates parse",
        bool(certs) and cert_error is None,
        cert_error,
    ))
    chain_ok, chain_detail = verify_chain(certs)
    checks.append(check("android attestation chain signatures validate", chain_ok, chain_detail))

    trusted_roots = load_trusted_roots(args.trusted_root_pem)
    root_trusted = bool(certs) and bool(trusted_roots) and certs[-1].fingerprint(SHA256()) in trusted_roots
    checks.append(check(
        "android attestation root is trusted",
        root_trusted,
        {"trusted_roots_supplied": len(trusted_roots)},
    ))

    attestation_detail: dict[str, Any] = {}
    attestation_ok = False
    challenge_ok = False
    try:
        if certs:
            ext = certs[0].extensions.get_extension_for_oid(ObjectIdentifier(ANDROID_ATTESTATION_OID))
            raw = ext.value.value
            attestation_detail = parse_attestation_extension(raw)
            challenge_subject = evidence.get("attestation-challenge-subject")
            if isinstance(challenge_subject, str) and challenge_subject:
                expected = hashlib.sha256(challenge_subject.encode()).digest()
                challenge_ok = attestation_detail["attestation-challenge-bytes"] == expected
            attestation_detail = {
                key: value for key, value in attestation_detail.items()
                if key != "attestation-challenge-bytes"
            }
            attestation_ok = True
    except Exception as exc:
        attestation_detail = {"error": str(exc)}
    checks.append(check("android attestation extension parses", attestation_ok, attestation_detail))
    checks.append(check("attestation challenge binds enrollment subject", challenge_ok))
    checks.append(check(
        "key security level is hardware-backed",
        attestation_detail.get("keymint-security-level") in ("TEE", "STRONGBOX"),
        attestation_detail,
    ))
    checks.append(check("device bootloader is locked", attestation_detail.get("device-locked") is True))
    checks.append(check(
        "verified boot state is verified",
        attestation_detail.get("verified-boot-state") == "VERIFIED",
        attestation_detail.get("verified-boot-state"),
    ))
    app_id = attestation_detail.get("attestation-application-id")
    app_packages = indexed_values(app_id.get("package-infos")) if isinstance(app_id, dict) else []
    app_signature_digests = (
        {item for item in indexed_values(app_id.get("signature-digests")) if isinstance(item, str)}
        if isinstance(app_id, dict)
        else set()
    )
    checks.append(check(
        "attestation application id includes package",
        bool(args.expected_package) and any(
            item.get("package-name") == args.expected_package
            for item in app_packages
            if isinstance(item, dict)
        ),
        app_id,
    ))
    expected_digests = {normalize_digest(item) for item in args.expected_signing_cert_digest}
    policy_digests = {
        item for item in indexed_values(policy.get("signing-certificate-digests"))
        if isinstance(item, str)
    }
    checks.append(check(
        "expected signing certificate digest supplied",
        bool(expected_digests),
        {"expected-signing-cert-digest": sorted(expected_digests)},
    ))
    checks.append(check(
        "attestation application id signing digest matches expected policy",
        bool(expected_digests) and bool(app_signature_digests.intersection(expected_digests)),
        {
            "attested": sorted(app_signature_digests),
            "expected": sorted(expected_digests),
        },
    ))
    checks.append(check(
        "policy signing digest matches attestation application id",
        bool(policy_digests) and bool(app_signature_digests.intersection(policy_digests)),
        {
            "policy": sorted(policy_digests),
            "attested": sorted(app_signature_digests),
        },
        "informational",
    ))
    if args.expected_verified_boot_key:
        checks.append(check(
            "verified boot key matches expected OS signer",
            attestation_detail.get("verified-boot-key") == normalize_digest(args.expected_verified_boot_key),
            attestation_detail.get("verified-boot-key"),
        ))
    if args.expected_verified_boot_hash:
        checks.append(check(
            "verified boot hash matches expected OS image",
            attestation_detail.get("verified-boot-hash") == normalize_digest(args.expected_verified_boot_hash),
            attestation_detail.get("verified-boot-hash"),
        ))
    checks.append(check(
        "OS patch floor satisfied",
        isinstance(attestation_detail.get("os-patch-level"), int)
        and attestation_detail["os-patch-level"] >= args.min_os_patch_level,
        {"min": args.min_os_patch_level, "actual": attestation_detail.get("os-patch-level")},
    ))
    checks.append(check(
        "vendor patch floor satisfied",
        isinstance(attestation_detail.get("vendor-patch-level"), int)
        and attestation_detail["vendor-patch-level"] >= args.min_vendor_patch_level,
        {"min": args.min_vendor_patch_level, "actual": attestation_detail.get("vendor-patch-level")},
    ))
    checks.append(check(
        "boot patch floor satisfied",
        isinstance(attestation_detail.get("boot-patch-level"), int)
        and attestation_detail["boot-patch-level"] >= args.min_boot_patch_level,
        {"min": args.min_boot_patch_level, "actual": attestation_detail.get("boot-patch-level")},
    ))

    signature_ok, signature_detail = verify_keystore_signature(
        certs,
        subject_id if isinstance(subject_id, str) else "",
        evidence.get("keystore-signature", ""),
    )
    checks.append(check("keystore signature verifies evidence subject id", signature_ok, signature_detail))

    if args.expected_package:
        package = policy.get("package-name") or body.get("system", {}).get("app", {}).get("package-name")
        checks.append(check("policy package identity matches expected", package == args.expected_package))
    if args.require_strongbox:
        attestation_strongbox = attestation_detail.get("keymint-security-level") == "STRONGBOX"
        checks.append(check(
            "key security level is StrongBox",
            evidence.get("key-security-level") == "STRONGBOX" and attestation_strongbox,
            attestation_detail,
        ))

    verified = all(c["ok"] or c["severity"] == "informational" for c in checks)
    if evidence.get("verdict") == "policy-failure":
        verified = False
    return {
        "verified": verified,
        "verdict": "accepted" if verified else "rejected",
        "checks": checks,
        "normalized_measurement": measurement,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("measurement", type=pathlib.Path)
    parser.add_argument("--out", type=pathlib.Path, default=None)
    parser.add_argument("--nonce")
    parser.add_argument("--expected-package", default="org.permaweb.handee")
    parser.add_argument(
        "--expected-signing-cert-digest",
        action="append",
        default=[],
        help="Expected SHA-256 digest of an app signing certificate, base64url or hex. Repeatable.",
    )
    parser.add_argument("--expected-verified-boot-key")
    parser.add_argument("--expected-verified-boot-hash")
    parser.add_argument("--min-os-patch-level", type=int, default=202605)
    parser.add_argument("--min-vendor-patch-level", type=int, default=20260501)
    parser.add_argument("--min-boot-patch-level", type=int, default=20260501)
    parser.add_argument("--require-strongbox", action="store_true")
    parser.add_argument("--allow-rejected", action="store_true")
    parser.add_argument(
        "--trusted-root-pem",
        action="append",
        default=[DEFAULT_ROOTS] if DEFAULT_ROOTS.exists() else [],
        type=pathlib.Path,
        help="Trusted Android attestation root certificate PEM. Repeatable.",
    )
    args = parser.parse_args()

    data = payload(json.loads(args.measurement.read_text()))
    if not isinstance(data, dict):
        print("measurement must be a JSON object", file=sys.stderr)
        return 2
    result = verify_measurement(data, args)

    if args.out:
        args.out.mkdir(parents=True, exist_ok=True)
        (args.out / "verdict.json").write_text(json.dumps({
            key: value for key, value in result.items()
            if key != "normalized_measurement"
        }, indent=2) + "\n")
        (args.out / "normalized-measurement.json").write_text(
            json.dumps(result["normalized_measurement"], indent=2) + "\n"
        )
        (args.out / "summary.txt").write_text(
            f"verdict={result['verdict']}\nverified={result['verified']}\n"
        )
    else:
        print(json.dumps(result, indent=2))
    return 0 if result["verified"] or args.allow_rejected else 1


if __name__ == "__main__":
    raise SystemExit(main())
