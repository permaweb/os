# LapEE Green-Zone Peer Verification Overnight Pass

## Update 44

Made AK PCR-policy binding clearer in the native TPM template: the AK public
template now initializes `authPolicy` with the computed PolicyPCR digest
directly instead of initializing it empty and assigning the digest one statement
later. This is behavior-preserving but removes the last misleading
empty-AK-policy line.

Validation evidence: `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`edc91453f558005f8bbba2be215b92b4a85570317cb637441781f9570d9f2b9a`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`6MvIDO8FbtJzdOf_3LdRGN0YPYdH79oVooJfiYMYX-g`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`20a012eee84bde73ba4a8d3995d11d10f9f9a9360eb03b17d4abd6dee36d32ca`.

## Update 43

Removed the stale `lapee_tpm_nif:sign/2` Erlang export and stub. The native AK
signing NIF was already removed, so leaving the wrapper export only advertised
a dead raw signing surface that would fail if called.

Validation evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19199 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2`
passed all 40 tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`53f7c2080d4f3a31ef5901d20d3b6b0f12c15b827525dfdeaab13161253ce1fc`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`4AOkSECTVq-zXqll0NShWIsWyvYJZV7HVSLSqzQK3m8`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`d7bb5a09d5fd37e3cb9b3636e29caa086d8ad3789931d89bb574d99d45c90c8d`.

## Update 42

Collapsed duplicate `~green-zone@1.0` admission and peer-attestation field
validators into one shared helper, reducing the device by 11 Erlang lines
without changing the public protocol. The helper still routes each failure to
the existing admission/peer error constructors, so API error shapes remain
unchanged.

Validation evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19197 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
passed all 15 tests; `HB_PORT=19198 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit
--module=dev_tpm2` passed all 40 tests; `make buildroot JOBS=18`; no-TME
image `build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`f60944aff076e76a3155a3b759842687d9b3666d3b7cb51e57683367a58b47ad`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`l3eugmrxUYn4ntFObfE5hjTy0Ylrf0gRquDFoZeTtEk`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`6e6b577460ad1c914ac5d33d18f84ac1f5334df607da2f96178719bec52f01b8`.

## Update 41

Trimmed `~tpm@2.0a` verifier exception details so malformed remote
attestation fields still fail the relevant check without returning Erlang
class/reason/stack traces as public API data. The device keeps the per-check
failure shape and now reports `detail=exception` for unexpected verifier
exceptions.

Validation evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19196 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2`
passed all 40 tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`82f3fefcbc58856b911e2974889622b8b5edd11410f34379a5e80562692766ef`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`bjeV090tG9UPJNmxqEan_mbM1CZz8a2LkcNQn9asyaQ`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`86c3db8b924884ab6021809ecbe709559ff0c7157910da9b03cec5568d96afaa`.

## Update 40

Sorted unsigned commitment IDs before selecting the stable nested payload ID
for green-zone admission authorization, removing a latent dependency on map
iteration order. Also collapsed two duplicate error branches. Validation
evidence: staged overlay into `build/hyperbeam/src-edge`; `HB_PORT=19195
LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone` passed all 15
tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`98928693368b26c9150cbcfa63fa238886d3c98fd014919748a8eadb806c7793`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`abcXi_SuM6rZK4XDtfxJ8eBKhEhiDXZoXEHR0uUsoDo`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`5a90f9a7207e706fac0407748cd33d7b04c0dbcb43817257c280b23e52cba7d7`.

## Update 39

Same-TPM stale-boot check passed against the pushed AK/PCR policy fix: one
swtpm state reported prod no-TME AK name
`AAv4-Et0X3CzCwr3YTyMKPhgcfix56pDYW5H_Zip_Q6Ntw`, then no-TME debug AK name
`AAsFJiS6pFHGnJTLGtEebP1K8JtjIvgsOFqdZDAaYooleQ`. Also trimmed unexpected
green-zone internal error payloads so class/reason dumps are not part of the
public device surface. Validation evidence: staged overlay into
`build/hyperbeam/src-edge`; `HB_PORT=19194 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3
eunit --module=dev_green_zone` passed all 15 tests; `make buildroot JOBS=18`;
no-TME image `build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`c9e9b4c1a544c56eda59d6cd80fd680c7b475d8729c56e91ca310d91a52a61a1`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`1V_brTOjGy7MKhf1vAHqP8AZ8fiC6pEbKUfjfd95QM8`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`42f7b0906e3beb99aed0ff49201c8afe7a5caa613897b857f57059b27faeff68`.

## Update 38

Removed the unused native `sign/2` TPM NIF export, leaving quote and
credential-activation as the only AK operations exposed by the LapEE TPM
device. I tested and rejected a smaller pure-`PolicyPCR` AK policy because the
full QEMU cluster showed `ActivateCredential` returning an invalid activation
response; the dual PCR-or-ActivateCredential policy is intentionally retained.
Validation evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19193 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2`
passed all 40 tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`e53184c17efe565ad47730a2f3a262af85884ee74d2c3ca3174c18acfadc14c4`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`IUvtBb4aHJhUWhydrqgZiHwLjoWpBRA90o_MxB7vDGE`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`376ba3cb9abcb70046c86a370cc5dc7c8c51fc73bc0bf308c91a3a40c47b3226`.

## Update 37

