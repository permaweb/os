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
  5. AK authPolicy equals the LapEE policy over PCRs
     [0,1,7,10,11,14,15]. Including PCR 15 proves AK use is gated by
     the boot-subject measurement.
  6. PCR 15 replay: starting at all-zero, extend every PCR-15 event
     in `runtime-event-log' in `seq' order; result must equal the
     quoted PCR-15 value.
  7. Some PCR-15 event has digest equal to `node-message-id'. That
     closes the loop: TPM state commits to the running node's
     identity hash. Match by digest, not by seq position -- the
     binding event-type is `EV_HYPERBEAM_BOOT_ATTESTATION_SUBJECT'
     when on.start drives `~tpm@2.0a/boot-attestation' (the
     production path) and `EV_HYPERBEAM_NODE_IDENTITY_EXTEND'
     when a caller drives `~tpm@2.0a/extend' directly.
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
AK_POLICY_PCRS = [0, 1, 7, 10, 11, 14, 15]
TPM_CC_ACTIVATE_CREDENTIAL = 0x00000147
TPM_CC_POLICY_COMMAND_CODE = 0x0000016C
TPM_CC_POLICY_OR = 0x00000171
TPM_CC_POLICY_PCR = 0x0000017F


def b64url_decode(s: str) -> bytes:
    """Decode base64url without padding (Arweave/HB convention)."""
    pad = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + pad)


def unwrap_envelope(raw):
    """Accept the flat attestation envelope and the signed
    boot-attestation wrapper.

    The boot-attestation shape is:

      body.{system,node,tpm}

    `dev_tpm2' normalises that to the flat verifier shape before
    checking peer attestations. Do the same here so this external
    verifier checks the live production endpoint, not only the older
    `/attestation-json' form.
    """
    if not isinstance(raw, dict):
        return raw
    if "lapee-attestation-version" in raw:
        return raw
    if "body" in raw and isinstance(raw["body"], dict):
        body = raw["body"]
        if "lapee-attestation-version" in body:
            return body
        boot = normalise_boot_attestation(body)
        if boot is not None:
            return boot
    boot = normalise_boot_attestation(raw)
    if boot is not None:
        return boot
    return raw


def normalise_boot_attestation(body):
    if not isinstance(body, dict):
        return None
    if body.get("type") == "lapee-measurement":
        if body.get("measurement-device") != "tpm@2.0a":
            return None
        subject = body.get("body")
        evidence = body.get("evidence")
        if not isinstance(subject, dict) or not isinstance(evidence, dict):
            return None
        body = dict(subject)
        body["tpm"] = evidence
    system = body.get("system")
    node = body.get("node")
    tpm = body.get("tpm")
    if not all(isinstance(v, dict) for v in (system, node, tpm)):
        return None
    out = dict(tpm)
    if "tpm-quote" not in out and "quote" in out:
        out["tpm-quote"] = out["quote"]
    out.setdefault("lapee-attestation-version", EXPECTED_VERSION)
    if "version" in body:
        out["boot-attestation-version"] = body["version"]
    out["node-message"] = node
    out["node-message-id"] = out.get("extended-subject")
    out["wallet-address"] = node.get("address")
    out["system-report"] = system
    return out


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


# Cache fetched AIA intermediates per process so repeated verifies of
# peers in the same SoC family hit the URL exactly once. Keyed by URL.
_AIA_CACHE: dict[str, bytes] = {}


def _aia_caissuers_urls(pem_path):
    """Extract every `id-ad-caIssuers' URL from a cert's AIA extension
    via openssl text. We avoid the Python cryptography lib here because
    real Intel ODCA EK leaves carry DER quirks (`EncodedDefault') that
    the strict parser refuses, and openssl is what the verify path
    already shells out to. Returns a list of HTTPS URLs."""
    r = subprocess.run(
        ["openssl", "x509", "-in", str(pem_path), "-noout", "-text"],
        capture_output=True, text=True)
    if r.returncode != 0:
        return []
    urls = []
    in_aia = False
    for line in r.stdout.splitlines():
        stripped = line.strip()
        if "Authority Information Access" in stripped:
            in_aia = True
            continue
        if in_aia:
            if stripped.startswith("CA Issuers - URI:"):
                urls.append(stripped.split("URI:", 1)[1].strip())
            elif stripped and not stripped.startswith("OCSP")\
                    and not stripped.startswith("CA Issuers"):
                # Hit the next extension; stop scanning.
                in_aia = False
    return [u for u in urls if u.startswith("https://")]


def _aia_fetch(url, timeout=5):
    """HTTPS GET an AIA URL, cache successful fetches, return PEM
    bytes. Detects whether the server returned PEM or DER and
    normalises to PEM. Returns None on any failure -- caller decides
    whether to fall through."""
    if url in _AIA_CACHE:
        return _AIA_CACHE[url]
    if not url.startswith("https://"):
        return None
    try:
        import urllib.request
        req = urllib.request.Request(
            url, headers={"User-Agent": "lapee-aia/1"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(64 * 1024)
    except Exception:
        return None
    # Convert DER to PEM via openssl when the body is binary.
    if body[:11] == b"-----BEGIN ":
        pem = body
    else:
        r = subprocess.run(
            ["openssl", "x509", "-inform", "DER", "-outform", "PEM"],
            input=body, capture_output=True)
        if r.returncode != 0:
            return None
        pem = r.stdout
    # Sanity-parse via openssl before caching to reject arbitrary
    # bytes from a misconfigured AIA endpoint.
    r2 = subprocess.run(
        ["openssl", "x509", "-noout"],
        input=pem, capture_output=True)
    if r2.returncode != 0:
        return None
    _AIA_CACHE[url] = pem
    return pem


def _verify_cert_chain(ek_pem, roots_dir,
                       envelope_chain_pem=b"", aia_enabled=True):
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

    # The envelope itself can supply on-TPM intermediates via
    # `ek-cert-chain-pem' (Intel ODCA stuffs the PTT/Kernel/ROM CAs
    # into the TPM NV slot adjacent to the EK; the LapEE TPM device
    # carries them through to the verifier). Treat them as untrusted
    # intermediates so the chain walker can use them. They never
    # promote to trust anchors -- only self-signed certs from
    # `roots_dir' do that.
    envelope_pems = []
    if isinstance(envelope_chain_pem, str):
        envelope_chain_pem = envelope_chain_pem.encode()
    if envelope_chain_pem:
        envelope_pems = [envelope_chain_pem]

    # Materialise candidate intermediates as a single concatenated PEM
    # so openssl can chase the issuer chain across multiple bundled
    # intermediates in one shot. The previous "one intermediate at a
    # time" loop couldn't build the four-step Intel ODCA ladder.
    def _bundle(extra_pems):
        with tempfile.NamedTemporaryFile(suffix=".pem", mode="wb",
                                         delete=False) as g:
            for _, cert in intermediates:
                from cryptography.hazmat.primitives import serialization
                g.write(cert.public_bytes(
                    serialization.Encoding.PEM))
            for ep in envelope_pems + list(extra_pems):
                g.write(ep)
        return g.name

    def _try(root_path, bundle_path):
        cmd = ["openssl", "verify", "-CAfile", str(root_path)]
        if bundle_path is not None:
            cmd += ["-untrusted", str(bundle_path)]
        cmd.append(ek_path)
        r = subprocess.run(cmd, capture_output=True, text=True)
        return r.returncode == 0

    bundle_path = _bundle([])
    for root_path, _ in roots:
        if _try(root_path, None):
            return Check(
                "EK certificate chains to a self-signed manufacturer root",
                True,
                f"validated against {root_path.name} (direct)")
        if _try(root_path, bundle_path):
            return Check(
                "EK certificate chains to a self-signed manufacturer root",
                True,
                f"validated against {root_path.name} via "
                f"{len(intermediates)} bundled intermediate(s)")

    # Local trust + envelope-supplied intermediates didn't close the
    # chain. Walk AIA caIssuers URLs starting from the leaf, then from
    # each cert in the envelope's chain, and try again with the
    # fetched intermediates appended. Real EK leaves don't carry an
    # AIA pointer (their issuer is the on-TPM PTT/leaf CA, which is
    # already in the envelope chain); the AIA pointer lives mid-chain
    # on the cert whose issuer is the missing public Issuing CA. We
    # must split a concatenated envelope chain PEM into individual
    # cert files since `openssl x509 -text' only reads the first cert
    # of any input.
    if aia_enabled:
        import re as _re
        cert_paths = [ek_path]
        for ep in envelope_pems:
            ep_str = ep.decode() if isinstance(ep, bytes) else ep
            for single in _re.findall(
                    r"-----BEGIN CERTIFICATE-----.*?"
                    r"-----END CERTIFICATE-----",
                    ep_str, _re.DOTALL):
                with tempfile.NamedTemporaryFile(
                        suffix=".pem", mode="w", delete=False) as nt:
                    nt.write(single)
                    cert_paths.append(nt.name)
        fetched_pems = []
        fetched_summary = []
        seen_urls = set()
        for cert_path in cert_paths:
            urls = _aia_caissuers_urls(cert_path)
            for url in urls:
                if url in seen_urls:
                    continue
                seen_urls.add(url)
                p = _aia_fetch(url)
                if p:
                    fetched_pems.append(p)
                    fetched_summary.append(url)
            if len(fetched_pems) >= 5:
                break  # depth cap
        if fetched_pems:
            extended_bundle = _bundle(fetched_pems)
            for root_path, _ in roots:
                if _try(root_path, extended_bundle):
                    return Check(
                        "EK certificate chains to a self-signed manufacturer root",
                        True,
                        f"validated against {root_path.name} via "
                        f"{len(intermediates)} bundled + "
                        f"{len(envelope_pems)} envelope + "
                        f"{len(fetched_pems)} AIA-fetched intermediate(s) "
                        f"[{', '.join(fetched_summary)}]")

    return Check(
        "EK certificate chains to a self-signed manufacturer root",
        False,
        "no self-signed root anchors this EK cert.\n"
        f"       roots tried   : {len(roots)} "
        f"({', '.join(p.name for p,_ in roots)})\n"
        f"       bundled mids  : {len(intermediates)}, AIA: "
        f"{'enabled' if aia_enabled else 'disabled'}")


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
# 4b. AK authPolicy binds AK use to the LapEE PCR policy, including PCR 15
# ----------------------------------------------------------------------
def _tpm2b(buf, off=0):
    if off + 2 > len(buf):
        raise ValueError("truncated TPM2B size")
    size = int.from_bytes(buf[off:off + 2], "big")
    off += 2
    if off + size > len(buf):
        raise ValueError("truncated TPM2B payload")
    return buf[off:off + size], off + size


def _ak_auth_policy(envelope):
    public_blob = b64url_decode(envelope.get("ak-public", ""))
    public, _ = _tpm2b(public_blob, 0)
    off = 0
    if len(public) < 8:
        raise ValueError("truncated TPMT_PUBLIC")
    typ = int.from_bytes(public[off:off + 2], "big")
    off += 2
    off += 2  # nameAlg
    off += 4  # objectAttributes
    if typ != 0x0001:
        raise ValueError(f"unsupported AK public type 0x{typ:04x}")
    auth_policy, _ = _tpm2b(public, off)
    return auth_policy


def _policy_pcr_selection(pcrs):
    selected = sorted(pcrs)
    pcr_select = bytearray(3)
    for pcr in selected:
        pcr_select[pcr // 8] |= 1 << (pcr % 8)
    return (
        (1).to_bytes(4, "big") +
        (0x000B).to_bytes(2, "big") +
        bytes([3]) +
        bytes(pcr_select)
    )


def _compute_pcr_digest(pcrs, pcr_values):
    h = hashlib.sha256()
    for pcr in pcrs:
        value = pcr_values.get(str(pcr))
        if value is None:
            raise KeyError(pcr)
        h.update(b64url_decode(value))
    return h.digest()


def _expected_ak_policy_digest(pcrs, pcr_values):
    pcr_digest = _compute_pcr_digest(pcrs, pcr_values)
    selection = _policy_pcr_selection(pcrs)
    pcr_policy = hashlib.sha256(
        b"\x00" * 32 +
        TPM_CC_POLICY_PCR.to_bytes(4, "big") +
        selection +
        pcr_digest
    ).digest()
    activate_policy = hashlib.sha256(
        pcr_policy +
        TPM_CC_POLICY_COMMAND_CODE.to_bytes(4, "big") +
        TPM_CC_ACTIVATE_CREDENTIAL.to_bytes(4, "big")
    ).digest()
    return hashlib.sha256(
        b"\x00" * 32 +
        TPM_CC_POLICY_OR.to_bytes(4, "big") +
        pcr_policy +
        activate_policy
    ).digest()


def _verify_ak_policy_bound(envelope):
    try:
        policy = _ak_auth_policy(envelope)
        pcr_values = envelope["tpm-quote"]["pcr-values"]
        expected = _expected_ak_policy_digest(AK_POLICY_PCRS, pcr_values)
    except KeyError as e:
        return Check(
            "AK authPolicy is PCR-bound to quoted boot state",
            False,
            f"quote omitted AK policy PCR {e.args[0]}")
    except Exception as e:
        return Check(
            "AK authPolicy is PCR-bound to quoted boot state",
            False,
            str(e)[:200])
    if not policy:
        return Check(
            "AK authPolicy is PCR-bound to quoted boot state",
            False,
            "AK authPolicy is empty")
    if policy != expected:
        return Check(
            "AK authPolicy is PCR-bound to quoted boot state",
            False,
            f"policy={policy.hex()[:16]} expected={expected.hex()[:16]}")
    return Check(
        "AK authPolicy is PCR-bound to quoted boot state",
        True,
        f"policy covers PCRs {AK_POLICY_PCRS}")


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
# 6. PCR-15 event commits to node-message-id
# ----------------------------------------------------------------------
def _verify_node_msg_binding(envelope):
    events = _pcr15_events_in_order(envelope)
    claimed = envelope.get("node-message-id")
    if not claimed:
        return Check("PCR 15 event commits to node-message-id",
                     False, "no node-message-id in envelope")
    if not events:
        return Check("PCR 15 event commits to node-message-id",
                     False, "no PCR-15 events in runtime-event-log")
    matches = [e for e in events if e.get("digest") == claimed]
    if not matches:
        return Check(
            "PCR 15 event commits to node-message-id",
            False,
            f"no PCR-15 event digest matches node-message-id "
            f"{claimed[:16]}...")
    e = matches[0]
    return Check(
        "PCR 15 event commits to node-message-id",
        True,
        f"seq={e.get('seq')} {e.get('event-type')} digest "
        f"{claimed[:16]}... matches node-message-id")


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
def verify(envelope, roots_dir, aia_enabled=True):
    if envelope.get("lapee-attestation-version") != EXPECTED_VERSION:
        return [Check(
            f"envelope version is exactly {EXPECTED_VERSION!r}",
            False,
            f"got {envelope.get('lapee-attestation-version')!r}")]

    return [
        _verify_cert_chain(envelope["ek-cert-pem"], roots_dir,
                           envelope_chain_pem=envelope.get(
                               "ek-cert-chain-pem", ""),
                           aia_enabled=aia_enabled),
        *_verify_quote(envelope),
        _verify_ak_policy_bound(envelope),
        _verify_pcr15_replay(envelope),
        _verify_node_msg_binding(envelope),
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
    # Default to the runtime trust corpus baked into the LapEE node
    # image. `scripts/fetch-ek-root-cas.sh' populates it from keylime's
    # tpm_cert_store. Pointing both verifiers at the same directory
    # means one refresh updates the LapEE runtime and this auditor in
    # lockstep -- no parallel corpora to drift apart. Override on the
    # cmdline if you maintain a separate trust bundle.
    _default_roots = (
        pathlib.Path(__file__).resolve().parent.parent
        / "hyperbeam-overlay" / "priv" / "tpm-interpret" / "root-cas"
    )
    ap.add_argument("--roots-dir",
                    default=str(_default_roots),
                    help="directory of candidate root-CA PEMs. Only "
                         "self-signed certificates are treated as trust "
                         "anchors; all others become untrusted "
                         "intermediates. (default: the LapEE runtime "
                         "corpus at hyperbeam-overlay/priv/"
                         "tpm-interpret/root-cas/)")
    ap.add_argument("--no-aia-fetch", action="store_true",
                    help="disable AIA caIssuers fetching when the local "
                         "corpus + envelope-supplied intermediates do not "
                         "complete the chain. Use for offline / "
                         "hermetic audits.")
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

    results = verify(envelope, args.roots_dir,
                     aia_enabled=not args.no_aia_fetch)
    for r in results:
        print(r)
    ok = all(r.ok for r in results)
    print()
    print(f"VERDICT: {'ATTESTATION ACCEPTED' if ok else 'ATTESTATION REJECTED'}")
    print("=" * 68)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
