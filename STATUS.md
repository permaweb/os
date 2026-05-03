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

Focused eunit passed for `dev_tpm2`, `dev_green_zone`, `dev_system`,
`lapee_http_json`, and `dev_tpm_interpret`.

`make buildroot JOBS=18` completed.

No-TME image:

```text
path: build/images/lapee-usb-no-tme.img
size: 247463936 bytes
sha256: 9ca2becb031849e25ef8ff4642f7b3eb76ef07ae885568b1026c46824ad9130a
```

QEMU ring test:

```text
TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
  --img build/images/lapee-usb-no-tme.img \
  --timeout 600

result: PASSED
ring-address: D-3ORKB6GxzkMrjtxQGicfgsIyvaM5XM9USFEjCuHTw
```

Standard TME image:

```text
path: build/images/lapee-usb.img
size: 247463936 bytes
sha256: e7bfc6c575619ab372b9b9d079c342fbc0dcf5d8f9876a11a0892e49d5ecfe68
```

Single-node `~tpm@2.0a/attestation` envelope re-validated end-to-end with
`secondary-external-verifier/verifier_hb.py` after the seq-pinning fix
(check 6 matches by digest, check 7 matches `EV_HYPERBEAM_KEY_PUBKEY_EXTEND`
+ digest): all eight checks PASS.

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
changes: TPM probe parsing, stale helper stubs, green-zone authorization
checks, peer-cache docs, and Boot Guard probe source generality were all
trimmed while preserving the four-node QEMU acceptance gate.

Two operability defects surfaced during this validation pass and were
fixed in-place:

* `scripts/qemu-green-zone-cluster.sh` was creating swtpm unix sockets
  under `OUTDIR/nodes/nodeN/tpm/swtpm-sock`. Worktree-rooted OUTDIRs
  blew the AF_UNIX `sun_path` limit (104 bytes on macOS) and swtpm
  failed opaquely with `Path for UnioIO socket is too long`. The
  script now stages sockets under a short `mktemp -d /tmp/lapee-gz.*`
  directory and cleans it up on exit; state, logs, and certs continue
  to live under OUTDIR.
* `secondary-external-verifier/verifier_hb.py` pinned PCR-15 binding
  checks to seq=0 (`EV_HYPERBEAM_NODE_IDENTITY_EXTEND`) and seq=1
  (`EV_HYPERBEAM_KEY_PUBKEY_EXTEND`). Production now drives PCR 15
  from the `on.start` -> `boot-attestation` path, so seq 0 carries
  `EV_HYPERBEAM_KEY_PUBKEY_EXTEND` and the node-identity binding is
  `EV_HYPERBEAM_BOOT_ATTESTATION_SUBJECT` at seq 2. The fix matches
  the Erlang-side `chk_binding` / `chk_ak_pubkey_binding` semantics:
  search by event-type + digest, not by seq position.

## Open Threads

Keep sharpening toward smaller, more idiomatic HyperBEAM device code while
preserving the four-node QEMU acceptance gate.

Do not track `AK_PCR_POLICY_ISSUE.md`; it is a local prompt artifact.