Collapsed green-zone admission authorization field definitions so the signer
and verifier share the same scalar/payload field lists, and removed a dead
admission-validity argument plus dead template sanitizer branch. Validation
evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19189 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
passed all 15 tests; `HB_PORT=19190 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit
--module=dev_tpm2` passed all 40 tests; after the final dead-argument cleanup
`HB_PORT=19191 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
passed all 15 tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`06313373d1e8d7031d55eaf4b75dc464931fbcec3c07da9e6358014fb00dd7cb`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`pl7S3EOuZAh9Rp37TOuDBggG204Ejv3ArhFvhj1PrOk`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`1d00d605346482dbae3daf352cbde2ec29cf2bd951d77108d4f9deb4fcbbf519`.

## Update 36

Removed the unused `green-zone-last-admission` server option written after
join. Validation evidence: staged overlay into `build/hyperbeam/src-edge`;
`HB_PORT=19188 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
passed all 15 tests; `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`4592f73125406bba4dbb77d77e541f47997a9bd8a7035c4e94c62b1d51f98a39`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`IqoWeY2RMtT3i17gsW4FnO3mCKenrvMuvXIjH0AzBFM`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`1ea70b672dd416ab27374390c0303317b538202bb5b4c7bf4897b077e9b16287`.

## Update 35

Full appliance validation passed for the corrected transport-stable
green-zone authorization. Evidence: `make buildroot JOBS=18`; no-TME image
`build/images/lapee-usb-no-tme.img` 247463936 bytes, SHA-256
`0a436bb3a61d5f63268dc88ba4aeaaf7629d14037210fe9754c725d628ff6610`;
`TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img
build/images/lapee-usb-no-tme.img --timeout 600` passed with ring
`s31LvSS5pYGOmNpz8nsxsdrvXLA01TeGU-eF0Gx8DzA`; standard TME image
`build/images/lapee-usb.img` 247463936 bytes, SHA-256
`329a8907a2e6e0cb1b285865a9d3e65d88300c1b7fcc73a2cfe1f122424fe9a4`.

## Update 34

QEMU found boolean `template-matched` transport-unstable for signed
authorization: it arrived as `"true"` and invalidated the ring signature.
Restored the stable binary string in the authorization and removed the duplicate
top-level boolean. Evidence: `HB_PORT=19187
LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone` passed 15/15.

## Update 33

Removed redundant admission name argument/checks from green-zone join
validation. Evidence: `HB_PORT=19183 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit
--module=dev_green_zone` passed 15/15.

## Update 32

Deduplicated TPM quote envelope construction across `/quote`,
boot-attestation, and live-attestation paths. Evidence:
`HB_PORT=19179 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit
--module=dev_tpm2` passed 40/40 with exit 0.

## Update 31

TPM HMAC/parameter-encryption session setup now fails closed instead of falling
back to unauthenticated/no-encryption session handles for EK/AK creation, quote,
and ActivateCredential. Evidence: `make buildroot JOBS=18`; no-TME image
247463936 bytes; QEMU cluster PASSED, ring
`vzZNgvh_iTRjrV7xLbsTAWgC72OktdrcSKDsXEgsr0Y`.

## Update 30

Removed stale internal peer-attestation cache-path docs from `~tpm@2.0a/info`.
Evidence: `HB_PORT=19149 LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit
--module=dev_tpm2` passed 40/40 with exit 0.

## Update 29

Removed the stale machine-local macOS TPM simulator library path; dev defaults
to `swtpm`, while appliance init still supplies `device:/dev/tpm0`. Evidence:
`dev_tpm2` 40/40; `make buildroot JOBS=18`; no-TME image 247463936 bytes;
QEMU cluster PASSED, ring `oRzwW03JJaBKbj5-dvReziJ-eMsXyQsxtMswTmx8ly4`.

## Update 28

Removed public stacktrace fields from unexpected green-zone/TPM error envelopes
and one duplicate assertion. Evidence at `2026-05-02T23:17:22Z`: 55/55
`dev_green_zone,dev_tpm2` tests; `make buildroot JOBS=18`; no-TME image
247463936 bytes; QEMU cluster PASSED, ring `sNhILfkrHSqZdzuI1ZFg5u-CPcWEYWl2ZswTYLBTQtI`.

## Update 27

Trimmed a duplicate green-zone test helper and made `~system@1.0` reuse one
Boot Guard, EDAC, and memory-controller snapshot per report. Evidence at
`2026-05-02T23:06:03Z`:

```text
dev_system: All 2 tests passed.
dev_green_zone: All 15 tests passed.
make buildroot JOBS=18: initramfs-lapee.cpio.zst, vmlinuz-lapee
make hb-usb-no-tme-image WIFI=0 JOBS=18: 247463936-byte image
qemu-green-zone-cluster: PASSED, ring jDQYzz0yXA1Zr8QoMmZKJdygHi0iLD0s4iViWwhU0KI
```

## Update 26

Removed one-use `~green-zone@1.0` member/admission wrappers.
Validation: `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone`
passed all 16 tests.

## Update 25

Trimmed unused `~tpm-interpret@1.0` compatibility wrappers and a stale debug
binding. Public device exports are unchanged.

Validation:

```text
$ cd build/hyperbeam/src-edge && LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm_interpret
All 117 tests passed.
$ make buildroot JOBS=18
artefacts: initramfs-lapee.cpio.zst, vmlinuz-lapee
```

## Update 24

Removed the legacy raw-PEM trust-anchor request path from TPM
verification, peer interpretation, and green-zone admission. The only inline
trust-anchor shape is now HyperBEAM's base64url `trusted-ca`; malformed inline
anchors fail closed instead of falling through to node config. The appliance
device table now exposes only canonical `tpm@2.0a` and `green-zone@1.0`
device names, and interpret docs/tests use the same names.

Validation:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
$ cd build/hyperbeam/src-edge && LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2
All 39 tests passed.
$ cd build/hyperbeam/src-edge && LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm_interpret
All 117 tests passed.
$ cd build/hyperbeam/src-edge && LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone
All 16 tests passed.
$ make buildroot JOBS=18
artefacts: initramfs-lapee.cpio.zst, vmlinuz-lapee
$ make hb-usb-no-tme-image WIFI=0
build/images/lapee-usb-no-tme.img: 247463936 bytes
$ ./scripts/boot-usb-image.sh --img build/images/lapee-usb-no-tme.img --timeout 420
=== QEMU boot test PASSED ===
$ ./scripts/interpret-local-capture.sh build/qemu-network-test/boot-attestation.json --label qemu-trust-anchor-cleanup
verdict = untrusted (score 4)
$ TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh --img build/images/lapee-usb-no-tme.img --timeout 600
=== green-zone QEMU cluster PASSED ===
ring-address: BW4l9iLxUVkaJiAvagB0JF4QPaCh57Hbvj4zSTqPjCc
```

## Update 23

Trimmed green-zone request parsing: removed unused aliases and replaced the
policy-attestation wrapper with the direct boot-attestation helper. Validation:
`dev_green_zone` EUnit, `make buildroot JOBS=18`, no-TME image generation, and
the four-node QEMU green-zone gate all passed.

## Update 22

Trimmed the AK policy envelope after the correctness fix:

- Removed reported `ak-policy-digest` / `ak-policy-pcrs` fields from the
  public TPM messages and NIF cache. They duplicated data already committed
  by the TPM `TPMT_PUBLIC.authPolicy`.
- `~tpm@2.0a/verify` now derives the AK policy solely from `ak-public`, the
  locally expected LapEE AK PCR set, and the quoted PCR values.
- Removed stale native comments from the old pre-credential-activation AK
  implementation.

Validation after trimming:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
$ cd build/hyperbeam/src-edge && rebar3 eunit --module=dev_tpm2
All 39 tests passed.

$ make buildroot JOBS=18
artefacts: initramfs-lapee.cpio.zst, vmlinuz-lapee

$ make hb-usb-no-tme-image WIFI=0
build/images/lapee-usb-no-tme.img: 247463936 bytes

$ ./scripts/boot-usb-image.sh --img build/images/lapee-usb-no-tme.img --timeout 420
=== QEMU boot test PASSED ===

