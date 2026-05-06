# LapEE Green-Zone Peer Verification Status

## Current State

Branch: `main`.

LapEE now has an end-to-end QEMU green-zone flow: four nodes boot from the
same no-TME image, three nodes matching the green-zone template join and sign
with the shared ring identity, and the mismatching node is rejected and cannot
sign.

The critical AK/PCR policy bug described in `AK_PCR_POLICY_ISSUE.md` is fixed.
Native AKs are created with an auth policy rather than user auth, quote and
ActivateCredential run through PCR policy sessions, and verification recomputes
the AK policy from the quoted PCRs before accepting the attestation.

Follow-up fix: PCR15 is now part of the AK policy. LapEE gathers the boot
subject (`~system@1.0/all` plus `~meta@1.0/info`), extends PCR15 with that
subject before AK creation, optionally extends the TCG event-log tip, and only
then creates the AK. Runtime/public PCR15 extension is blocked after that point
so AK use remains gated by the node config that booted.

## Latest Validation

Overlay staged into `build/hyperbeam/src-edge`.

Focused eunit passed for `dev_tpm2`, `dev_green_zone`, `dev_system`,
`lapee_http_json`, and `dev_tpm_interpret`.

`JOBS=18 make DOCKER_PLATFORM='--dns=1.1.1.1' buildroot` completed.
The Docker DNS override was needed on this machine because Docker Desktop's
default resolver intermittently failed to resolve GitHub/crates.io during
dependency fetches; it does not change the resulting image.

No-TME image:

```text
path: build/images/lapee-usb-no-tme.img
size: 247463936 bytes
sha256: 66b94254f2c8f0b8741901f621242014ec361ff89fd691f93c1718aaab8939a8
```

Fresh AK/PCR15 no-TME smoke test:

```text
OUTDIR=build/qemu-ak-policy-final \
LOGFILE=build/qemu-ak-policy-final/serial.log \
  ./scripts/boot-usb-image.sh \
    --img build/images/lapee-usb-no-tme.img \
    --timeout 420

result: PASSED
captures:
  build/qemu-ak-policy-final/boot-attestation.json
  build/qemu-ak-policy-final/system.json
```

Secondary verifier against the QEMU capture:

```text
python3 secondary-external-verifier/verifier_hb.py \
  build/qemu-ak-policy-final/boot-attestation.json

expected final verdict: ATTESTATION REJECTED
reason: QEMU/swtpm EK does not chain to a bundled manufacturer root.
critical passes:
  TPM2_Quote signature + pcrDigest + nonce all valid
  AK authPolicy covers PCRs [0, 1, 7, 10, 11, 14, 15]
  PCR15 replay matches quoted value
  PCR15 boot-subject event matches node-message-id
```

QEMU ring test (now exercises the multi-hop join path: node 3 joins
via node 2, then asserts every member's `/status` shows the wallet
count the protocol actually delivers -- 2 on the initializer, 3 on
the admitter and joiner):

```text
TIMEOUT=600 ./scripts/qemu-green-zone-cluster.sh \
  --img build/images/lapee-usb-no-tme.img \
  --timeout 600

result: PASSED
ring-address: JWfbKiiYxxNgup7Ac0QleOoqth_3BaCx8g1PAGi3VwY
```

Standard TME image:

```text
path: build/images/lapee-usb.img
size: 247463936 bytes
sha256: 24a4c15e3b64b59f210b239a9dceafe80a3611275349cfa09767fe6f1b420f66
```

Single-node `~tpm@2.0a/attestation` envelope re-validation path now checks AK
`authPolicy` over `[0, 1, 7, 10, 11, 14, 15]`, PCR15 replay, and the
boot-subject digest binding. The old AK-public-key PCR15 event requirement was
removed because it cannot coexist with PCR15-gated AK policy.

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
* `secondary-external-verifier/verifier_hb.py` now treats the AK `authPolicy`
  as the key binding check. It recomputes the same PCR policy as the TPM NIF,
  including PCR15, then separately verifies PCR15 replay and the boot-subject
  digest event.

## Cross-vendor green-zone hardening

A second pass driven by three real-hardware findings:

1. `add_member_to_members` was dropping new members through a stale
   `commitments` key. Mutating a committed map via Erlang's `#{=>}'
   leaves the commitments untouched; the next `commit_unsigned_tree'
   linkifies the inner map, the cache write honours the existing
   signature's `committed' list, and the new key is silently
   filtered. Switched to `hb_message:uncommitted' + `hb_ao:set'.
   Regression eunit drives the same `commit_unsigned_tree' path that
   exposed the bug on real nodes.
2. The original cross-vendor green-zone template I built pinned the
   `system.firmware.efi.global-variables.secure-boot.state' value,
   which reads `not-readable' on every recent laptop firmware that
   doesn't expose efivarfs to the kernel -- whether SB is on or
   off. The template trivially admitted a Lenovo ADL with SB
   *disabled*. Added `dev_tpm_tcg:boot_signals/1' which derives
   policy-actionable signals from the firmware-side TCG event log
   (currently `secure-boot.enabled' from
   `EV_EFI_VARIABLE_DRIVER_CONFIG' on PCR 7) and embedded the result
   at `body.tpm.signals.secure-boot.enabled' in the signed
   boot-attestation envelope. Green-zone templates can now pin the
   actual TCG-derived state, not the efivarfs-readable proxy.
3. The keylime corpus shipped at `priv/tpm-interpret/root-cas/' is
   never updated automatically (the fetch script had drifted to
   write to a different directory, since reverted), and Intel ODCA's
   per-SoC issuing CAs (one per Alder Lake / Meteor Lake / Raptor
   Lake / ... family) are not in keylime's bundle at all. They are
   only published at each chip's AIA caIssuers URL (e.g.
   `https://tsci.intel.com/content/OnDieCA/certs/ADL_00002820_ODCA_CA2.cer').
   Added a new `lapee_aia' module (HTTPS-only fetch, persistent_term
   cache, node-config kill switch) and wired it into both Erlang
   chain validators (`dev_tpm2:validate_ek_chain' and
   `dev_tpm_interpret:build_intermediate_path') plus the Python
   secondary verifier. Confirmed end-to-end on three live nodes:
   Lenovo MTL Intel-PTT, Framework 13 Nuvoton, and Lenovo ADL
   Intel-PTT (which requires AIA fetch of the ADL Issuing CA) all
   return ATTESTATION ACCEPTED from the Python verifier with default
   settings.

## Open Threads

Keep sharpening toward smaller, more idiomatic HyperBEAM device code while
preserving the four-node QEMU acceptance gate.

Do not track `AK_PCR_POLICY_ISSUE.md`; it is a local prompt artifact.
