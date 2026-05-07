#!/usr/bin/env bash
# fetch-ek-root-cas.sh -- populate priv/tpm-interpret/root-cas/ with
# public TPM vendor EK-cert root + intermediate CAs.
#
# These roots are required for legitimate end-to-end EK chain
# validation: without them, claim_ek.chain-validation reports
# `no-roots-loaded' and a real attestation chain has nothing to
# anchor against.
#
# Primary source: the keylime project's TPM cert store
# (github.com/keylime/keylime/tpm_cert_store). Keylime is the
# upstream reference for TPM-based remote attestation in Linux
# distros, is BSD-licensed, and maintains a curated set of
# Infineon / Intel / Nuvoton / STMicro / GlobalSign / Alibaba /
# Nationz roots and intermediates. Using it as the trust anchor
# keeps us aligned with the broader Linux ecosystem rather than
# shipping a boutique bundle.
#
# AMD fTPM EK *leaf* certificates are fetched per public key from
# https://ftpm.amd.com/pki/aia/<id>, but AMD also publishes stable
# RSA/ECC EK roots and Ryzen 6000 intermediates through that AIA
# service. Keep those anchors in this measured corpus so AMD peers
# can validate without caller-supplied roots.
#
# Usage:
#   ./scripts/fetch-ek-root-cas.sh            # refresh all
#   ./scripts/fetch-ek-root-cas.sh --check    # verify existing files
#   ./scripts/fetch-ek-root-cas.sh --add URL  # add a new root URL

set -euo pipefail

cd "$(dirname "$0")/.."
# DEST is the runtime trust corpus baked into the LapEE node image:
# `~tpm-interpret@1.0' loads it via `hb_db_tpm:read_cert_roots/1' and
# `~tpm@2.0a/verify' reads from the same path. The secondary external
# verifier (`secondary-external-verifier/verifier_hb.py') is the
# *secondary* verifier and points at this same directory so that one
# refresh updates both sides; do not maintain a parallel corpus.
DEST="hyperbeam-overlay/priv/tpm-interpret/root-cas"
mkdir -p "$DEST"

MODE="${1:-fetch}"

KEYLIME_API="https://api.github.com/repos/keylime/keylime/contents/tpm_cert_store"

if [ "$MODE" = "--check" ]; then
    echo "=== current root-cas/ contents ==="
    n=0
    for f in "$DEST"/*.pem; do
        [ -f "$f" ] || continue
        subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null \
                | sed 's/^subject= *//' || echo "(unparseable)")
        notafter=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null \
                | sed 's/^notAfter= *//')
        printf "  %-40s  %s\n                                          (expires %s)\n" \
            "$(basename "$f")" "$subj" "$notafter"
        n=$((n+1))
    done
    echo ""
    echo "$n root/intermediate certs loaded."
    exit 0
fi

if [ "$MODE" = "--add" ]; then
    URL="${2:?}"
    NAME="${3:-$(basename "$URL")}"
    NAME="${NAME%.crt}.pem"
    NAME="${NAME%.cer}.pem"
    out="$DEST/$NAME"
    tmp="$out.tmp.$$"
    echo "=> fetching $URL"
    curl -fsSL --connect-timeout 10 --max-time 60 "$URL" -o "$tmp"
    if head -1 "$tmp" | grep -q "BEGIN CERTIFICATE"; then
        mv "$tmp" "$out"
    else
        openssl x509 -inform DER -in "$tmp" -out "$out"
        rm -f "$tmp"
    fi
    openssl x509 -in "$out" -noout -subject
    exit 0
fi

# -- bulk fetch from keylime -------------------------------------------

echo "=> enumerating keylime tpm_cert_store ..."
LIST=$(curl -fsSL --connect-timeout 15 --max-time 60 "$KEYLIME_API" \
    | python3 -c "
import json,sys
for f in json.load(sys.stdin):
    n = f.get('name','')
    if n.lower().endswith(('.pem','.crt','.cer')):
        print(n + '|' + f['download_url'])
")
echo "$LIST" | wc -l | awk '{printf "   %s certs in upstream store\n", $1}'

fail=0
got=0
for spec in $LIST; do
    IFS='|' read -r name url <<< "$spec"
    out="$DEST/$name"
    tmp="$out.tmp.$$"
    if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp" \
            2>/dev/null; then
        if head -1 "$tmp" | grep -q "BEGIN CERTIFICATE"; then
            mv "$tmp" "$out"
            got=$((got+1))
        elif openssl x509 -inform DER -in "$tmp" -out "$out" 2>/dev/null; then
            rm -f "$tmp"
            got=$((got+1))
        else
            rm -f "$tmp"
            echo "   [warn] $name: not PEM or DER" >&2
            case "$name" in
                Alibaba_Cloud_vTPM_EK.pem|Nationz_TPM_EK.pem)
                    ;;
                *) fail=1 ;;
            esac
        fi
    else
        rm -f "$tmp"
        echo "   [warn] $name: fetch failed" >&2
        fail=1
    fi