$ jq -r '.body | [has("ak-policy-digest"), has("ak-policy-pcrs"),
    (.tpm | has("ak-policy-digest")), (.tpm | has("ak-policy-pcrs"))] | @tsv' \
    build/qemu-network-test/boot-attestation.json
false   false   false   false

$ ./scripts/interpret-local-capture.sh \
    build/qemu-network-test/boot-attestation.json \
    --label qemu-trimmed-ak-policy
verdict = untrusted (score 4)

$ TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
    --img build/images/lapee-usb-no-tme.img --timeout 600
=== green-zone QEMU cluster PASSED ===
```

## Update 21

Implemented and verified the AK/PCR policy fix from
`AK_PCR_POLICY_ISSUE.md`.

- The AK is no longer authorized by empty password auth. It is created with a
  non-empty `authPolicy` under `ADMINWITHPOLICY`.
- The AK policy is a TPM `PolicyOR` over two branches:
  1. `PolicyPCR([0,1,7,10,11,14])` for quote/sign operations.
  2. `PolicyPCR([0,1,7,10,11,14])` plus
     `PolicyCommandCode(ActivateCredential)` for credential activation.
- PCR15 remains excluded from AK creation policy because LapEE extends PCR15
  later with runtime node/subject evidence.
- `~tpm@2.0a/verify` now rejects empty AK policies, mismatched reported
  policy digests, wrong policy PCR sets, and AK policies that cannot be
  recomputed from the quoted PCRs.

Validation:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge && rebar3 eunit --module=dev_tpm2
All 39 tests passed.

$ make buildroot JOBS=18 && make hb-usb-no-tme-image WIFI=0
build/images/lapee-usb-no-tme.img: 247463936 bytes

$ ./scripts/boot-usb-image.sh --img build/images/lapee-usb-no-tme.img --timeout 420
>> HB /info answered on http://127.0.0.1:18734
>> fetching boot attestation
>> fetching system report
=== QEMU boot test PASSED ===

$ python3 /tmp/check-ak-policy-or.py
AK policy PCRs [0, 1, 7, 10, 11, 14]
authPolicy bytes 32
authPolicy == reported True
authPolicy == recomputed PCR/PCR+ActivateCredential PolicyOR True

$ ./scripts/interpret-local-capture.sh \
    build/qemu-network-test/boot-attestation.json \
    --label qemu-ak-policy-or
verdict = untrusted (score 4)
criticals=2 warnings=2
```

The QEMU verdict is expected for swtpm/OVMF, but the analyzer completed and
the failure is not the AK/PCR policy.

Four-node green-zone acceptance gate:

```text
$ TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
    --img build/images/lapee-usb-no-tme.img --timeout 600
>> node 1 initialized green-zone R0nd-auQLeIUFKKfMZacmIGN8pwQB1cUt-Htr09csbo
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone R0nd-auQLeIUFKKfMZacmIGN8pwQB1cUt-Htr09csbo
>> node 2 signed as green-zone R0nd-auQLeIUFKKfMZacmIGN8pwQB1cUt-Htr09csbo
>> node 3 signed as green-zone R0nd-auQLeIUFKKfMZacmIGN8pwQB1cUt-Htr09csbo

=== green-zone QEMU cluster PASSED ===
```

## Update 20

Resumed in unattended mode after the real-hardware `.207` / `.210` retry.

- Pushed `20fe561 Fix TPM EK chain validation for peer admission` to
  `origin/feat/ak-ek-trust`.
- Confirmed the live no-TME image can fetch both boot attestations and that
  both nodes report the same PCR11 / kernel cmdline. Both also expose
  `secure-boot-measured=true` when `~tpm-interpret@1.0/summary` is run over
  the boot-attestation envelope, although the current green-zone template
  surface still matches the raw boot-attestation body rather than derived
  interpret claims.
- The real-hardware join now passes the previous EK-chain blocker and reaches
  admission validation. It currently fails on `validity` because one laptop's
  hardware clock is badly skewed. I am leaving the clock check intact; for
  testing, use a deliberately large `green-zone-clock-skew-seconds` configured
  in node opts or fix the hardware RTC before retrying.
- Read `AK_PCR_POLICY_ISSUE.md`. Current priority is binding the deterministic
  AK to measured boot state by putting a TPM PolicyPCR digest into the AK
  public template and using a live PolicyPCR session for AK operations.

Implementation direction for the AK/PCR fix:

1. Keep the existing EK/AK credential-activation protocol shape.
2. Add minimal native helpers for:
   - building the security PCR selection,
   - computing a trial-session PolicyPCR digest,
   - starting a live PolicyPCR session for AK authorization.
3. Create the AK without `USERWITHAUTH` and with `authPolicy =
   PolicyPCR(current security PCRs)`.
4. Authorize `Quote` and `ActivateCredential` with the live PolicyPCR session,
   not password auth.
5. Do not weaken admission freshness or clock policy while doing this.

## Update 19

Reworked `~green-zone@1.0` around named ring definitions rather than one
implicit singleton ring:

- `init`, `join`, `admit`, and `sign` now require a green-zone `name`.
- A node can hold multiple zones at once. Public definitions live under the
  node-message-visible `green-zones` key, keyed by name. Private AES/wallet
  material lives separately under `priv-green-zones`.
- The initializer no longer supplies a wallet or AES key. `init` rejects
  caller-provided secret material and mints both inside the matching node.
- `init` now checks the initializer's own boot attestation against the
  template before creating the ring wallet.
- Green-zone-local `trusted-publishers` state was removed. Reusable or
  transitive peer-attestation publisher trust is a TPM-device concern, not a
  ring-definition concern.
- Green-zone templates now use `hb_message:match(..., primary, Opts)` and the
  standard `_` wildcard. JSON callers can send `"_"`, which is normalized to
  the Erlang wildcard atom.
- Public green-zone definitions include a lightweight `members` map keyed by
  node address with known URLs for nodes admitted into the ring.

Validation:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 16 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 37 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.

