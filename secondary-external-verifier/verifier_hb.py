"""verifier_hb.py — validate a LapEE attestation produced by dev_tpm2.

Targets envelope `lapee-attestation-version: "0.4"' (the live shape on
agent/lapee + the Framework iron boot stack as of 2026-04-25). Earlier
versions are rejected outright; this verifier is a SECONDARY check
(separate codebase, separate language) so divergence is the point.

Envelope shape (kebab-case keys, base64url 32-byte IDs):

  lapee-attestation-version : "0.4"
  ek-cert-pem               : EK certificate (PEM)
  ek-cert-source            : { kind: "tpm-nv" | "absent", handle, ... }
  ak-pub-pem                : Attestation Key public key (PEM)
  ak-hierarchy              : "endorsement"
  tpm-quote                 : { pcr-selection, nonce, quoted, signature,
                                pcr-values: { "0": b64url, ..., "15": b64url } }
  runtime-event-log         : [{seq, pcr, event-type, digest, subject?, ...}]
  node-message              : the running HB node message (map)
  node-message-id           : 32-byte native id (base64url, 43 chars)
  wallet-address            : operator wallet address (AR human-id)

The bundle endpoint `/~tpm@2.0a/attestation' returns the envelope
inside `{"body": <env>, ...}'. The plain endpoint
`/~tpm@2.0a/attestation-json' returns the envelope at the top level
(when not 500-ing). We accept either by unwrapping `body' if present.

Checks:
  1. EK certificate chains to a self-signed manufacturer root.
  2. TPM2_Quote signature is valid under the AK public key (RSA-PSS
     SHA-256, salt 32). Extracts the standard TPMS_ATTEST.
  3. Quote's extraData == nonce field of the envelope.
  4. Quote's pcrDigest == SHA-256(pcr0||pcr1||...||pcr15) in the
     order given by `pcr-selection'.
  5. PCR 15 replay: starting at all-zero, extend every PCR-15 event
     in `runtime-event-log' in `seq' order; result must equal the
     quoted PCR-15 value.
  6. The seq=0 PCR-15 event (must be `EV_HYPERBEAM_NODE_IDENTITY_EXTEND')
     digest equals `node-message-id'. That closes the loop: TPM state
     commits to the running node's identity hash.
  7. The seq=1 PCR-15 event (must be `EV_HYPERBEAM_KEY_PUBKEY_EXTEND')
     digest equals sha256(ak-pub-pem). Paper P5: AK is bound to the
     measured-boot session.
  8. node-message + node-message-id present, IDs are base64url 32 bytes.
"""
from __future__ import annotations

import base64
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

EXPECTED_VERSION = "0.4"


