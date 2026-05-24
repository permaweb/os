# `~measurement@1.0` Device Specification

`~measurement@1.0` owns the public PermawebOS measurement subject and common
peer protocol. It is the only device that zones call for hardware verification.
Backends such as TPM, SNP, and AndEE provide evidence; this device standardizes
the envelope.

## Responsibilities

- Build the subject once from `~system@1.0/all` and signed `~meta@1.0/info`.
- Select a real measurement engine by device name.
- Generate, sign, cache, and link the boot measurement.
- Generate fresh nonce-bound measurements.
- Verify local or peer measurement messages.
- Perform peer verification and sign `zone-peer-attestation` messages.
- Provide internal secret wrap/unwrap dispatch to trusted local devices.
- Stay policy neutral: expose verified facts and checks, but do not decide
  whether a deployment should trust a class of hardware.

## Cache Rule

`boot` is a singleton for a boot. It is generated during startup, signed, and
stored under `~measurement@1.0/boot` using the signed message ID.

## Peer Verification

Peer verification fetches:

- peer boot measurement,
- peer fresh measurement for a local nonce.

It verifies that boot/fresh subjects and recipients agree, verifies backend
evidence, verifies node signatures, and signs a peer attestation containing
verifier address, peer URL, peer node address, boot measurement ID, fresh
measurement ID, verifier nonce, subject ID, recipient ID, backend, issued-at,
expires-at, and verification result.