$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
$ git diff --check
```

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
  activation, then signs a `green-zone-peer-attestation` message.

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
- Added the `green-zone@1.0` device alias.

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

## Update 6

Added the first four-node QEMU/swtpm green-zone acceptance harness. It boots
three nodes from the same no-TME image plus one intentionally different image,
manufactures local EK certificates for each swtpm, initializes a ring on node
1, admits nodes 2 and 3 through credential activation, rejects node 4 via the
deep boot-attestation template, and checks that the accepted nodes can sign as
the same ring wallet.

The first run exposed a harness issue before any LapEE code executed:
`swtpm_setup` requires its TPM state directory to exist ahead of provisioning.
Fixed that and made local swtpm config pathing/cleanup less brittle. The
multi-node run is now the active validation gate.

## Update 7

The harness now boots all four QEMU nodes and reaches green-zone join
requests. Two peer-call issues surfaced in sequence:

- Default outbound peer calls used HyperBEAM's default HTTP/2-oriented client
  path, which closed against the local QEMU peers.
- Forcing `httpc` fixed the protocol direction but caused the minimal rootfs
  to raise `pubkey_os_cacerts:no_cacerts_found`.

The code now forces peer-verification/admission traffic through `gun` with
`http1`. That keeps the protocol explicit without requiring an OS CA bundle
for local HTTP peers. Rebuilding the appliance image again before rerunning the
four-node acceptance harness.

## Update 8

Focused tests pass against the staged HyperBEAM checkout after the peer-call
changes:

- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2` passes 26 tests.
- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone` passes 3
  tests.

The first direct QEMU admission preflight then exposed the expected next hard
edge: swtpm manufactures EK certs with an intermediate local CA, so trusting
only `issuercert.pem` is not sufficient. The verifier now treats inline CA
anchors as PEM bundles, tries each certificate as a trust anchor, and uses the
remaining bundle entries plus the peer-presented chain as intermediate
candidates. The cluster harness now supplies the swtpm issuer +
root bundle via base64url `trusted-ca`.

Also replaced a brittle `true = Verified` peer-verification assertion with an
explicit verifier-error return so future rejected peers carry their failed
checks instead of collapsing into `{badmatch,false}`.

Target Buildroot rebuild is running now so the QEMU image contains the latest
verifier changes.

## Update 9

Second peer-review pass found three real protocol/harness blockers and one
missing negative assertion. Fixed all four:

- `~tpm@2.0a` boot-attestation normalization now keeps the
  `tpm.extended-subject` ID as `node-message-id`. The previous code
  recomputed an ID over the nested `node` message only, while PCR 15 was
  extended with the ID of the full `#{system,node}` subject. That would reject
  otherwise-valid peers before green-zone admission.
- Added a regression test:
  `normalise_boot_attestation_uses_extended_subject_test`.
- The QEMU green-zone template now expects the emitted EK-cert provenance
  `tpm.ek-cert-source.kind = "tpm-nv"` instead of the nonexistent
  `"nv-index"`.
- The harness now checks the actual admission shape
  `body.credential.credential-blob`, and it actively attempts node 4 signing
  after the rejected join to prove the inadmissible node does not have the
  green-zone wallet.
- The harness cleanup and swtpm launch path now report early swtpm failures
  instead of exiting silently under `set -u` / `set -e`.

Validation evidence at `2026-05-02 03:20:56 EDT`:

- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile` passes in
  `build/hyperbeam/src-edge`.
- Direct EUnit without starting the HTTP listener:
  `LAPEE_TPM_ALLOW_NO_NIF=1 erl -noshell -pa _build/test/lib/*/ebin -pa _build/default/lib/*/ebin -eval 'case eunit:test(dev_tpm2, [verbose]) of ok -> halt(0); error -> halt(1) end.'`
  passes 27/27 tests.
- Direct EUnit without starting the HTTP listener:
  `LAPEE_TPM_ALLOW_NO_NIF=1 erl -noshell -pa _build/test/lib/*/ebin -pa _build/default/lib/*/ebin -eval 'case eunit:test(dev_green_zone, [verbose]) of ok -> halt(0); error -> halt(1) end.'`
  passes 3/3 tests.
- `bash -n scripts/qemu-green-zone-cluster.sh` passes.

Environment blockers in this Codex desktop sandbox:

- `make buildroot JOBS=18` cannot connect to Docker:
  `permission denied while trying to connect to the docker API at unix:///Users/sam/.docker/run/docker.sock`.
- HyperBEAM's normal `rebar3 eunit --module=...` app-start path cannot bind
  Ranch on port 8734 here: `listen_error ... eperm`.
- The four-node QEMU harness cannot start swtpm here:
  `!! swtpm failed for node 1` /
  `Could not open UnixIO socket: Operation not permitted`.

The code and harness are now ready for the full acceptance run in an
environment that allows Docker and local listener sockets.

## Update 10

Second unattended pass tightened the current branch in three places:

- `~tpm@2.0a/verify-peer` now stores the unwrapped boot-attestation body in
  the signed `green-zone-peer-attestation`. This keeps later green-zone template
  matching aligned with the `system`/`tpm` shape produced by the verifier and
  by the QEMU harness.
- Green-zone admission now supports the intended reusable peer-attestation
  path. `admit` accepts either a live `joiner-url` or a supplied signed
  `peer-attestation`; supplied attestations are only reused when their
  HyperBEAM commitment verifies and at least one signer is explicitly listed
  in `trusted-publisher`, `trusted-publishers`, or green-zone opts. The
  attestation must also carry `verification.verified = true`,
  `credential-activation.verified = true`, a peer boot-attestation, and a
  credential subject.
- The peer HTTP path now uses the LapEE-owned minimal HTTP/1.1 JSON client for
  plain local peer calls. It preserves structured device-level HTTP errors so
  a remote `template-mismatch` is not collapsed into an opaque transport
  failure.

Harness/docs updates:

- `scripts/qemu-green-zone-cluster.sh` now prints git/image/QEMU/swtpm
  provenance at start.
- Node 1 initialization must now prove a non-empty ring address before
  admission proceeds.
- Node 4 rejection must now be the expected structured
  `status = 400`, `body.error = "template-mismatch"`, and node 4 status must
  remain uninitialized without the ring address before the negative signing
  check runs.
- Added `make qemu-green-zone-cluster` and README coverage for the four-node
  green-zone gate.

Validation evidence at `2026-05-02 04:24:12 EDT`:

- Staged overlay into `build/hyperbeam/src-edge`.
- `LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile` passes in
  `build/hyperbeam/src-edge`.
- Direct EUnit without starting the HTTP listener:
  `LAPEE_TPM_ALLOW_NO_NIF=1 erl -noshell -pa _build/test/lib/*/ebin -pa _build/default/lib/*/ebin -eval 'case eunit:test(dev_green_zone, [verbose]) of ok -> halt(0); error -> halt(1) end.'`
  passes 6/6 tests.
- Direct EUnit without starting the HTTP listener:
  `LAPEE_TPM_ALLOW_NO_NIF=1 erl -noshell -pa _build/test/lib/*/ebin -pa _build/default/lib/*/ebin -eval 'case eunit:test(dev_tpm2, [verbose]) of ok -> halt(0); error -> halt(1) end.'`
  passes 28/28 tests.