def b64url_decode(s: str) -> bytes:
    """Decode base64url without padding (Arweave/HB convention)."""
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def b64url_encode(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode("ascii").rstrip("=")


def unwrap_envelope(raw):
    """Bundle endpoint nests the envelope in `body'; plain endpoint
    returns it at top level. Accept either."""
    if isinstance(raw, dict) and "body" in raw and isinstance(raw["body"], dict):
        body = raw["body"]
        if "lapee-attestation-version" in body:
            return body
    return raw


class Check:
    def __init__(self, name, ok, detail=""):
        self.name = name
        self.ok = ok
        self.detail = detail

    def __repr__(self):
        tag = "[PASS]" if self.ok else "[FAIL]"
        return f"{tag} {self.name}\n       {self.detail}"


# ----------------------------------------------------------------------
# 1. EK chain  (unchanged from v0.3 -- self-signed-only anchors)
# ----------------------------------------------------------------------
def _load_roots(roots_dir):
    from cryptography import x509
    roots_dir = pathlib.Path(roots_dir)
    roots, intermediates, unreadable = [], [], []
    for p in sorted(roots_dir.glob("*.pem")):
        try:
            cert = x509.load_pem_x509_certificate(p.read_bytes())
        except Exception as e:
            unreadable.append((p, str(e)))
            continue
        if cert.subject == cert.issuer:
            roots.append((p, cert))
        else:
            intermediates.append((p, cert))
    return roots, intermediates, unreadable


def _verify_cert_chain(ek_pem, roots_dir):
    roots, intermediates, unreadable = _load_roots(roots_dir)
    if not roots:
        return Check(
            "EK certificate chains to a self-signed manufacturer root",
            False,
            f"no self-signed certs in {roots_dir} "
            f"({len(intermediates)} non-self-signed, "
            f"{len(unreadable)} unreadable)")

    with tempfile.NamedTemporaryFile(suffix=".pem", mode="w",
                                     delete=False) as f:
        f.write(ek_pem)
        ek_path = f.name

    def _try(root_path, mid):
        cmd = ["openssl", "verify", "-CAfile", str(root_path)]
        if mid is not None:
            cmd += ["-untrusted", str(mid)]
        cmd.append(ek_path)
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.returncode == 0

    for root_path, _ in roots:
        if _try(root_path, None):
            return Check(
                "EK certificate chains to a self-signed manufacturer root",
                True,
                f"validated against {root_path.name} (direct)")
        for mid_path, _ in intermediates:
            if _try(root_path, mid_path):
                return Check(
                    "EK certificate chains to a self-signed manufacturer root",
                    True,
                    f"validated against {root_path.name} via {mid_path.name}")

    from cryptography import x509
    ek_cert = x509.load_pem_x509_certificate(ek_pem.encode())
    return Check(
        "EK certificate chains to a self-signed manufacturer root",
        False,
        "no self-signed root anchors this EK cert.\n"
        f"       EK issuer     : {ek_cert.issuer.rfc4514_string()}\n"
        f"       roots tried   : {len(roots)} "
        f"({', '.join(p.name for p,_ in roots)})\n"
        f"       intermediates : {len(intermediates)}, none completed.")


# ----------------------------------------------------------------------
# 2-4. TPM2_Quote: signature, extraData == nonce, pcrDigest match
# ----------------------------------------------------------------------
def _verify_quote(envelope):
    q = envelope["tpm-quote"]
    quoted = b64url_decode(q["quoted"])
    sig    = b64url_decode(q["signature"])
    nonce  = b64url_decode(q["nonce"])
    ak_pem = envelope["ak-pub-pem"].encode()
    selection = q["pcr-selection"]
    # `pcr-values' map carries a stray `commitments' key alongside the
    # actual PCR indices; filter to the integer-keyed entries only.
    pcr_values = {
        k: v for k, v in q["pcr-values"].items()
        if isinstance(k, str) and k.isdigit()
    }

    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding

    try:
        ak = serialization.load_pem_public_key(ak_pem)
        ak.verify(
            sig, quoted,
            padding.PSS(mgf=padding.MGF1(hashes.SHA256()), salt_length=32),
            hashes.SHA256(),
        )
    except Exception as e:
        return [Check("TPM2_Quote signature valid under AK public key",
                      False, str(e)[:200])]

    # Parse TPMS_ATTEST: magic(4) type(2) qualifiedSigner(TPM2B)
    #   extraData(TPM2B) clockInfo(17) firmwareVersion(8)
    #   attested(TPMS_QUOTE_INFO: pcrSelect(TPML_PCR_SELECTION)
    #                              pcrDigest(TPM2B_DIGEST))
    off = 4 + 2
    qs_size = int.from_bytes(quoted[off:off + 2], "big")
    off += 2 + qs_size
    ed_size = int.from_bytes(quoted[off:off + 2], "big")
    off += 2
    extra = quoted[off:off + ed_size]
    off += ed_size
    if extra != nonce:
        return [Check("TPM2_Quote extraData == nonce",
                      False,
                      f"extraData={extra.hex()[:16]}... "
                      f"nonce={nonce.hex()[:16]}...")]
    off += 17 + 8
    n_sel = int.from_bytes(quoted[off:off + 4], "big")
    off += 4
    for _ in range(n_sel):
        off += 2
        sz = quoted[off]
        off += 1
        off += sz
    pd_size = int.from_bytes(quoted[off:off + 2], "big")
    off += 2
    claimed_digest = quoted[off:off + pd_size]

    m = hashlib.sha256()
    for idx in selection:
        v = pcr_values.get(str(idx))
        if v is None:
            return [Check("Quote pcrDigest matches reported PCR values",
                          False, f"missing value for PCR {idx}")]
        m.update(b64url_decode(v))
    if claimed_digest != m.digest():
        return [Check(
            "Quote pcrDigest matches reported PCR values",
            False,
            f"quote={claimed_digest.hex()[:16]} "
            f"vs computed={m.digest().hex()[:16]}")]
    return [Check("TPM2_Quote signature + pcrDigest + nonce all valid",
                  True,
                  "OpenSSL PSS + TPMS_ATTEST parse ok; "
                  f"selection={selection}")]


# ----------------------------------------------------------------------
# 5. PCR-15 replay matches quote
# ----------------------------------------------------------------------
def _pcr15_events_in_order(envelope):
    events = [e for e in envelope["runtime-event-log"]
              if int(e.get("pcr", -1)) == 15]
    events.sort(key=lambda e: int(e["seq"]))
    return events


def _verify_pcr15_replay(envelope):
    events = _pcr15_events_in_order(envelope)
    pcr = b"\x00" * 32
    for e in events:
        digest = b64url_decode(e["digest"])
        pcr = hashlib.sha256(pcr + digest).digest()
    quoted = b64url_decode(
        envelope["tpm-quote"]["pcr-values"].get("15", ""))
    ok = pcr == quoted
    return Check(
        "Runtime event log replay of PCR 15 matches quoted value",
        ok,
        f"{len(events)} PCR-15 event(s); "
        f"replay={pcr.hex()[:16]}... quote={quoted.hex()[:16]}...")


# ----------------------------------------------------------------------
# 6. seq=0 event commits to node-message-id
# ----------------------------------------------------------------------
def _verify_node_msg_binding(envelope):
    events = _pcr15_events_in_order(envelope)
    claimed = envelope.get("node-message-id")
    if not claimed:
        return Check("PCR 15 seq=0 commits to node-message-id",
                     False, "no node-message-id in envelope")
    if not events:
        return Check("PCR 15 seq=0 commits to node-message-id",
                     False, "no PCR-15 events in runtime-event-log")
    e0 = events[0]
    if e0.get("event-type") != "EV_HYPERBEAM_NODE_IDENTITY_EXTEND":
        return Check(
            "PCR 15 seq=0 commits to node-message-id",
            False,
            f"seq=0 event-type is {e0.get('event-type')!r}, expected "
            "EV_HYPERBEAM_NODE_IDENTITY_EXTEND")
    if e0.get("digest") != claimed:
        return Check(
            "PCR 15 seq=0 commits to node-message-id",
            False,
            f"seq=0 digest={e0.get('digest')[:16]}... vs "
            f"node-message-id={claimed[:16]}...")
    return Check(
        "PCR 15 seq=0 commits to node-message-id",
        True,
        f"seq=0 EV_HYPERBEAM_NODE_IDENTITY_EXTEND digest "
        f"{claimed[:16]}... matches node-message-id")


# ----------------------------------------------------------------------
# 7. seq=1 event commits to AK pub PEM (paper P5 binding)
# ----------------------------------------------------------------------
def _verify_ak_pubkey_binding(envelope):
    events = _pcr15_events_in_order(envelope)
    if len(events) < 2:
        return Check("PCR 15 seq=1 commits to AK pub PEM (paper P5)",
                     False, f"only {len(events)} PCR-15 event(s); need ≥2")
    e1 = events[1]
    if e1.get("event-type") != "EV_HYPERBEAM_KEY_PUBKEY_EXTEND":
        return Check(
            "PCR 15 seq=1 commits to AK pub PEM (paper P5)",
            False,
            f"seq=1 event-type is {e1.get('event-type')!r}, expected "
            "EV_HYPERBEAM_KEY_PUBKEY_EXTEND")
    ak_pem = envelope["ak-pub-pem"].encode()
    expected_digest = b64url_encode(hashlib.sha256(ak_pem).digest())
    if e1.get("digest") != expected_digest:
        return Check(
            "PCR 15 seq=1 commits to AK pub PEM (paper P5)",
            False,
            f"seq=1 digest={e1.get('digest')[:16]}... vs "
            f"sha256(ak-pub-pem)={expected_digest[:16]}...")
    return Check(
        "PCR 15 seq=1 commits to AK pub PEM (paper P5)",
        True,
        f"seq=1 EV_HYPERBEAM_KEY_PUBKEY_EXTEND digest "
        f"{expected_digest[:16]}... matches sha256(ak-pub-pem)")


# ----------------------------------------------------------------------
# 8. node-message + id present and correctly shaped
# ----------------------------------------------------------------------
def _verify_node_msg_shape(envelope):
    nm = envelope.get("node-message")
    idb64 = envelope.get("node-message-id")
    if not nm or not idb64:
        return Check(
            "Embedded node-message + id present",
            False,
            f"node-message={'yes' if nm else 'no'} "
            f"id={'yes' if idb64 else 'no'}")
    try:
        idb = b64url_decode(idb64)
    except Exception as e:
        return Check("Embedded node-message + id present", False,
                     f"node-message-id not base64url-decodable: {e}")
    if len(idb) != 32:
        return Check(
            "Embedded node-message + id present", False,
            f"node-message-id decodes to {len(idb)} bytes, expected 32")
    return Check(
        "Embedded node-message + id present and 32-byte b64url",
        True,
        f"node-message is {len(nm)}-key map; id = {idb64[:16]}...")


# ----------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------
def verify(envelope, roots_dir):
    if envelope.get("lapee-attestation-version") != EXPECTED_VERSION:
        return [Check(
            f"envelope version is exactly {EXPECTED_VERSION!r}",
            False,
            f"got {envelope.get('lapee-attestation-version')!r}")]

    return [
        _verify_cert_chain(envelope["ek-cert-pem"], roots_dir),
        *_verify_quote(envelope),
        _verify_pcr15_replay(envelope),
        _verify_node_msg_binding(envelope),
        _verify_ak_pubkey_binding(envelope),
        _verify_node_msg_shape(envelope),
    ]


def main():
    import argparse
    ap = argparse.ArgumentParser(
        description="LapEE attestation verifier (secondary, external). "
                    "Validates a v0.4 envelope from the dev_tpm2 device "
                    "independently of any HyperBEAM node.")
    ap.add_argument("envelope",
                    help="path to a LapEE attestation envelope JSON "
                         "(either /attestation-json or the bundled "
                         "/attestation form -- both are accepted)")
    # Default to the directory that ships with this repo (the
    # `fetch-ek-root-cas.sh' script populates it from keylime's
    # tpm_cert_store). Override on the cmdline if you maintain a
    # separate trust bundle.
    _default_roots = pathlib.Path(__file__).resolve().parent / "root-cas"
    ap.add_argument("--roots-dir",
                    default=str(_default_roots),
                    help="directory of candidate root-CA PEMs. Only "
                         "self-signed certificates are treated as trust "
                         "anchors; all others become untrusted "
                         "intermediates. (default: ./root-cas next to "
                         "verifier_hb.py)")
    args = ap.parse_args()

    raw = json.loads(pathlib.Path(args.envelope).read_text())
    envelope = unwrap_envelope(raw)

    print("=" * 68)
    print("LapEE attestation verifier (secondary, external)")
    print("=" * 68)
    print(f"  envelope            : {args.envelope}")
    print(f"  roots dir           : {args.roots_dir}")
    print(f"  version             : "
          f"{envelope.get('lapee-attestation-version')}")
    print(f"  wallet-address      : {envelope.get('wallet-address')}")
    print(f"  node-message-id     : {envelope.get('node-message-id')}")
    pv = envelope.get("tpm-quote", {}).get("pcr-values", {})
    print(f"  quoted pcr-15       : {pv.get('15')}")
    pp = envelope.get("platform-probes", {})
    print(f"  dmi-sys-vendor      : {pp.get('dmi-sys-vendor')}")
    print(f"  dmi-product-name    : {pp.get('dmi-product-name')}")
    print(f"  tpm-session-mode    : {envelope.get('tpm-session-mode')}")
    print()

    results = verify(envelope, args.roots_dir)
    for r in results:
        print(r)
    ok = all(r.ok for r in results)
    print()
    print(f"VERDICT: {'ATTESTATION ACCEPTED' if ok else 'ATTESTATION REJECTED'}")
    print("=" * 68)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
