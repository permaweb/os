# Measurement Protocol

`~measurement@1.0` is the only public hardware measurement orchestration API.
It standardizes the measured subject and delegates only backend-native
evidence and secret wrapping to `~tpm@2.0a`, `~snp@1.0`, or future engines.

## Subject

Every measurement signs or verifies this subject:

```erlang
#{
    <<"system">> => SystemReport,
    <<"node">> => SignedNodeMessage
}
```

`SystemReport` is the result of `~system@1.0/all`. `SignedNodeMessage` is the
public `~meta@1.0/info` message in signed AO-Core form. The subject is included
directly; no duplicate `body-id` field is required.

## Measurement Message

```erlang
#{
    <<"type">> => <<"lapee-measurement">>,
    <<"version">> => <<"1.0">>,
    <<"issued-at-unix">> => UnixSeconds,
    <<"purpose">> => <<"boot">> | <<"fresh">>,
    <<"nonce">> => NonceOrBootSentinel,
    <<"measurement-device">> => DeviceName,
    <<"body">> => Subject,
    <<"evidence">> => BackendEvidence,
    <<"secret-recipient">> => Recipient
}
```

The top-level message is signed by the current HyperBEAM node identity. The
backend evidence proves, in a backend-specific way, that the included subject,
purpose, nonce, measurement device, and secret-recipient ID are bound to
hardware-rooted measurement. Boot measurements use purpose `boot` and a fixed
boot sentinel nonce. Fresh measurements use purpose `fresh` and a verifier
nonce with at least 128 bits of entropy.

## Public Exports

- `info`: selected device, candidate devices, and version.
- `boot`: return the cached signed boot measurement, generating it once during
  startup if absent.
- `fresh`: return a signed measurement bound to request key `nonce`.
- `verify`: return an AO-Core result message with `verified = true | false`.
- `verify-peer`: fetch peer `boot` and fresh measurement; verify them; return
  a signed `zone-peer-attestation`.
- `unwrap-secret`: recover a locally addressed challenge and return only a
  signed activation proof. It must never return the plaintext secret.

Secret wrapping is an internal operation used by `~zone@1.0`. Plaintext
unwrapped material must never leave the local process through a request.

## Backend Engine Contract

Measurement-capable devices implement:

- `supported`: whether real backend hardware is available.
- `recipient`: backend secret-recipient object.
- `measure`: produce backend evidence over the supplied subject and nonce.
- `verify`: verify backend evidence against subject, nonce, and recipient.
- internal `wrap-secret`: encrypt or credential-wrap a secret for a verified
  recipient.
- internal `unwrap-secret`: recover a locally addressed secret for trusted local
  callers only.

`auto` selection tries real `snp@1.0`, then real `tpm@2.0a`. Test mocks are
never selected by production `auto`.

## Failure Rules

Missing hardware, invalid evidence, nonce mismatch, subject mismatch, recipient
mismatch, bad signature, stale credential binding, or failed secret activation
returns an explicit error message. Verification fails unless boot and fresh
measurements have the same subject ID, node signer, backend, recipient object,
and recipient ID. The device must not silently fall back to a weaker backend.