- Direct EUnit without starting the HTTP listener:
  `LAPEE_TPM_ALLOW_NO_NIF=1 erl -noshell -pa _build/test/lib/*/ebin -pa _build/default/lib/*/ebin -eval 'case eunit:test(lapee_http_json, [verbose]) of ok -> halt(0); error -> halt(1) end.'`
  passes 2/2 tests.
- `bash -n scripts/qemu-green-zone-cluster.sh` passes.
- `PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache python3 -m py_compile scripts/qemu-green-zone-requests.py`
  passes.
- `git diff --check` passes.

Earlier environment blockers, superseded by Update 11:

- An earlier `make buildroot JOBS=18` attempt could not connect to Docker:
  `permission denied while trying to connect to the docker API at unix:///Users/sam/.docker/run/docker.sock`.
- An earlier four-node QEMU harness attempt failed before node boot because `swtpm`
  cannot create its UnixIO socket here:
  `!! swtpm failed for node 1` /
  `Could not open UnixIO socket: Operation not permitted`.

## Update 11

The four-node TPM-backed green-zone acceptance gate now passes end-to-end in
this environment.

Fixes made in this checkpoint:

- `TPM2_MakeCredential` now loads the peer EK as a public-only external object
  with `inPrivate = NULL` and `TPM_RH_NULL`. Passing an empty sensitive area
  caused swtpm/ESYS to reject the peer EK load with
  `Esys_LoadExternal(peer EK public): 0x0009000b`.
- Green-zone templates are now canonicalized before storage/matching by
  removing AO envelope metadata keys (`commitments`, `ao-types`) recursively.
  Response commitments are transport/provenance metadata, not ring policy.
- Template rejection responses include `mismatch-path`, which made the
  inadmissible QEMU node's rejection externally inspectable as
  `/system/kernel/cmdline`.
- The local HTTP JSON client now uses configurable long receive timeouts
  (`peer-http-timeout-ms`, default 120s) so TPM-heavy peer admission does not
  fail during legitimate MakeCredential/ActivateCredential work.
- The QEMU harness now checks for the ring wallet address as a HyperBEAM
  commitment `committer`, including nested signed-message response shapes.

Acceptance evidence at `2026-05-02 05:01 EDT`:

```text
$ rm -f build/images/lapee-usb-no-tme.img \
    build/images/lapee-usb-no-tme-bad-ring.img
$ bash scripts/qemu-green-zone-cluster.sh --timeout 600
>> node 1 ready
>> node 2 ready
>> node 3 ready
>> node 4 ready
>> node 1 initialized green-zone 2mSXuqxRI3m6WmRANgtw3vOku28Yns2FfMGX3Vi3j28
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone 2mSXuqxRI3m6WmRANgtw3vOku28Yns2FfMGX3Vi3j28
>> node 2 signed as green-zone 2mSXuqxRI3m6WmRANgtw3vOku28Yns2FfMGX3Vi3j28
>> node 3 signed as green-zone 2mSXuqxRI3m6WmRANgtw3vOku28Yns2FfMGX3Vi3j28

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: 2mSXuqxRI3m6WmRANgtw3vOku28Yns2FfMGX3Vi3j28
```

Focused verification after the acceptance run:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 8 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 28 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
```

## Update 12

Extended the QEMU acceptance harness to cover the commander's-intent
stored-attestation flow, not just live admission:

1. Node 1 calls `~tpm@2.0a/verify-peer` for node 2.
2. Node 1 receives a signed `green-zone-peer-attestation` whose verification and
   credential-activation checks are true.
3. The harness submits that signed peer attestation back to
   `~green-zone@1.0/admit` with node 1's address as `trusted-publisher`.
4. Green-zone admission reuses the signed artifact and still returns the
   ring credential/wallet payload.
5. The original four-node gate then continues: nodes 2 and 3 join live,
   node 4 is rejected, and only nodes 1-3 can sign as the ring wallet.

Evidence at `2026-05-02 05:14 EDT`:

```text
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
$ bash scripts/qemu-green-zone-cluster.sh --timeout 600
>> node 1 ready
>> node 2 ready
>> node 3 ready
>> node 4 ready
>> node 1 initialized green-zone cWc8haLTOJLiL9ZTBVzSDkdP3j3CUs9Be_Nb7N_JGbM
>> node 1 can reuse its signed peer attestation for node 2
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone cWc8haLTOJLiL9ZTBVzSDkdP3j3CUs9Be_Nb7N_JGbM
>> node 2 signed as green-zone cWc8haLTOJLiL9ZTBVzSDkdP3j3CUs9Be_Nb7N_JGbM
>> node 3 signed as green-zone cWc8haLTOJLiL9ZTBVzSDkdP3j3CUs9Be_Nb7N_JGbM

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: cWc8haLTOJLiL9ZTBVzSDkdP3j3CUs9Be_Nb7N_JGbM
```

## Update 13

Tightened stored peer-attestation trust so it is ring policy, not request
policy:

- `~green-zone@1.0/init` now stores `trusted-publishers` in the ring state.
- Stored peer attestations are accepted only when one of their verified
  signers is in the ring's configured publisher allow-list.
- `admit` returns that allow-list and `join` carries it into newly admitted
  members, keeping future reusable-attestation admissions on the same ring
  policy.
- The QEMU request generator configures node 1 as the trusted publisher at
  ring initialization. The harness no longer sends `trusted-publisher` with
  the reusable attestation admission request.
- The harness now asserts all generated request JSON files exist before it
  starts mutating node state, so generator failures stop at the source.
- Added a regression test proving a caller cannot make an otherwise untrusted
  stored attestation admissible by supplying `trusted-publisher` in the request.

Validation evidence at `2026-05-02 05:19 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 9 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 28 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ make buildroot JOBS=18
=== artefacts ===
-rw-r--r--@ ... 192M ... build/initramfs/initramfs-lapee.cpio.zst
-rw-r--r--@ ...  20M ... build/kernel/vmlinuz-lapee

$ rm -f build/images/lapee-usb-no-tme.img \
    build/images/lapee-usb-no-tme-bad-ring.img