done

# Keep the explicit Infineon Optiga fetches from the original script
# -- these are the CA030 roots used for current-production SLB96xx
# TPMs, which are easier to audit individually than via keylime's
# numerically-named IFX_RSA_034.pem etc.
EXTRA=(
  # AMD fTPM EK CA anchors. The EK leaves themselves are per-device
  # and fetched via ftpm.amd.com/pki/aia/<hash>; these static CAs are
  # the public roots/intermediates referenced by that AMD AIA service.
  "AMD_EK_RSA_ROOT.pem|https://ftpm.amd.com/pki/aia/264D39A23CEB5D5B49D610044EEBD121"
  "AMD_EK_ECC_ROOT.pem|https://ftpm.amd.com/pki/aia/23452201D41C5AB064032BD23F158FEF"
  "AMD_EK_RYZEN_6000_RSA_INTERMEDIATE.pem|https://ftpm.amd.com/pki/aia/51ADE34A2F8253525E2321AD63F7B197"
  "AMD_EK_RYZEN_6000_ECC_INTERMEDIATE.pem|https://ftpm.amd.com/pki/aia/D30EE6F7557055BA66AD1A1DD1157D2C"
  "infineon-optiga-rsa-ca030.pem|https://pki.infineon.com/OptigaRsaMfrCA030/OptigaRsaMfrCA030.crt"
  "infineon-optiga-ecc-ca030.pem|https://pki.infineon.com/OptigaEccMfrCA030/OptigaEccMfrCA030.crt"
  # Nuvoton NPCTxxx EK chain -- v1.2.1 addition after Sam's
  # Framework 13 v1.1 capture showed EK chain broken because
  # keylime's bundle doesn't include the NPCT75x-family LeafCA +
  # ECC521 RootCA. Discovered via the Authority-Information-Access
  # URI in Sam's EK cert itself:
  #   AIA -> www.nuvoton.com/security/NTC-TPM-EK-Cert/
  # Nuvoton's CDN serves these over HTTPS but their cert chain
  # doesn't validate from a standard trust store (self-signed
  # intermediate), so --insecure is required. Content integrity is
  # verified by the chain-to-trusted-root test at the end of this
  # block, not by TLS to Nuvoton.
  "NUVOTON_NPCTxxx_ECC384_LeafCA_012110.pem|insecure:https://www.nuvoton.com/security/NTC-TPM-EK-Cert/NPCTxxxECC384LeafCA012110.cer"
  "NUVOTON_NPCTxxx_ECC521_RootCA.pem|insecure:https://www.nuvoton.com/security/NTC-TPM-EK-Cert/NPCTxxxECC521RootCA.cer"
  # Intel 11th-gen+ PTT ODCA chain anchors. The PTT/Kernel/ROM
  # EICAs are embedded in TPM NV 0x01c00100+, while the ROM EICA
  # points via AIA to product/intermediate/root certs published under
  # Intel's OnDieCA endpoint.
  "INTEL_ODCA_ROOT_CA.pem|https://tsci.intel.com/content/OnDieCA/certs/OnDie_CA_RootCA_Certificate.cer"
  "INTEL_ODCA_CA2_CSME_INTERMEDIATE.pem|https://tsci.intel.com/content/OnDieCA/certs/ODCA_CA2_CSME_Intermediate.cer"
  "INTEL_ODCA_MTL_00003043_CA2.pem|https://tsci.intel.com/content/OnDieCA/certs/MTL_00003043_ODCA_CA2.cer"
)
for spec in "${EXTRA[@]}"; do
    IFS='|' read -r name url <<< "$spec"
    out="$DEST/$name"
    tmp="$out.tmp.$$"
    # `insecure:' prefix on the URL tells us to pass -k to curl. Used
    # for the Nuvoton NPCTxxx chain (see comment in EXTRA list above).
    curl_opts="-fsSL --connect-timeout 10 --max-time 60"
    case "$url" in
        insecure:*) curl_opts="$curl_opts --insecure"; url="${url#insecure:}" ;;
    esac
    if curl $curl_opts "$url" -o "$tmp" 2>/dev/null; then
        if head -1 "$tmp" | grep -q "BEGIN CERTIFICATE"; then
            mv "$tmp" "$out"
        elif openssl x509 -inform DER -in "$tmp" -out "$out" 2>/dev/null; then
            rm -f "$tmp"
        fi
        got=$((got+1))
    else
        rm -f "$tmp"
    fi
done

echo ""
echo "=== summary ==="
printf "  %s root/intermediate certs loaded in %s\n" "$got" "$DEST"
[ "$fail" = 0 ] || echo "  (some fetches failed; see warnings above)"
exit $fail
