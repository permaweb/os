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

`HB_PORT=19207 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_system`
passed both focused system-device tests.

`make buildroot JOBS=18` completed.

No-TME image:

```text
path: build/images/lapee-usb-no-tme.img
size: 247463936 bytes
sha256: 89875273b48f5ff0daccb8f1a9e3939a2c1d6a3f207b1218f9c3f7a1ece0bdec
```

QEMU ring test:

```text
TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
  --img build/images/lapee-usb-no-tme.img \
  --timeout 600

result: PASSED
ring-address: khbcYXRrDskKBWMs3uWlL3i2ezCtIkyeyUi5kwQQIj4
```

Standard TME image:

```text
path: build/images/lapee-usb.img
size: 247463936 bytes
sha256: 4c5b4f418d60becfc65c20d795578c0824a1d349487070c2144b347f0cbfbb57
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

Latest local cleanup before the next commit: shared `~system@1.0` fixed-width
pread handling across MMIO, MSR, and CPUID probes.

## Open Threads

Keep sharpening toward smaller, more idiomatic HyperBEAM device code while
preserving the four-node QEMU acceptance gate.

Do not track `AK_PCR_POLICY_ISSUE.md`; it is a local prompt artifact.