$ bash scripts/qemu-green-zone-cluster.sh --timeout 600
>> building admissible no-TME image: build/images/lapee-usb-no-tme.img
>> building inadmissible no-TME image: build/images/lapee-usb-no-tme-bad-ring.img
>> node 1 ready
>> node 2 ready
>> node 3 ready
>> node 4 ready
>> node 1 initialized green-zone x70az3U-VE6gei0nj1gO-0eMR4BNQqF4AJAh3Tjq2sA
>> node 1 can reuse its signed peer attestation for node 2
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone x70az3U-VE6gei0nj1gO-0eMR4BNQqF4AJAh3Tjq2sA
>> node 2 signed as green-zone x70az3U-VE6gei0nj1gO-0eMR4BNQqF4AJAh3Tjq2sA
>> node 3 signed as green-zone x70az3U-VE6gei0nj1gO-0eMR4BNQqF4AJAh3Tjq2sA

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: x70az3U-VE6gei0nj1gO-0eMR4BNQqF4AJAh3Tjq2sA

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
```

## Update 14

Tightened the join/admission boundary after re-reading the current
green-zone protocol surface:

- Stored `green-zone-peer-attestation` reuse now binds the request to the URL that
  was actually attested. A caller cannot relabel a signed attestation for
  `peer-url = A` as an admission request for `joiner-url = B`.
- `~green-zone@1.0/join` now validates the admission envelope before using
  it: expected protocol type, `template-matched = true`, joiner URL, peer
  attestation, credential, encrypted wallet, and non-empty ring address.
- After decrypting the furnished wallet, join verifies that the wallet's
  address equals the admission's advertised `ring-address` before installing
  it as the local `green-zone` identity.
- `~green-zone@1.0/sign` now returns structured
  `green-zone-not-initialized` instead of a generic 500 when a node has not
  joined the ring.
- The QEMU acceptance harness now asserts node 4's negative sign path returns
  `status = 400`, `body.error = "green-zone-not-initialized"` before checking
  that no green-zone commitment exists.

Validation evidence at `2026-05-02 06:20 EDT`:

```text
$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py

$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 13 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 28 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0
```

Target rebuild/QEMU rerun for this increment is blocked in this Codex macOS
sandbox:

```text
$ make buildroot JOBS=18
permission denied while trying to connect to the docker API at
unix:///Users/sam/.docker/run/docker.sock

