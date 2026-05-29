#!/usr/bin/env python3
"""Generate SEV-SNP ID block/auth blobs from measured LapEE evidence."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import struct
from typing import Any

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils


ID_BLOCK_SIZE = 0x60
ID_AUTH_SIZE = 0x1000
SNP_ECDSA_P384_SHA384 = 1
SNP_ECC_CURVE_P384 = 2


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate QEMU base64 SEV-SNP id-block/id-auth blobs."
    )
    parser.add_argument("--attestation", required=True, type=pathlib.Path)
    parser.add_argument("--out-dir", required=True, type=pathlib.Path)
    parser.add_argument("--key-dir", required=True, type=pathlib.Path)
    args = parser.parse_args()

    measurement = measurement_message(
        json.loads(args.attestation.read_text(encoding="utf-8"))
    )
    report = measurement["evidence"]["report"]
    keys = load_or_create_keys(args.key_dir)
    id_public = snp_public_key(keys["id"].public_key())
    author_public = snp_public_key(keys["author"].public_key())
    id_block = build_id_block(report)
    id_auth = bytearray(ID_AUTH_SIZE)
    struct.pack_into("<II", id_auth, 0, SNP_ECDSA_P384_SHA384,
                     SNP_ECDSA_P384_SHA384)
    id_auth[0x40:0x240] = snp_signature(keys["id"], id_block)
    id_auth[0x240:0x644] = id_public
    id_auth[0x680:0x880] = snp_signature(keys["author"], id_public)
    id_auth[0x880:0xC84] = author_public

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_blob(args.out_dir / "id-block", id_block)
    write_blob(args.out_dir / "id-auth", bytes(id_auth))
    metadata = {
        "id-key-digest": b64url(hashlib.sha384(id_public).digest()),
        "author-key-digest": b64url(hashlib.sha384(author_public).digest()),
        "measurement": report["measurement"],
        "family-id": b64url(decode_field(report, "family-id", 16)),
        "image-id": b64url(decode_field(report, "image-id", 16)),
        "guest-svn": int(report.get("guest-svn", 0)),
        "policy": int(report.get("policy", 0)),
    }
    (args.out_dir / "metadata.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


def measurement_message(attestation: dict[str, Any]) -> dict[str, Any]:
    body = attestation.get("body")
    if isinstance(body, dict) and body.get("type") == "lapee-measurement":
        return body
    if attestation.get("type") == "lapee-measurement":
        return attestation
    raise SystemExit("attestation did not contain a lapee-measurement body")


def load_or_create_keys(
    key_dir: pathlib.Path,
) -> dict[str, ec.EllipticCurvePrivateKey]:
    key_dir.mkdir(parents=True, exist_ok=True)
    return {
        "id": load_or_create_key(key_dir / "publisher-id-key.pem"),
        "author": load_or_create_key(key_dir / "publisher-author-key.pem"),
    }


def load_or_create_key(path: pathlib.Path) -> ec.EllipticCurvePrivateKey:
    if path.exists():
        key = serialization.load_pem_private_key(path.read_bytes(), password=None)
        if not isinstance(key, ec.EllipticCurvePrivateKey):
            raise SystemExit(f"{path} is not an EC private key")
        return key
    key = ec.generate_private_key(ec.SECP384R1())
    path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    path.chmod(0o600)
    return key


def build_id_block(report: dict[str, Any]) -> bytes:
    measurement = decode_field(report, "measurement", 48)
    family_id = decode_field(report, "family-id", 16)
    image_id = decode_field(report, "image-id", 16)
    guest_svn = int(report.get("guest-svn", 0))
    policy = int(report.get("policy", 0))
    return (
        measurement
        + family_id
        + image_id
        + struct.pack("<IIQ", 1, guest_svn, policy)
    )


def snp_public_key(key: ec.EllipticCurvePublicKey) -> bytes:
    numbers = key.public_numbers()
    return (
        struct.pack("<I", SNP_ECC_CURVE_P384)
        + numbers.x.to_bytes(72, "little")
        + numbers.y.to_bytes(72, "little")
        + bytes(0x404 - 0x94)
    )


def snp_signature(key: ec.EllipticCurvePrivateKey, data: bytes) -> bytes:
    der = key.sign(data, ec.ECDSA(hashes.SHA384()))
    r, s = utils.decode_dss_signature(der)
    return r.to_bytes(72, "little") + s.to_bytes(72, "little") + bytes(0x170)


def decode_field(report: dict[str, Any], key: str, size: int) -> bytes:
    value = report.get(key)
    if not value:
        return bytes(size)
    data = b64decode(str(value))
    if len(data) != size:
        raise SystemExit(f"{key} decoded to {len(data)} bytes, expected {size}")
    return data


def b64decode(value: str) -> bytes:
    padded = value + "=" * (-len(value) % 4)
    try:
        return base64.urlsafe_b64decode(padded)
    except Exception:
        return base64.b64decode(padded)


def write_blob(prefix: pathlib.Path, data: bytes) -> None:
    prefix.with_suffix(".bin").write_bytes(data)
    prefix.with_suffix(".b64").write_text(
        base64.b64encode(data).decode("ascii"),
        encoding="ascii",
    )


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


if __name__ == "__main__":
    raise SystemExit(main())
