# `~tpm@2.0a` Engine Specification

`~tpm@2.0a` is a measurement backend for TPM 2.0 hardware. Public product
flows consume it through `~measurement@1.0`; direct TPM command surfaces are
kept out of the v1 API.

## Engine Behavior

- Generate or load an AK whose policy binds PCR 15 after the PermawebOS
  measurement subject is extended.
- Extend PCR 15 with the boot measurement subject identity before quoting.
- Fresh measurements must not extend PCRs; they bind nonce through quote
  qualifying data.
- Quote the selected PCR set with the AK.
- Include EK certificate material, AK public material, PCR values, quote,
  signature, TCG event log, and enough chain material for offline verification.
- Verify EK chain against measured-in roots or peer-provided chains that end in
  known measured-in roots.
- Verify AK possession through credential activation.
- Use salted encrypted sessions for `ActivateCredential` secrets.

## Secret Wrapping

`wrap-secret` maps to `MakeCredential` for the peer recipient. `unwrap-secret`
maps to `ActivateCredential` on the local TPM and fails closed if the AK policy
or salted session cannot be established.

## Minimal Diagnostics

Keep only `info` and `supported` as direct diagnostics. Do not keep raw PCR,
quote, extend, or a separate TPM peer verification protocol when
`~measurement@1.0/verify-peer` covers the product flow.
