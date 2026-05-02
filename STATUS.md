# LapEE Green-Zone Peer Verification Overnight Pass

## Current Objective

Build a maintainable TPM-backed peer verification and green-zone ring flow.
The target is not just local attestation: LapEE nodes must be able to verify
each other, publish signed peer attestations, and admit only peers whose
boot-attestation matches a deeply nested ring template. Accepted peers receive
the ring AES key through TPM credential activation, then receive the ring
`priv-wallet` encrypted under that AES key.

## Starting State

- Branch: `feat/ak-ek-trust`.
- This checkout was one commit ahead of origin when work started:
  `2bccdf9 chore: reset STATUS.md for new overnight session`.
- `STATUS.md` had been deleted by that commit, so this file is the new
  working log.
- `~tpm@2.0a` verifies EK chain, quote signature, PCR/event-log replay,
  node-message binding, and AK-pub PCR binding.
- `~tpm@2.0a` does not yet prove EK/AK co-residency with credential
  activation.
- Existing upstream `dev_green_zone` is SNP-shaped and not suitable for
  LapEE TPM rings. It uses `dev_snp`, ad hoc RSA key wrapping, and no
  EK/AK credential activation.
- `dev_green_zone` currently comes from the fetched HyperBEAM checkout, not
  from the LapEE overlay.

## Commander’s Intent

1. LapEE peers verify one another with `~tpm@2.0a` using the full EK chain,
   AK quote, and EK/AK credential activation proof.
2. A peer can sign and store a verification of another peer’s
   boot-attestation. Later consumers can accept that peer attestation when
   they trust the verifier address.
3. `~green-zone@1.0` rings admit peers by matching a nested attestation
   template against the peer’s verified boot-attestation.
4. Admitted peers receive the ring AES key via TPM credential activation.
   The ring `priv-wallet` is then encrypted under that AES key.
5. Protocols must stay simple, documented, and small enough to maintain.

## Design Decision

Use the TPM-canonical credential activation flow as the only EK/AK
co-residency proof:

1. Peer exposes a signed credential subject:
   EK certificate/chain/source, EK public area/name, AK public area/name,
   and current boot-attestation identity.
2. Verifier checks the EK certificate chain and checks that the EK public
   area corresponds to the EK certificate public key.
3. Verifier generates a fresh 32-byte secret.
4. Verifier runs `TPM2_MakeCredential(EK public, AK Name, secret)`.
5. Peer runs `TPM2_ActivateCredential(AK, EK, credentialBlob, secretBlob)`.
6. Peer returns the recovered secret.
7. Verifier signs a peer-attestation message containing the peer URL,
   peer boot-attestation, credential-activation transcript, and verification
   checks.

For green-zone admission, use the same mechanism but set the credential
activation secret to the 32-byte ring AES key. That keeps the ring secret
bound to the joiner’s TPM-resident AK/EK pair without introducing another
key-exchange protocol.

## Plan

1. Add TPM NIF support:
   - Return TPM public areas and Names for EK and AK.
   - Add `make_credential(EkPublic, AkName, Secret)`.
   - Add `activate_credential(AkHandle, EkHandle, CredentialBlob, Secret)`.
2. Extend `~tpm@2.0a`:
   - Add `credential-subject`.
   - Add `activate-credential`.
   - Add `verify-peer&url=...`.
   - Make EK/AK binding an explicit check, not an `ak-hierarchy` inference.
3. Overlay a new `dev_green_zone.erl`:
   - Keep the device generic: ring admission is template matching over a
     verified attestation message.
   - Avoid SNP-specific assumptions.
   - Add `init`, `join`, `admit`, `status`, and `sign` paths.
4. Add focused tests for:
   - Credential activation transcript shape.
   - Template matching.
   - Admissible/inadmissible ring joins.
5. Add QEMU harness for four nodes:
   - Three nodes match the green-zone template and join.
   - One node differs and is refused.
   - The accepted nodes can sign as the shared ring wallet.

## Progress Log

- Created hourly Codex automation:
  `lapee-green-zone-peer-verification-loop`.
- Reconfirmed current gap: EK/AK co-residency is not yet verified by
  credential activation.
- Reconfirmed green-zone source is upstream-only; LapEE needs an overlay
  replacement for this protocol.

## Update 1

Implemented the first TPM credential-activation pass in the overlay:

- NIF now returns EK/AK public areas and TPM Names.
- NIF now exposes `make_credential/3` and `activate_credential/4`.
- `~tpm@2.0a` now exposes `credential-subject`, `activate-credential`,
  and `verify-peer`.
- `verify-peer` fetches peer boot-attestation and credential subject, checks
  the attestation, checks subject/boot AK+EK consistency, runs credential
  activation, then signs a `lapee-peer-attestation` message.

First compile found one Erlang unsafe-variable issue; fixed locally and
restaging now.

## Update 2

Validation so far:

- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2` passes in the
  staged HyperBEAM checkout.
- Host `rebar3 as lapee compile` reaches the TPM NIF build and then stops
  because this macOS host does not have the target TSS2 headers:
  `fatal error: 'tss2/tss2_esys.h' file not found`.

That is not a runtime acceptance check. The next verification step is to
compile the NIF through the LapEE Buildroot/Docker path where libtss2 is part
of the target toolchain, then fix any real C/API errors surfaced there.

## Update 3

Added the first LapEE-owned `~green-zone@1.0` overlay:

- Replaces the upstream SNP-shaped green-zone with a TPM-backed ring device.
- Adds `init`, `status`, `admit`, `join`, `sign`, and `match`.
- Ring admission now:
  1. Calls `~tpm@2.0a/verify-peer` for the joiner.
  2. Deep-subset-matches the joiner's verified boot-attestation against the
     ring template.
  3. Wraps the ring AES key to the joiner's EK/AK using
     `TPM2_MakeCredential`.
  4. Returns the ring wallet encrypted under that AES key.
- Join now activates the credential locally, decrypts the wallet, and installs
  it as the `green-zone` identity.
- Added `green-zone@1.0` as a real device alias while keeping the existing
  `greenzone@1.0` alias.

Focused tests now passing:

- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2`

Target Buildroot compile is now running with `-j18` to validate the NIF and
full release path.

## Update 4

First target Buildroot compile reached the LapEE TPM NIF and failed on the new
`Esys_LoadExternal` call signature. This validated that the build is now
exercising the target TSS2 headers. Fix applied:

- `Esys_LoadExternal(ctx, shandle1, shandle2, shandle3, inPrivate, inPublic,
  hierarchy, outHandle)` now passes explicit `ESYS_TR_NONE` session handles.
- The MakeCredential blob marshalling was also hardened to avoid relying on a
  nullable-size-probe convention in `Tss2_MU_*_Marshal`.

Next: re-run the Buildroot package compile and continue fixing target-only C
issues until the full release builds.

## Update 5

Target Buildroot build now passes with the new TPM credential-activation NIF
and green-zone overlay. Evidence:

- `make buildroot JOBS=18` completed successfully.
- Release contains:
  - `dev_tpm2.beam`
  - `dev_green_zone.beam`
  - `lapee_tpm_nif.beam`
  - `priv/lapee_tpm_nif.so`
- `file` reports the shipped NIF as x86-64 ELF.
- Focused host-side tests still pass after the docs/export update:
  - `rebar3 eunit --module=dev_green_zone`
  - `rebar3 eunit --module=dev_tpm2`

Next implementation target: QEMU swtpm EK-certificate provisioning and a
multi-node harness so credential activation can be proven end-to-end across
four concurrently running nodes.
