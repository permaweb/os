# LapEE Green-Zone Peer Verification Status

## Current State

Branch: `feat/ak-ek-trust`.

LapEE now has an end-to-end QEMU green-zone flow: four nodes boot from the
same no-TME image, three nodes matching the green-zone template join and sign
with the shared ring identity, and the mismatching node is rejected and cannot
sign.

The critical AK/PCR policy bug described in `AK_PCR_POLICY_ISSUE.md` is fixed.
Native AKs are created with an auth policy rather than user auth, quote and
ActivateCredential run through PCR policy sessions, and verification recomputes
the AK policy from the quoted PCRs before accepting the attestation. PCR15 is
excluded from AK creation policy because LapEE extends PCR15 later with runtime
state.

## Latest Validation

Overlay staged into `build/hyperbeam/src-edge`.

`HB_PORT=19206 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2`
passed all 40 tests.

`make buildroot JOBS=18` completed.

No-TME image:

```text
path: build/images/lapee-usb-no-tme.img
size: 247463936 bytes
sha256: d76583d38b542d75690b6bb4bf152581f0db8e2b2c02538e94b7e832f504a51c
```

QEMU ring test:

```text
TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
  --img build/images/lapee-usb-no-tme.img \
  --timeout 600

result: PASSED
ring-address: NVnjXChhW0qZWiMOyKtOct0gs5RvjzCz7eVw_gPkyOc
```

Standard TME image:

```text
path: build/images/lapee-usb.img
size: 247463936 bytes
sha256: 76c73fb2a5b2d1d245389b47c1403e7a5b07563d21893ed5731210ccde83ac27
```

No QEMU or swtpm processes owned by this validation run remain. The only
matching process was the pre-existing `work/qemu-hyperbuddy-test` swtpm, which
was left untouched.

## Model Notes

`~tpm@2.0a` owns boot attestation, AK/EK verification, peer verification, and
credential activation. Peer attestations are signed statements over another
node's boot attestation plus the observed peer URL.

`~green-zone@1.0` owns named rings. A ring is initialized from a template, the
initializer must satisfy the same template as later joiners, and accepted nodes
receive the ring wallet only after TPM peer verification and template matching.
The ring signs a stable authorization object over scalar admission fields and
stable payload IDs rather than the mutable transport envelope.

## Recent Cleanup

The unattended cleanup pass has been committing only net-negative source
changes. Recent examples:

- Trimmed TPM platform-probe parsing.
- Inlined green-zone template loading.
- Removed TPM peer helper indirection.
- Shared TPM nonce decoding.
- Removed stale TPM signing and AK signing stubs.
- Shared green-zone authorization and field checks.

Latest local cleanup before the next commit: simplified TPM trust-anchor source
reporting by removing an unused opts argument and collapsing the two clauses
into one expression.

## Open Threads

Keep sharpening toward smaller, more idiomatic HyperBEAM device code while
preserving the four-node QEMU acceptance gate.

Do not track `AK_PCR_POLICY_ISSUE.md`; it is a local prompt artifact.