$ make native-build
native-build requires a Linux host (Buildroot doesn't run on Darwin).
```

The last full target acceptance gate remains the Update 13 run above. This
increment is staged and host-validated, but the appliance images in
`build/images` are still from `2026-05-02 05:14 EDT` and do not contain Update
14 until Buildroot can run again.

## Update 15

Closed a protocol gap in `~tpm@2.0a/verify-peer`: the endpoint now does not
only return a signed `green-zone-peer-attestation`; it writes that signed artifact
to the local HyperBEAM cache and links it under deterministic public paths:

- `~tpm@2.0a/peer-attestations/by-id/<signed-message-id>`
- `~tpm@2.0a/peer-attestations/latest-by-peer-url-sha256/<base64url-sha256-url>`

That keeps the artifact itself simple and self-verifying while making the
publisher's latest attestation for a peer discoverable by a stable path.

Validation evidence at `2026-05-02 06:24 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 29 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 13 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
```

Target rebuild/QEMU rerun for this increment remains blocked by the same local
Docker/native-Buildroot constraints recorded in Update 14.

## Update 16

Re-read the peer verification and green-zone admission boundary with two
sidecar reviews. One review found a real oracle bug:

- Before this pass, `~green-zone@1.0/admit` returned a credential wrapping the
  ring AES key to the joiner's TPM and also returned the wallet encrypted under
  that AES key. Because `~tpm@2.0a/activate-credential` was public and returned
  the recovered secret, a third party could request admission for an honest
  peer, ask that peer's public activation endpoint to unwrap the credential,
  and decrypt the ring wallet.

Fixes in this increment:

- `~tpm@2.0a/activate-credential` no longer exports the recovered secret over
  HTTP. It returns `credential-secret-sha256` plus an `HMAC-SHA256` proof over
  the MakeCredential transcript. `verify-peer` now verifies that proof against
  its verifier-chosen challenge.
- `~green-zone@1.0/join` still recovers the ring AES key, but only through the
  local Erlang API `dev_tpm2:activate_credential_secret/2`; that function is
  not a HyperBEAM device export.
- EK certificate binding now checks the actual TPMT_PUBLIC bytes used by
  MakeCredential. The RSA public key parsed from `ek-public`, the `ek-pub-pem`,
  and the EK certificate public key must all match.
- Quote verification now checks TPMS_ATTEST `qualifiedSigner` against the
  attested AK qualified name instead of discarding it after parsing.
- Added focused regression tests for public activation proof shape, proof
  rejection with the wrong secret, TPMT_PUBLIC RSA parsing, and
  qualified-signer mismatch rejection.
- Strengthened the QEMU harness so the four nodes have explicit differing
  boot-attested properties: distinct RAM sizes and distinct DMI product names,
  with node 4 still carrying the rejected cmdline. The harness writes and
  asserts `responses/security-properties.json` before admission starts.
- The harness now defaults swtpm control to TCP (`SWTPM_CTRL=tcp`) while
  preserving `SWTPM_CTRL=unix`; this avoids relying only on Unix socket
  support in environments that permit local TCP.

Validation evidence at `2026-05-02 07:28 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 33 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 13 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
```

Target rebuild and fresh QEMU acceptance rerun are still blocked in this
Codex sandbox:

```text
$ make buildroot JOBS=18
permission denied while trying to connect to the docker API at
unix:///Users/sam/.docker/run/docker.sock

$ bash scripts/qemu-green-zone-cluster.sh --timeout 600
!! swtpm failed for node 1
Could not open UnixIO socket: Operation not permitted

$ OUTDIR=/private/tmp/lapee-qemu-green-zone \
    bash scripts/qemu-green-zone-cluster.sh --timeout 600
!! swtpm failed for node 1
Could not open TCP socket: Operation not permitted
```

The last full appliance/QEMU green-zone pass remains Update 13. The current
increment is host-validated and staged into `build/hyperbeam/src-edge`, but the
image rebuild and the strengthened heterogeneity harness still need a host
that can access Docker and open swtpm sockets.

Residual protocol work from review:

- Add verifier-nonce freshness for `verify-peer`; the current path still
  verifies a cached boot-attestation plus a fresh credential-activation proof.
- Scope stored peer attestations more tightly by ring/template/peer/EK and
  validity window before they are accepted as reusable publisher evidence.

## Update 17

Closed the two residual protocol gaps from Update 16 and tightened admission
replay protection:

- `~tpm@2.0a/verify-peer` now fetches both the cached boot-attestation and a
  fresh `/~tpm@2.0a/attestation?nonce=<verifier-nonce>`. The verifier checks
  the fresh quote nonce explicitly, verifies both attestations against the same
  credential subject, and signs the resulting `green-zone-peer-attestation` with a
  `freshness` proof.
- Public `~tpm@2.0a/activate-credential` responses now validate as a typed
  `lapee-tpm-credential-activation` envelope. The HMAC proof is bound to the
  credential blobs, AK name, proof algorithm, and issued-at timestamp; the
  verifier rejects wrong type/version/proof algorithm/AK name.
- Signed peer attestations now carry a `peer-scope` containing the peer URL,
  boot/fresh attestation IDs, EK-public hash, AK-name hash, and optional
  consumer scope. Cache paths include an immutable scoped path keyed by peer
  URL hash, EK hash, boot-attestation ID, consumer-scope hash, and signed ID.
- `~green-zone@1.0/admit` passes the current ring scope
  `{ring-address, template-id}` into live peer verification and requires stored
  peer attestations to match that ring scope and TPM material before reuse.
- Green-zone stored-attestation reuse now requires `issued-at-unix`, signed
  validity, and a bounded max age (`green-zone-peer-attestation-max-age-seconds`,
  default 3600s).
- `~green-zone@1.0/admit` signs admissions as the ring wallet and includes
  `admission-nonce`, `validity`, and `ring-reference`. `join` generates the nonce,
  verifies the admission signer is the advertised ring address, checks expiry
  and optional expected ring address, then decrypts and address-checks the
  furnished wallet before installing it.
- The QEMU harness now scopes the direct `verify-peer` reusable-attestation
  preflight to the ring scope returned by `init`, and asserts the signed
  attestation carries that scope.

Validation evidence at `2026-05-02 08:32 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 34 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 15 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
```

Target rebuild and fresh QEMU acceptance rerun remain blocked by this Codex
macOS sandbox, not by the LapEE code path:

```text
$ make buildroot JOBS=18
permission denied while trying to connect to the docker API at
unix:///Users/sam/.docker/run/docker.sock

$ OUTDIR=/private/tmp/lapee-qemu-green-zone \
    bash scripts/qemu-green-zone-cluster.sh --timeout 600
!! swtpm failed for node 1
Could not open TCP socket: Operation not permitted

$ SWTPM_CTRL=unix OUTDIR=/private/tmp/lapee-qemu-green-zone-unix \
    bash scripts/qemu-green-zone-cluster.sh --timeout 600
!! swtpm failed for node 1
Could not open UnixIO socket: Operation not permitted

$ make native-build
native-build requires a Linux host (Buildroot doesn't run on Darwin).
```

The last full appliance/QEMU green-zone pass remains Update 13. The current
increment is host-validated and staged into `build/hyperbeam/src-edge`; it
still needs a host with Docker access and swtpm socket permission to rebuild
images and rerun the strengthened four-node gate.

## Update 18

Re-read the current branch and ran two focused sidecar reviews. Both found
the same high-risk gap: `verify-peer` produced nonce-bound fresh evidence, but
green-zone admission still matched templates against the cached
`peer-boot-attestation`. Additional review found AK public/name binding and
signed PCR-selection checks that were too trusting.

Fixes in this increment:

- `~green-zone@1.0/admit` now matches the ring template against the signed
  peer attestation's `peer-fresh-attestation`, not the stable cached
  boot-attestation.
- Stored `green-zone-peer-attestation` reuse now requires `boot-verification`,
  `peer-fresh-attestation`, a peer-scope URL matching the signed `peer-url`,
  and boot/fresh attestation IDs matching the embedded attestation bodies.
- `~green-zone@1.0/join` now requires a pinned expected ring address, supplied
  either in the request or node opts. A joiner no longer installs an arbitrary
  self-signed ring returned by a peer URL.
- Green-zone templates strip AO envelope metadata (`commitments`, `ao-types`)
  only at the template envelope boundary. Nested keys with those names remain
  policy. Metadata-only templates are rejected instead of becoming allow-all.
- `~tpm@2.0a/verify-peer` now binds the AK used for MakeCredential to the AK
  used for Quote by checking `ak-public` TPMT_PUBLIC, derived TPM name, and
  `ak-pub-pem` RSA key all match. Subject, boot, and fresh evidence also must
  agree on AK/EK public PEMs, names, and qualified names.
- TPMS_ATTEST parsing now requires quote magic/type, parses the signed PCR
  selection, compares it with the reported `pcr-selection`, and computes the
  PCR digest from the signed selection rather than caller-supplied metadata.
- Removed the mutable-looking `latest-by-peer-url-sha256` peer attestation
  cache path. Public storage now uses immutable by-id and scoped paths only.
- The QEMU harness now fetches credential subjects for all four nodes and
  asserts distinct EK publics, distinct AK names, matching cmdlines for nodes
  1-3, a differing cmdline for node 4, pinned join ring addresses, and node 4's
  exact `/system/kernel/cmdline` mismatch path.

Validation evidence at `2026-05-02 09:31 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test compile
Post-compile hooks executed

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_green_zone, [verbose])
All 22 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(dev_tpm2, [verbose])
All 37 tests passed.
exit:0

$ LAPEE_TPM_ALLOW_NO_NIF=1 erl ... eunit:test(lapee_http_json, [verbose])
2 tests passed.
exit:0

$ git diff HEAD --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py
```

Fresh target rebuild/QEMU acceptance rerun is still blocked by this Codex
macOS sandbox:

```text
$ make buildroot JOBS=18
permission denied while trying to connect to the docker API at
unix:///Users/sam/.docker/run/docker.sock

$ OUTDIR=/private/tmp/lapee-qemu-green-zone \
    bash scripts/qemu-green-zone-cluster.sh --timeout 600
!! swtpm failed for node 1
Could not open TCP socket: Operation not permitted

$ make native-build
native-build requires a Linux host (Buildroot doesn't run on Darwin).
```

The last full appliance/QEMU green-zone pass remains Update 13. This increment
is host-validated and staged into `build/hyperbeam/src-edge`; the strengthened
gate still needs a host with Docker access and swtpm socket permission.

## Update 15 - Named Green-Zones Accepted End-to-End

Sam clarified that transitive trust in stored peer attestations is a TPM-layer
concern, while green-zone state should be named active rings. The green-zone
implementation now follows that shape:

- `~green-zone@1.0` has named zones. `init`, `join`, `admit`, and `sign` take
  `name`/`green-zone-name`; node opts expose public `green-zones` keyed by
  name and private `priv-green-zones` keyed by name.
- `init` rejects caller-supplied AES keys or wallets, proves the initializer's
  own boot attestation matches the template, then mints the ring AES secret
  and wallet inside the node.
- `admit` still performs live TPM peer verification and MakeCredential, but no
  longer treats trusted publishers as ring state.
- Admission responses carry a nested ring-wallet-signed `authorization` over
  stable payload IDs so the joiner can verify the transported material before
  installing the named ring identity.
- The QEMU acceptance harness now uses a single no-TME image for all four
  nodes, differentiates node 4 via boot-attested DMI product, and asserts that
  only nodes 1-3 can join/sign as `book-shelf`.

Validation evidence at `2026-05-02 13:42 EDT`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m dev_green_zone
All 16 tests passed.

$ make buildroot JOBS=18
build/initramfs/initramfs-lapee.cpio.zst 192M May 2 13:34
build/kernel/vmlinuz-lapee 20M May 2 13:34

$ make hb-usb-no-tme-image WIFI=0
USB image ready: .../build/images/lapee-usb-no-tme.img (247463936 bytes)

$ ./scripts/qemu-green-zone-cluster.sh --timeout 600
>> node 1 initialized green-zone MmLlnKmWdIdvJxB_QV-yIfdMhNFBVKo9LS5v30g3KJ0
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone MmLlnKmWdIdvJxB_QV-yIfdMhNFBVKo9LS5v30g3KJ0
>> node 2 signed as green-zone MmLlnKmWdIdvJxB_QV-yIfdMhNFBVKo9LS5v30g3KJ0
>> node 3 signed as green-zone MmLlnKmWdIdvJxB_QV-yIfdMhNFBVKo9LS5v30g3KJ0

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: MmLlnKmWdIdvJxB_QV-yIfdMhNFBVKo9LS5v30g3KJ0

$ git diff --check
$ bash -n scripts/qemu-green-zone-cluster.sh
$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m dev_green_zone
All 16 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m dev_tpm2
All 37 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m lapee_http_json
All 4 tests passed. The Codex exec wrapper reported code -1 twice after
printing the successful EUnit result and normal os_mon shutdown lines.
```

## Update 16 - Green-Zone Protocol Naming And Docs

The public green-zone protocol terms now read from the ring's perspective:

- The peer-attestation envelope type is `green-zone-peer-attestation`.
- The ring identity object is `ring-reference`.
- The ring reference is the durable reference object built from the named zone,
  ring address, and template ID. The TPM layer still uses generic
  `peer-scope` / `consumer-scope` terms because those are not ring-specific.

The `~green-zone@1.0` module docs now include the current registration and
admission protocol: local zone initialization, live peer verification through
`~tpm@2.0a/verify-peer`, template matching against the peer boot attestation,
TPM MakeCredential/ActivateCredential delivery of the ring AES key, encrypted
ring-wallet transfer, and final installation of the named identity.

Validation evidence at `2026-05-02T19:54:25Z`:

```text
Deprecated-name scan across the repository: no results.

$ git diff --check

$ bash -n scripts/qemu-green-zone-cluster.sh

$ PYTHONPYCACHEPREFIX=/private/tmp/lapee-pycache \
    python3 -m py_compile scripts/qemu-green-zone-requests.py

$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m dev_green_zone
All 16 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m dev_tpm2
All 37 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 as test eunit -m lapee_http_json
All 4 tests passed. The Codex exec wrapper reported code -1 after printing
the successful EUnit result and normal os_mon shutdown lines.

$ make hb-usb-no-tme-image WIFI=0 JOBS=18
USB image ready: .../build/images/lapee-usb-no-tme.img (247463936 bytes)

$ ./scripts/qemu-green-zone-cluster.sh --timeout 600
>> node 1 initialized green-zone Lyc7r23hrZwvmct7ym-SwbTAz--Waay5X61f28NJd0s
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone Lyc7r23hrZwvmct7ym-SwbTAz--Waay5X61f28NJd0s
>> node 2 signed as green-zone Lyc7r23hrZwvmct7ym-SwbTAz--Waay5X61f28NJd0s
>> node 3 signed as green-zone Lyc7r23hrZwvmct7ym-SwbTAz--Waay5X61f28NJd0s

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: Lyc7r23hrZwvmct7ym-SwbTAz--Waay5X61f28NJd0s
```

## Update 17 - Peer Attestation Subject Binding

`~tpm@2.0a/verify-peer` now rejects a peer-verification response unless the
cached boot attestation and the fresh nonce-bound attestation name the same
`node-message-id`. This closes a stale-attestation mixing gap: the AK/EK
material still had to match, but the admission path now also requires the
boot-attested runtime subject and the fresh quote subject to be identical
before credential activation or green-zone admission can proceed.

Validation evidence at `2026-05-02T22:46:27Z`:

```text
$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_tpm2
All 40 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone
All 16 tests passed.

$ make buildroot JOBS=18
build/initramfs/initramfs-lapee.cpio.zst 192M May 2 18:39
build/kernel/vmlinuz-lapee 20M May 2 18:39

$ make hb-usb-no-tme-image WIFI=0 JOBS=18
USB image ready: .../build/images/lapee-usb-no-tme.img (247463936 bytes)

$ TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
    --img build/images/lapee-usb-no-tme.img --timeout 600
>> node 1 initialized green-zone ikJ7HRAVfkKTRNem2IbcbAREcjHu3aAGsk2JAFS4BXU
>> node 1 can admit node 2
>> node 2 joined green-zone
>> node 3 joined green-zone
>> node 4 rejected as expected
>> node 4 status has no green-zone wallet
>> node 4 cannot sign as green-zone
>> node 1 signed as green-zone ikJ7HRAVfkKTRNem2IbcbAREcjHu3aAGsk2JAFS4BXU
>> node 2 signed as green-zone ikJ7HRAVfkKTRNem2IbcbAREcjHu3aAGsk2JAFS4BXU
>> node 3 signed as green-zone ikJ7HRAVfkKTRNem2IbcbAREcjHu3aAGsk2JAFS4BXU

=== green-zone QEMU cluster PASSED ===
out: /Users/sam/.codex/worktrees/4b17/lapee/build/qemu-green-zone
ring-address: ikJ7HRAVfkKTRNem2IbcbAREcjHu3aAGsk2JAFS4BXU
```

## Update 18 - Naming And Template Semantics Cleanup

Tidied the protocol surface and system probe snapshots:

- Removed the completed probe-surface correction TODO; the durable decision is
  `docs/decisions/read-oriented-probe-surface.md`.
- Updated stale documentation/corpus references to canonical `~tpm@2.0a`.
- Clarified `~green-zone@1.0` template docs: templates use
  `hb_message:match/4`, so AO metadata keys such as `commitments` and
  `ao-types` are ignored as message metadata.
- `~system@1.0` reuses one Boot Guard, EDAC, and memory-controller snapshot.

Validation evidence at `2026-05-02T22:51:48Z`:

```text
$ rg 'lapee-peer-attestation|ring-scope|greenzone@1\\.0|tpm2@2\\.0a|trusted-ca-pem|probe-surface-correction-todo' -n . --glob '!build/**' --glob '!STATUS.md'
no results

$ ./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge
>> LapEE HyperBEAM overlay staged

$ cd build/hyperbeam/src-edge
$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_green_zone
All 15 tests passed.

$ LAPEE_TPM_ALLOW_NO_NIF=1 rebar3 eunit --module=dev_system
All 2 tests passed.

$ git diff --check
```
