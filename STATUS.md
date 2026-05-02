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
only `issuercert.pem` is not sufficient. The verifier now treats
`trusted-ca`/`trusted-ca-pem` as PEM bundles, tries each certificate as a trust
anchor, and uses the remaining bundle entries plus the peer-presented chain as
intermediate candidates. The cluster harness now supplies the swtpm issuer +
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
  the signed `lapee-peer-attestation`. This keeps later green-zone template
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
2. Node 1 receives a signed `lapee-peer-attestation` whose verification and
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

- Stored `lapee-peer-attestation` reuse now binds the request to the URL that
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
