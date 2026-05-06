# Secondary external verifier

This directory holds an **external, non-HyperBEAM** verifier for LapEE
attestation envelopes. It exists to let a third party check an envelope
without running a HyperBEAM node, and as an independent implementation
that can be compared against `~tpm-interpret@1.0` (the primary verifier,
which lives on the `agent/lapee` branch in `src/dev_tpm_interpret.erl`).

This is the *secondary* verifier. In normal use, an off-LapEE
HyperBEAM node running `~tpm-interpret@1.0` is what verifies; the code
in this directory is for reviewers / auditors / CI jobs that want a
standalone tool with a minimal dependency surface.

## What it does

Eight checks, in order:

1. **EK certificate chains to a self-signed manufacturer root.** Loads
   every PEM in `--roots-dir`, splits them into self-signed (candidate
   trust anchors) and non-self-signed (candidate intermediates), then
   runs `openssl verify` with each root in turn. A non-self-signed
   certificate *cannot* serve as a trust anchor — if the bundle
   contains an intermediate mislabelled as a root, the check fails
   and names it in the output. This is the one guarantee that separates
   a real manufacturer chain from a chain that loops back to a cert
   the attester themselves could have issued.
2. **Quote signature** valid under the envelope's AK public key
   (RSA-PSS/SHA-256, salt 32).
3. **Quote extraData == nonce** in the envelope.
4. **Quote pcrDigest == SHA-256(PCR values concatenated in selection
   order)**.
5. **AK authPolicy matches the LapEE PCR policy** over
   `[0, 1, 7, 10, 11, 14, 15]`, proving AK use is gated by the quoted
   boot state including PCR 15.
6. **Runtime event-log PCR 15 replay** matches the quoted PCR 15 value.
7. **Some PCR 15 event digest equals `node-message-id`** — TPM state
   commits to the running node identity. Match by digest, not by seq
   position.
8. **Embedded `node-message` + id shape** (id decodes to 32 bytes).

## Intentional limitations

- Envelope shape: currently handles `lapee-attestation-version = "0.4"`,
  the live shape emitted by `~tpm@2.0a/attestation`.
- No hardware introspection — this tool never talks to a TPM; it only
  validates cryptographic evidence in the envelope itself.
- Trust anchor selection: by default the verifier reads from the LapEE
  runtime trust corpus at `../hyperbeam-overlay/priv/tpm-interpret/root-cas/`,
  the same directory `~tpm-interpret@1.0` loads on the node and that
  `scripts/fetch-ek-root-cas.sh` populates from keylime's
  `tpm_cert_store`. Both verifiers share one corpus so a single refresh
  updates them in lockstep. Override with `--roots-dir` for an
  independent audit. **Audit the corpus before use** — at time of
  writing, at least one file in it (`NUVOTON_NPCTxxx_ECC384_LeafCA_012110.pem`)
  is an intermediate, not a root, and this verifier will honestly refuse
  to treat it as a trust anchor.

## Usage

```bash
# default --roots-dir resolves to the runtime corpus next door
python3 verifier_hb.py <envelope.json>
# or supply your own
python3 verifier_hb.py <envelope.json> --roots-dir <dir>
```

Exit code: 0 if all eight checks pass, 1 otherwise. Each check prints
its own PASS/FAIL line with detail.
