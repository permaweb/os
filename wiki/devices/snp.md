# `~snp@1.0` Engine Specification

`~snp@1.0` is the measurement backend for AMD SEV-SNP guests. It is the
virtualized PermawebOS security engine: SNP provides guest memory
confidentiality and integrity inside the AMD SEV-SNP threat model, while
`~measurement@1.0` provides the common AO-Core envelope.

## Engine Behavior

- `supported` succeeds only when real SNP guest hardware/device support exists.
- The native component only checks support and obtains raw SNP reports and
  platform-supplied certificate material from `/dev/sev-guest`.
- Erlang parses the SNP report and binds `report-data` to a domain-separated
  SHA-512 digest of subject ID, purpose, nonce, measurement-device, and
  secret-recipient ID. It verifies the report signature and certificate chain,
  then exposes policy-neutral fields.
- The device does not enforce debug bit, TCB floor, launch measurement, or host
  policy. It exposes them for templates and callers.
- Non-SNP architectures still build the verifier path when possible. Local
  measurement generation must fail softly when real SNP guest support is absent.

## Secret Wrapping

SNP has no TPM-style ActivateCredential. The local recipient contains a
boot-local X25519 public key bound into `report-data`. Internal `wrap-secret`
uses X25519, HKDF-SHA256, and AES-256-GCM with ring-reference and purpose in
the AAD. Internal `unwrap-secret` uses the boot-local private key and never
returns plaintext over HTTP.

## Evidence

Evidence includes raw report bytes, parsed report fields, report-data binding
inputs, certificate chain facts, and verification checks.
