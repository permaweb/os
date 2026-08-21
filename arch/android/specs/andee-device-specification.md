# AndEE Device Interface Specification

Status: implementation specification for the PermawebOS AndEE architecture.

Audience: verifier authors, third-party AndEE implementers, and agents adding
tests or peer interoperability. This document specifies the public AO-Core
interfaces implemented by AndEE-specific HyperBEAM devices and the exact
message bindings that external verifiers must check.

## 1. Scope

AndEE keeps PermawebOS's public measurement and zone contracts while using
Android Keystore/StrongBox evidence as one measurement backend.

The AndEE measurement backend is `~andee@1.0`. It is packaged with the
shared PermawebOS devices so every architecture can verify AndEE peers. Local
measurement generation requires Android; peer verification is pure BEAM.
The public architecture name is AndEE; existing wire identifiers, package
names, and module names still use `andee` where that is the implemented
AO-Core or Android API.

- `~measurement@1.0`: inherited public measurement envelope, fresh nonce flow,
  peer verification, and secret activation entry point. In AndEE it selects
  `andee@1.0` as the only backend.
- `~andee@1.0`: Android Keystore/StrongBox measurement backend and
  secret-recipient implementation. `subject`, `measure`, and `unwrap-secret`
  require the app-private Android crypto agent; `verify` and `wrap-secret`
  are portable.
- `~system@1.0`: inherited system-report slot, reduced to Android/app/runtime
  facts inserted into the measured subject.
- `~meta@1.0`: inherited stock HyperBEAM meta device.
- `~zone@1.0`: inherited measurement-backed shared identity admission, adapted
  to AndEE peer HTTP and volatile Android runtime state.

`~hyperbuddy@1.0` is included in the runtime as an unchanged formatter device.
It is not a security boundary and is not part of the attestation protocol.

In the current Android package, `andee_bootstrap` explicitly binds these names
to local modules because the runtime is a stripped, self-contained HyperBEAM
release. That bootstrap binding MUST NOT be read as a claim that
`~measurement@1.0`, `~system@1.0`, or `~zone@1.0` are new public protocols.

## 2. Normative Conventions

### 2.1 AO-Core Messages

Every public AndEE value at the HyperBEAM boundary is an AO-Core structured
message. Implementations MUST NOT replace these messages with an ad hoc JSON
protocol. JSON may be used by HTTP clients or by the app-private Android bridge
only as a transport encoding of the AO-Core message tree.

Message keys in this specification are written as strings. In Erlang
implementations they are binary keys such as `<<"measurement-device">>`.

### 2.2 Binary Encoding

All binary values on the wire MUST be base64url without padding unless a field
explicitly says otherwise.

Base64url means:

- alphabet `A-Z a-z 0-9 - _`;
- no `=` padding;
- no line wrapping.

Fields that use base64url include nonces, X.509 DER certificates, ECDSA
signatures, X25519 public keys, AES-GCM inputs/outputs, SHA-256 digests, and
AO-Core human IDs.

The only hex field in the current AndEE public evidence is
`policy-snapshot.release-digest`, which is the Android app's local hex
SHA-256 digest over the release signing certificate bytes in APK signer order.

### 2.3 Boolean Encoding

AO-Core materializers may expose booleans as JSON booleans (`true`, `false`) or
as AO atom strings (`"true"`, `"false"`). Verifiers MUST normalize both forms
when checking boolean policy facts. Producers SHOULD emit JSON booleans when
using JSON as a transport.

### 2.4 Links And Materialization

AndEE responses may contain AO-Core links such as `body+link`,
`evidence+link`, or nested linked commitments. A verifier that receives linked
messages MUST materialize the linked values before applying this specification.

For peer HTTP calls, AndEE requests HyperBEAM HTTPSig responses with:

```json
{
  "require-codec": "httpsig@1.0",
  "accept-bundle": true
}
```

Third-party clients SHOULD do the same. A verifier MAY accept already
materialized JSON if all linked values have been expanded faithfully.

### 2.5 Stable IDs

Several fields bind one AO-Core message to another by ID. These IDs are not
JSON hashes.

For a map value, `stable-id(Msg)` is:

1. Recursively remove detached transport metadata keys:
   - `commitments`;
   - `ao-types`.
2. Recursively convert atom values to their binary/string names.
3. Recursively remove commitments from all nested maps, as
   `hb_message:uncommitted_deep/2` does.
4. Compute the AO-Core uncommitted message ID using HyperBEAM
   `hb_message:id(UncommittedDeepMsg, uncommitted, Opts)`.
5. Encode the 32-byte ID as a HyperBEAM human ID, which is base64url without
   padding and is normally 43 characters.

For non-map values, `stable-id(Value)` is:

- if `Value` is exactly 32 bytes: base64url encode those bytes;
- if `Value` is a 43-byte valid HyperBEAM human ID: use it unchanged;
- if `Value` is any other binary/string: base64url(SHA-256(Value));
- otherwise: base64url(SHA-256(Erlang `term_to_binary(Value)`)).

Conformant verifiers MUST use the AO-Core ID rule for the following fields:

- `andee-evidence-subject.body-id`;
- `andee-evidence-subject.secret-recipient-id`;
- `andee-android-evidence.evidence-subject-id`;
- `lapee-secret-recipient.binding.binding-id`;
- `lapee-wrapped-secret.subject-id`;
- `zone-peer-attestation.peer-scope.*-attestation-id`;
- `zone-peer-attestation.peer-scope.secret-recipient-id`;
- `zone-admission.authorization.*-id`.

Using `SHA-256(canonical JSON)` for these fields is non-conformant.

## 3. Runtime Configuration Invariants

A production AndEE node MUST enforce at least:

```json
{
  "measurement-device": "andee@1.0",
  "on": {
    "start": {
      "device": "measurement@1.0",
      "path": "boot",
      "method": "POST",
      "target": "body",
      "hook": {
        "result": "ignore"
      }
    }
  }
}
```

Operator configuration MAY shape public node metadata and MAY enable normal
remote device resolution with a nonempty `trusted-device-signers` allowlist
and measured `name-resolvers`. The exact allowlist and resolver bindings are
part of the effective node message and therefore the boot measurement.
Operator configuration MUST NOT disable the AndEE measurement device, bypass
the `on.start` boot measurement hook, inject an unmeasured `trusted-devices`
map, or override HyperBEAM's stock store/cache configuration. Node identity
MUST follow normal HyperBEAM `priv-key-location` semantics. When the operator
does not select a location, the Android runtime MUST supply an app-private
default that persists across service and app-process restarts and is removed
with app data. The path and key material MUST NOT be projected into public
runtime facts or passed to an isolated execution worker.

The shipped read-only gateway store MUST decode fetched AO messages through
the measured `_build/preloaded-store`. It MUST NOT write remote device
archives back into the primary store: loaded device modules already use
HyperBEAM's shared loaded-device cache, while archive materialization adds
archive-sized work unrelated to application state. The primary store MUST use
stock transactional LMDB semantics in app-private storage outside the
replaceable runtime directory so concurrent cache writers cannot expose
partially replaced links and ordinary stateful devices retain process graphs
and bootstrap links across service and app-process restarts. Its write batch
MUST be bounded. Release acceptance MUST force-stop the app immediately after
an acknowledged application mutation and prove that mutation, its process
graph, and its execution workspace recover. Because the pinned stock backend
acknowledges writes in its in-memory overlay before transaction commit, AndEE
MUST NOT claim that an arbitrary write-only store call is synchronously durable.

Private provider elements under `inference-providers/<provider>/priv` follow
normal HyperBEAM configuration semantics. AndEE preserves them in the
app-private effective configuration and relies on stock HyperBEAM private-key
filtering to keep them out of `~meta@1.0` and the public boot measurement. Only
the explicitly protected identity and runtime-control keys listed by the
boot-config store are rejected.

Apart from those protected top-level boot controls, operator configuration is
merged without AndEE-specific key filtering. Private options such as provider
credentials retain normal HyperBEAM semantics in the app-private effective
configuration. Stock HyperBEAM private-key filtering, rather than Android-side
name matching, keeps them out of `~meta@1.0` and the public boot measurement.

### 3.1 Local Andock execution capability

An AndEE build MUST preload the repository-owned generic `~andock@1.0`
execution device and package its local capability. This does not add an
AndEE-specific public AO protocol or any application server to the Android
app. Application devices MUST remain runtime-loaded trusted packages selected
through measured node JSON; their source, archives, payloads, pins, and
provenance MUST NOT enter the APK or its build graph.

Each member MUST have a separate writable filesystem image. The main app MUST
pass an isolated worker only that member image, a bounded command channel, and
an outbound network capability when the request enables networking. It MUST
NOT pass the runtime root, immutable template, another member image, effective
node configuration, wallet, provider credentials, crypto-agent socket, or
Android credential storage. Guest path resolution MUST remain inside the
filesystem image and MUST NOT concatenate guest paths with Android host paths.

PRoot or an equivalent compatibility layer MAY supply Ubuntu/glibc pathname
and syscall behavior, but MUST NOT be represented as the security boundary.
The boundary is the Android isolated UID, SELinux domain, and explicitly
delivered descriptors. A network-disabled worker MUST receive no Internet
socket-creation capability. A network-enabled worker MUST enforce numeric
destination policy for each destination-bearing syscall; command inspection
is non-conformant. A wildcard ephemeral UDP client bind MUST NOT create an
inbound capability: receive filtering MUST be pinned to an authorized reply
peer and pre-selection datagrams MUST NOT be delivered, while fixed-port,
non-wildcard, and listening binds remain denied. The worker MUST NOT permit a
UDP disconnect to remove that peer filter while another receive is in flight.

The immutable template, native engine, compatibility layer, manifests, and
selected node configuration are committed through the existing APK-set,
native-library-set, runtime-ZIP, and effective-node-message measurement facts.

### 3.2 Local inference capability

An AndEE build MUST preload the repository-owned generic
`~andee-inference@1.0` provider device and package its Android local-compute
capability. It MUST NOT replace the generic `~inference@1.0` multiplexer. The
public AO surface MUST remain application- and provider-agnostic and MUST
return non-streaming OpenAI chat-completion shapes. Models MUST NOT be embedded
in the APK or runtime ZIP.

Each model MUST be selected by an id allowlisted beneath its provider in the
effective measured node configuration. The catalogue MUST bind that name to a
43-character Arweave `model-id`, exact byte length, base64url SHA-256 digest,
measured backend, and resource bounds. The Android runtime MAY derive an
app-private materialization path from the network id. Requests and public
configuration MUST NOT select filesystem paths, URLs, or unmeasured model
files.

The backend MUST be selected by effective measured configuration and MUST NOT
be request-overridable. An NPU model MUST declare an exact supported-vendor SoC
allowlist and the current device, ABI, Android version, vendor dispatch
library, and model backend MUST match before initialization. Runtime
initialization failure MUST NOT trigger an application-level retry on CPU or
GPU. Because the current LiteRT-LM API does not expose effective partition
delegation and may retain CPU-side work, successful initialization or
generation MUST NOT be represented as mobile-NPU evidence. Hardware acceptance
requires an independently observed device trace or counter. Emulator
acceptance MAY select CPU or GPU in measured configuration but MUST NOT
represent that run as mobile-NPU evidence.

HyperBEAM and the Android inference broker MUST communicate over an
app-private, bounded, length-framed Unix socket whose peer UID is the AndEE app
UID. Model generation MUST be serialized and request text, message count, tool
count, output tokens, end-to-end duration including engine initialization, and
frame sizes MUST be bounded. Timeout and service shutdown MUST NOT wait
unboundedly for vendor cancellation; a non-cooperative native runtime MUST
trigger an explicit AndEE app-process reset. Health MUST
distinguish compatible configuration from successful engine initialization.
Completion evidence MUST state the requested backend, model digest, and SoC,
and MUST NOT claim effective NPU execution without independent evidence.

Mutable member images MUST NOT enter the boot measurement. No additional
Andock-specific `~measurement@1.0`, `~system@1.0`, or `~andee@1.0` projection
is required.

## 4. Stock `~meta@1.0`

AndEE uses the stock HyperBEAM `~meta@1.0` device. `GET /~meta@1.0/info`
therefore returns the public node message after HyperBEAM's normal private-key
filtering. AndEE-specific Android facts belong in `~system@1.0/all` and
AndEE cryptographic evidence belongs in `~andee@1.0`; neither requires replacing
the meta device.

The stock meta result is one half of the measured body used by
`~measurement@1.0`.

## 5. `~system@1.0`

`~system@1.0` contributes Android/app/runtime facts to the measurement body.
Hardware-rooted acceptance lives in `~andee@1.0` evidence, not here.

### 5.1 `GET /~system@1.0/info`

Returns status `200`:

```json
{
  "version": "1.0",
  "platform": "android",
  "measurement-device": "andee@1.0"
}
```

### 5.2 `GET /~system@1.0/all`

Returns status `200`:

```json
{
  "schema": "andee-system-report@1",
  "generated-at-unix": 0,
  "platform": "android",
  "runtime": {
    "hyperbeam-release": "<release id or unknown>",
    "app-uid-isolation": true,
    "runtime-root": "app-private",
    "config-source": "app-private"
  },
  "app": {
    "package-name": "org.permaweb.andee",
    "version-name": "<version name or unknown>",
    "version-code": "<version code or unknown>",
    "release-digest": "<hex sha256 signer aggregate or unknown>"
  },
  "policy": {
    "policy-source": "android-agent",
    "debuggable": "<boolean or unknown>",
    "adb-enabled": "<boolean or unknown>",
    "debugger-attached": "<boolean or unknown>",
    "tracer-pid": "<integer or unknown>"
  }
}
```

Required semantics:

- `schema` MUST be `andee-system-report@1`.
- `platform` MUST be `android`.
- `runtime.app-uid-isolation` MUST be true.
- `app.package-name` MUST be `org.permaweb.andee` for the release app.

This report is descriptive. Verifiers MUST use the Android evidence policy
snapshot for acceptance.

## 6. `~measurement@1.0`

`~measurement@1.0` is the public measurement interface. In AndEE it selects
`andee@1.0` as the only supported backend and wraps backend evidence in the
PermawebOS-compatible measurement envelope.

### 6.1 Exports

The device exports:

- `info`;
- `boot`;
- `fresh`;
- `verify`;
- `verify-peer`;
- `unwrap-secret`.

The Erlang module also exposes helper functions for internal callers:
`wrap_secret_for_subject/3`, `unwrap_secret_value/2`, `measurement_body/1`, and
`measurement_body_id/2`.

### 6.2 `GET /~measurement@1.0/info`

Returns status `200`:

```json
{
  "version": "1.0",
  "selected-measurement-device": "andee@1.0",
  "selection-reason": "configured",
  "available-candidates": [
    {
      "device": "andee@1.0",
      "supported": true
    }
  ]
}
```

`selection-reason` is:

- `configured` when node config sets `measurement-device = "andee@1.0"`;
- `auto` when the device was selected from defaults;
- an error detail if no device is available.

### 6.3 Measured Body

Both `/boot` and `/fresh` measure the same canonical subject body for the
current HyperBEAM VM:

```json
{
  "system": { "...": "~system@1.0/all body" },
  "node": { "...": "~meta@1.0/info body" }
}
```

The body is cached in VM memory after first construction. `body-id` fields in
AndEE evidence MUST equal `stable-id(body)`.

### 6.4 Measurement Envelope

`/boot` and `/fresh` return a committed AO-Core message whose body has this
shape:

```json
{
  "type": "lapee-measurement",
  "version": "1.0",
  "issued-at-unix": 0,
  "measurement-device": "andee@1.0",
  "body": {},
  "evidence": {},
  "secret-recipient": {}
}
```

Required semantics:

- `type` MUST be `lapee-measurement`.
- `version` MUST be `1.0`.
- `measurement-device` MUST be `andee@1.0`.
- `body` MUST be the measured body from section 6.3.
- `evidence` MUST be a `andee-android-evidence` message from section 7.6.
- `secret-recipient` MUST be a `lapee-secret-recipient` message from section
  7.5.
- The envelope SHOULD be AO-Core committed by the node's current commitment
  device. External Android/Keystore verification does not rely on this
  HyperBEAM node commitment alone; it relies on the backend evidence.

### 6.5 `GET|POST /~measurement@1.0/boot`

Returns the boot measurement envelope.

Behavior:

- The first successful call in a VM creates a measurement with
  `purpose = "boot"`.
- The resulting committed envelope is cached in VM memory.
- Subsequent calls return the same cached envelope materialized from cache.
- The first `on.start` hook in production config invokes this path with
  `method = "POST"` and ignores the result after caching it.

If measurement construction fails, the device returns status `500` with:

```json
{
  "error": "measurement-boot-failed",
  "reason": "<detail>"
}
```

### 6.6 `GET|POST /~measurement@1.0/fresh`

Returns a new measurement envelope on every call.

Request fields:

- `nonce`: optional. If present and base64url-decodable, it is decoded to raw
  nonce bytes. If present and not base64url-decodable, its raw binary/string
  bytes are used. If absent, the node generates 32 random bytes.

Behavior:

- The backend evidence subject uses `purpose = "fresh"`.
- The backend evidence subject stores `nonce = base64url(raw nonce bytes)`.
- Verifiers that requested a nonce MUST compare it to
  `evidence.evidence-subject.nonce`.

If construction fails, the device returns status `500` with:

```json
{
  "error": "measurement-fresh-failed",
  "reason": "<detail>"
}
```

### 6.7 `POST /~measurement@1.0/verify`

Verifies a measurement envelope by delegating to the envelope's
`measurement-device`.

Accepted request shapes:

- request body has `envelope` set to a measurement envelope;
- request body itself is a measurement envelope;
- base message is a wrapper with `body` set to a measurement envelope.

Optional request fields:

- `nonce`: when set, the backend verifier MUST require it to match the evidence
  subject nonce.

Response body:

```json
{
  "verified": true,
  "verdict": "accepted",
  "checks": [
    {
      "name": "measurement device is andee@1.0",
      "ok": true,
      "severity": "core"
    }
  ]
}
```

Required semantics:

- `verified` MUST be true only if every check with `severity = "core"` has
  `ok = true`.
- `verdict` MUST be `accepted` when `verified` is true, else `rejected`.

### 6.8 `POST /~measurement@1.0/verify-peer`

Performs online verification of another AndEE peer and returns a
`zone-peer-attestation`.

Request fields:

- `url` or `peer`: required peer base URL. A trailing slash is stripped.
- `peer-attestation-scope`: optional consumer scope. Zones set this to their
  `zone-ring-reference`.

Protocol:

1. Fetch peer `GET /~measurement@1.0/boot`.
2. Generate a 32-byte random fresh nonce.
3. Fetch peer `GET /~measurement@1.0/fresh?nonce=<base64url nonce>`.
4. Materialize both envelopes.
5. Require both envelopes to have:
   - `type = "lapee-measurement"`;
   - map `body`;
   - map `evidence`;
   - map `secret-recipient`.
6. Require `stable-id(boot.body) == stable-id(fresh.body)`.
7. Require boot and fresh `secret-recipient` to have the same
   `measurement-device` and `stable-id`.
8. Verify boot with `~measurement@1.0/verify`.
9. Verify fresh with `~measurement@1.0/verify` and the generated nonce.
10. Generate a 32-byte random challenge.
11. Wrap the challenge to the peer's `secret-recipient`.
12. POST the wrapped credential to peer
    `/~measurement@1.0/unwrap-secret`.
13. Verify the peer's activation proof over the original challenge.
14. Commit and store the resulting peer attestation under
    `~measurement@1.0/peer-attestations/<attestation-id>`.

Response body shape:

```json
{
  "type": "zone-peer-attestation",
  "version": "1.0",
  "issued-at-unix": 0,
  "measurement-device": "andee@1.0",
  "secret-method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "validity": {
    "not-before-unix": 0,
    "expires-at-unix": 0
  },
  "peer-url": "http://host:8734",
  "peer-scope": {
    "peer-url": "http://host:8734",
    "measurement-device": "andee@1.0",
    "boot-attestation-id": "<AO-Core ID>",
    "fresh-attestation-id": "<AO-Core ID>",
    "secret-recipient-id": "<AO-Core ID>",
    "consumer-scope": null
  },
  "peer-boot-attestation": {},
  "peer-fresh-attestation": {},
  "peer-credential-subject": {},
  "peer-secret-subject": {},
  "boot-verification": {
    "verified": true
  },
  "verification": {
    "verified": true
  },
  "freshness": {
    "verified": true,
    "nonce-sha256": "<base64url sha256 raw nonce>",
    "fresh-attestation-id": "<AO-Core ID>"
  },
  "credential-activation": {
    "verified": true,
    "challenge-sha256": "<base64url sha256 raw challenge>",
    "credential": {},
    "response": {}
  }
}
```

Default peer-attestation validity:

- `not-before-unix = issued-at-unix`;
- `expires-at-unix` is absent by default;
- if `peer-attestation-ttl-seconds` is set, `expires-at-unix =
  issued-at-unix + peer-attestation-ttl-seconds`.

Failure returns status `400` for missing peer URL or `502` for peer verification
failure, with `error = "measurement-verify-peer-failed"` or a more specific
error body.

### 6.9 `POST /~measurement@1.0/unwrap-secret`

Activates a wrapped secret locally.

Accepted request shapes:

- `{ "credential": <lapee-wrapped-secret> }`;
- `{ "wrapped-secret": <lapee-wrapped-secret> }`;
- the wrapped secret message itself.

Behavior:

- Selects the backend from `credential.measurement-device`.
- Delegates to `~andee@1.0/unwrap-secret`.
- Returns a committed `lapee-secret-activation` message from section 7.12.

## 7. `~andee@1.0`

`~andee@1.0` is the only measurement backend in AndEE. It constructs Android
Keystore evidence, owns the boot/session-local X25519 recipient key, and
implements PermawebOS-compatible secret wrapping.

### 7.1 Exports

The device exports:

- `info`;
- `supported`;
- `subject`;
- `measure`;
- `verify`;
- `wrap-secret`;
- `unwrap-secret`.

### 7.2 Constants

```text
version = "1.0"
measurement-device = "andee@1.0"
method = "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm"
evidence-context = "andee-android-evidence-v1"
default evidence ttl = none; freshness is nonce-bound through `/fresh`
default Android agent socket = "org.permaweb.andee.crypto"
default Android agent timeout = 5000 ms
```

### 7.3 `GET /~andee@1.0/info`

Returns status `200`:

```json
{
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "supported": true,
  "policy-accepted": true
}
```

`supported` is true iff the local Android crypto agent is reachable. This keeps
non-Android nodes from selecting AndEE for local measurement generation while
still allowing them to verify AndEE peers. `policy-accepted` is read from the
agent's `policy-status` action and is evidence only.

### 7.4 `GET|POST /~andee@1.0/supported`

Returns the bare AO-Core boolean value `true` only when the local Android
crypto agent is reachable. It is not wrapped in a `status/body` response by the
Erlang backend. `~measurement@1.0/info` uses this export to decide whether
`andee@1.0` is an available local measurement candidate. Non-Android nodes
normally return `false` here but can still call `~andee@1.0/verify`.

### 7.5 `POST /~andee@1.0/subject`

Constructs the local secret-recipient subject for a measurement body.

Request fields:

- `body`: optional AO-Core measured body. Defaults to `{}`.

The device keeps one X25519 recipient keypair in VM memory at
`persistent_term {dev_andee, x25519_keypair}`. It is generated on first use
with `crypto:generate_key(ecdh, x25519)`. It is never persisted by AndEE v1.

Response body:

```json
{
  "type": "lapee-secret-recipient",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "key-id": "<base64url sha256 x25519 public key>",
  "public-material": {
    "x25519-public-key": "<base64url raw 32-byte x25519 public key>"
  },
  "binding": {
    "evidence-context": "andee-android-evidence-v1",
    "body-id": "<stable-id(body)>",
    "measurement-device": "andee@1.0",
    "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
    "binding-id": "<stable-id(binding without binding-id)>"
  }
}
```

Required semantics:

- `binding.body-id` MUST equal `stable-id(body)`.
- `binding.binding-id` MUST equal `stable-id(binding)` before `binding-id` is
  added.
- `key-id` MUST equal base64url(SHA-256(raw X25519 public key)).

### 7.6 `POST /~andee@1.0/measure`

Constructs AndEE Android evidence for a measurement body.

Request fields:

- `body`: AO-Core measured body. Defaults to `{}`.
- `secret-recipient`: optional recipient message. If absent, the backend calls
  `subject` for `body`.
- `nonce`: optional raw or base64url nonce. If absent, 32 random bytes.
- `purpose`: optional string. `~measurement@1.0` passes `boot` or `fresh`.

The backend first builds an evidence subject:

```json
{
  "type": "andee-evidence-subject",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "context": "andee-android-evidence-v1",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "purpose": "boot",
  "nonce": "<base64url nonce bytes>",
  "issued-at-unix": 0,
  "body-id": "<stable-id(body)>",
  "secret-recipient-id": "<stable-id(secret-recipient)>"
}
```

Then it computes:

```text
evidence-subject-id = stable-id(evidence-subject)
```

It sends this AO-Core message and ID to the Android agent action
`sign-evidence`. The Android Keystore signature is over the UTF-8 bytes of the
`evidence-subject-id` string.

Response body on successful agent response:

```json
{
  "type": "andee-android-evidence",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "evidence-subject": {},
  "evidence-subject-id": "<stable-id(evidence-subject)>",
  "android-attestation-cert-chain": {
    "0": "<base64url DER leaf cert>",
    "1": "<base64url DER issuer cert>"
  },
  "keystore-signature": "<base64url ECDSA signature>",
  "attestation-challenge-subject": "{\"type\":\"andee-android-enrollment-subject\",...}",
  "policy-snapshot": {},
  "key-security-level": "STRONGBOX",
  "accepted": true,
  "verdict": "accepted"
}
```

Important exactness:

- `android-attestation-cert-chain` is produced by Android as a JSON object with
  decimal string keys in certificate order (`"0"` leaf, then issuers). Verifiers
  MAY also accept an array after materialization.
- `attestation-challenge-subject` is the Android agent's enrollment subject
  JSON string, not the evidence subject ID. The Android Key Attestation
  challenge MUST equal `SHA-256(UTF-8(attestation-challenge-subject))`.
- `keystore-signature` MUST verify over `UTF-8(evidence-subject-id)` using the
  public key in the leaf attestation certificate.
- `accepted` is the Android agent's current combined local and hardware policy
  verdict at signing time.

If the agent is unavailable or policy signing fails, the backend returns status
`200` with non-accepted evidence. A policy failure evidence body has:

```json
{
  "type": "andee-android-evidence",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "evidence-subject": {},
  "evidence-subject-id": "<stable-id(evidence-subject)>",
  "accepted": false,
  "verdict": "policy-failure",
  "policy-snapshot": {
    "accepted": false,
    "reason": "<detail>"
  }
}
```

Rejected environments are still measurable. External verifiers MUST treat them
as cryptographically useful evidence of a rejected environment, not as accepted
Tier A evidence.

### 7.7 Android Agent Interface

This is app-private local transport, not a public peer protocol. It is included
so third-party Android implementations can match the backend behavior.

Transport:

- Android filesystem namespace Unix-domain socket.
- Default socket path/name: `org.permaweb.andee.crypto`, overridden by
  `andee-agent-socket` or `ANDEE_CRYPTO_SOCKET`.
- Framing: 4-byte big-endian length prefix followed by UTF-8 JSON.
- Maximum frame accepted by Android: 1 MiB.

Request:

```json
{
  "type": "andee-agent-request",
  "version": "1.0",
  "action": "sign-evidence",
  "payload": {}
}
```

Response:

```json
{
  "status": "ok",
  "body": {}
}
```

Actions:

- `policy-status`: returns `accepted`, `supported`, `verdict`, and
  `policy-snapshot`.
- `sign-evidence`: signs `payload.evidence-subject-id`, returns policy,
  attestation chain, signature, challenge subject, key security level, and
  node key binding.
- `verify-evidence`: locally verifies an evidence object against current
  device policy and returns `verified` plus `verifier-checks`.

### 7.8 Android Keystore And Policy Snapshot

The Android agent uses:

```text
Android Keystore alias = andee_android_attestation_v1
key algorithm = EC secp256r1 / P-256
key purposes = SIGN | VERIFY
signature algorithm = SHA256withECDSA
attestation extension OID = 1.3.6.1.4.1.11129.2.1.17
```

Key generation:

1. Attempt StrongBox-backed generation on SDK >= 28.
2. If Android throws `StrongBoxUnavailableException`, retry with TEE-backed
   Keystore.
3. Set no user authentication requirement.
4. Set attestation challenge to
   `SHA-256(UTF-8(enrollment-challenge-subject))`.

Enrollment challenge subject JSON string:

```json
{
  "type": "andee-android-enrollment-subject",
  "version": "1.0",
  "package-name": "org.permaweb.andee",
  "release-digest": "<hex sha256 signer aggregate>",
  "measurement-device": "andee@1.0"
}
```

The exact string signed into the Android attestation challenge is Android
`JSONObject.toString()` output for those fields. Verifiers MUST compare the
Key Attestation challenge to SHA-256 of the UTF-8 bytes of the evidence field
`attestation-challenge-subject`.

The policy snapshot body contains:

```json
{
  "accepted": true,
  "local-policy-accepted": true,
  "package-name": "org.permaweb.andee",
  "version-name": "<BuildConfig.VERSION_NAME>",
  "version-code": 1,
  "release-digest": "<hex sha256 signer aggregate>",
  "signing-certificate-digests": {
    "0": "<base64url sha256 signer cert DER>"
  },
  "build-debug": false,
  "app-debuggable": false,
  "debugger-attached": false,
  "tracer-pid": 0,
  "adb-enabled": false,
  "sdk-int": 0,
  "security-patch": "YYYY-MM-DD",
  "min-os-patch-level": 0,
  "min-vendor-patch-level": 0,
  "min-boot-patch-level": 0,
  "bootloader": "<Build.BOOTLOADER>",
  "device": "<Build.DEVICE>",
  "manufacturer": "<Build.MANUFACTURER>",
  "android-attestation": {
    "accepted": true,
    "chain-signatures-valid": true,
    "root-trusted": true,
    "challenge-valid": true,
    "attestation-application-valid": true,
    "keymint-security-level": "STRONGBOX",
    "device-locked": true,
    "verified-boot-state": "VERIFIED",
    "verified-boot-key": "<base64url>",
    "verified-boot-hash": "<base64url>",
    "os-patch-level": 0,
    "vendor-patch-level": 0,
    "boot-patch-level": 0,
    "attestation-application-id": {}
  }
}
```

Local policy is accepted iff all are true:

- `BuildConfig.DEBUG == false`;
- application is not debuggable;
- `Debug.isDebuggerConnected() == false`;
- `/proc/self/status` has `TracerPid: 0`;
- `Settings.Global.ADB_ENABLED == 0`.

Hardware attestation policy is accepted iff all are true:

- every certificate verifies against the next certificate in the chain;
- the chain root SHA-256 fingerprint is in the bundled Android attestation root
  set;
- attestation challenge equals SHA-256 of `attestation-challenge-subject`;
- KeyMint security level is TEE or STRONGBOX;
- RootOfTrust `deviceLocked` is true;
- RootOfTrust `verifiedBootState` is VERIFIED;
- AttestationApplicationId contains the app package name;
- AttestationApplicationId signature digests intersect the app's own signer
  digest set;
- OS, vendor, and boot patch levels are greater than or equal to configured
  floors.

The agent's `accepted` field is:

```text
local-policy-accepted AND android-attestation.accepted
```

### 7.9 `POST /~andee@1.0/verify`

Verifies an AndEE measurement envelope.

Request fields:

- `envelope`: optional measurement envelope.
- `nonce`: optional verifier nonce.

Core checks performed by the backend:

1. Measurement envelope has `measurement-device = "andee@1.0"`.
2. If request `nonce` exists, it matches
   `evidence.evidence-subject.nonce` after base64url normalization.
3. `evidence.evidence-subject.body-id == stable-id(measurement.body)` or the
   verified AO-Core ID carried by a materialized bundled body.
4. `evidence.evidence-subject.secret-recipient-id ==
   stable-id(measurement.secret-recipient)`.
5. `evidence.evidence-subject-id ==
   stable-id(evidence.evidence-subject)`.
6. Android attestation certificate chain parses, validates to a bundled
   Android attestation root, and contains the Android Key Attestation
   extension.
7. The attestation challenge equals
   `SHA-256(UTF-8(evidence.attestation-challenge-subject))`.
8. `evidence.keystore-signature` verifies
   `UTF-8(evidence.evidence-subject-id)` with the leaf certificate public key.
9. Reported `key-security-level` matches the parsed KeyMint security level.

Response:

```json
{
  "verified": true,
  "verdict": "accepted",
  "checks": [
    {
      "name": "measurement device is andee@1.0",
      "ok": true,
      "severity": "core"
    },
    {
      "name": "Keystore signature subject binds body, nonce, and recipient",
      "ok": true,
      "severity": "core"
    },
    {
      "name": "Android attestation root is trusted",
      "ok": true,
      "severity": "core"
    }
  ],
  "facts": {
    "keymint-security-level": "TEE",
    "device-locked": true,
    "verified-boot-state": "VERIFIED"
  }
}
```

### 7.10 External Verifier Algorithm

An independent verifier MUST apply at least these provenance checks before
reporting cryptographically verified AndEE evidence:

1. Materialize all AO-Core links used by the measurement envelope.
2. Require envelope:
   - `type = "lapee-measurement"`;
   - `version = "1.0"`;
   - `measurement-device = "andee@1.0"`;
   - map `body`, `evidence`, and `secret-recipient`.
3. Require evidence:
   - `type = "andee-android-evidence"`;
   - `version = "1.0"`;
   - `measurement-device = "andee@1.0"`;
   - method equal to the constant in section 7.2.
4. Require evidence subject:
   - `type = "andee-evidence-subject"`;
   - `measurement-device = "andee@1.0"`;
   - `context = "andee-android-evidence-v1"`;
   - same method as evidence.
5. Recompute `stable-id(measurement.body)`, or use the verified AO-Core ID
   carried by a materialized bundled body, and compare it to
   `evidence-subject.body-id`.
6. Recompute `stable-id(measurement.secret-recipient)` and compare to
   `evidence-subject.secret-recipient-id`.
7. Recompute `stable-id(evidence-subject)` and compare to
   `evidence.evidence-subject-id`.
8. If verifying `/fresh`, compare verifier nonce to
   `evidence-subject.nonce`.
9. Do not reject otherwise valid AndEE evidence based on local wall-clock age.
   `/boot` is a stable attestation of the app/HB environment that produced it;
   `/fresh` provides nonce-bound liveness when a verifier needs a current
   challenge response.
10. Parse the Android attestation certificate chain in leaf-to-root order.
11. Verify every child certificate signature with its parent public key.
12. Require the root certificate fingerprint to be in the verifier's Android
    Key Attestation root set.
13. Parse leaf extension OID `1.3.6.1.4.1.11129.2.1.17`.
14. Require extension challenge equals
    `SHA-256(UTF-8(evidence.attestation-challenge-subject))`.
15. Parse KeyMint security level, RootOfTrust, AttestationApplicationId, patch
    levels, verified boot key/hash, package names, and signing digests. Expose
    them as facts; do not collapse them into a universal pass/fail policy.
16. Verify `evidence.keystore-signature` over
    `UTF-8(evidence.evidence-subject-id)` with the leaf certificate public key
    using ECDSA P-256/SHA-256 for current AndEE.

Zone templates or external callers decide whether parsed facts such as
`keymint-security-level`, `device-locked`, `verified-boot-state`,
`attestation-application-id`, local debug/ADB facts, package identity, signing
digest, and patch levels are acceptable for their deployment. `policy-snapshot`
and `evidence.accepted` are useful signed-node evidence, but they are not the
root of cryptographic verification.

### 7.11 `POST /~andee@1.0/wrap-secret`

Backend export for wrapping a secret to a `lapee-secret-recipient`.

Request fields:

- `subject`: required `lapee-secret-recipient`.
- `secret`: required base64url secret bytes.

Algorithm:

1. Decode `subject.public-material.x25519-public-key`.
2. Generate ephemeral X25519 keypair.
3. Compute X25519 ECDH shared secret.
4. Generate 32-byte random salt.
5. Generate 12-byte random IV.
6. Compute `subject-id = stable-id(subject)`.
7. Set `info = "andee-wrap-secret-v1:" || subject-id`.
8. Run HKDF-SHA256:
   - extract: `PRK = HMAC-SHA256(salt, shared-secret)`;
   - expand: RFC 5869 style blocks `T(n) = HMAC(PRK, T(n-1) || info || n)`;
   - output length 32 bytes.
9. Set AES-GCM AAD to the same bytes as `info`.
10. AES-256-GCM encrypt the secret using the HKDF key, IV, and AAD, producing
    ciphertext and 16-byte tag.

Response body:

```json
{
  "type": "lapee-wrapped-secret",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "subject-id": "<stable-id(subject)>",
  "ephemeral-public-key": "<base64url raw x25519 public key>",
  "salt": "<base64url 32 bytes>",
  "iv": "<base64url 12 bytes>",
  "ciphertext": "<base64url>",
  "tag": "<base64url 16 bytes>"
}
```

### 7.12 `POST /~andee@1.0/unwrap-secret`

Unwraps a `lapee-wrapped-secret` using the local VM-memory X25519 recipient key
and returns an activation proof.

Accepted request shapes:

- `{ "credential": <lapee-wrapped-secret> }`;
- `{ "wrapped-secret": <lapee-wrapped-secret> }`;
- the wrapped secret itself.

Decryption uses the inverse of section 7.11. If AES-GCM authentication fails,
the credential is rejected.

Activation response body before AO-Core commitment:

```json
{
  "type": "lapee-secret-activation",
  "version": "1.0",
  "measurement-device": "andee@1.0",
  "method": "android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm",
  "issued-at-unix": 0,
  "credential-secret-sha256": "<base64url sha256 unwrapped secret>",
  "proof-alg": "HMAC-SHA256",
  "credential-secret-proof": "<base64url HMAC-SHA256>"
}
```

The proof is:

```text
credential-secret-proof =
  base64url(HMAC-SHA256(secret, activation-context))
```

where `activation-context` is the exact UTF-8 byte string:

```text
lapee-secret-activation-v1
measurement-device:andee@1.0
method:android-keystore-attestation-x25519-hkdf-sha256-aes-256-gcm
issued-at-unix:<decimal issued-at-unix>
credential-id:<stable-id(credential)>
```

There is a newline after every line except the last line.

## 8. `~zone@1.0`

`~zone@1.0` forms shared identities whose admission is gated by live
measurement verification and the AndEE secret-recipient flow.

### 8.1 Exports

The device exports:

- `info`;
- `init`;
- `status`;
- `admit`;
- `join`;
- `member`.

Every successful response is AO-Core committed unless already committed by the
operation. Zone errors return status `400`. Unexpected failures return status
`500` with `error = "zone-failed"`.

### 8.2 `GET /~zone@1.0/info`

Returns status `200`:

```json
{
  "version": "1.0",
  "exports": ["info", "init", "status", "admit", "join", "member"]
}
```

### 8.3 Templates

A zone template is an AO-Core message pattern matched with
`hb_message:match(Template, Candidate, primary, Opts)`.

Template handling:

- `commitments` and `ao-types` are stripped recursively.
- The binary/string value `"_"` is converted to the wildcard atom `_`.
- Empty templates are forbidden for `init`.
- The following request fields are forbidden on `init`:
  - `aes-key`;
  - `wallet`;
  - `priv-zone-aes`;
  - `priv-zone-wallet`.

If a template contains any of `measurement-device`, `evidence`, `body`, or
`secret-recipient`, it is matched against the full measurement envelope with
selected keys materialized. Otherwise it is matched against the measurement
`body`.

### 8.4 `POST /~zone@1.0/init`

Initializes a local zone ring.

This endpoint is a state-mutating operator action. It is allowed by default.
Set `zone-init-allow` to `false`/`0` to disable initialization, or to a list
containing allowed zone names to restrict which zones may be initialized.
`zone-allow` still controls how many zones the node may install.

Request fields:

- `name`: required unless node option `zone-name` is set.
- `template`: required non-empty template.
- `self-url`: optional URL recorded for the initializer member.

Protocol:

1. Reject supplied secret material.
2. Fetch local `~measurement@1.0/boot`.
3. Select the template target as described in section 8.3.
4. Require the template to match the local attestation target.
5. Generate a 32-byte AES zone secret.
6. Generate a new Arweave wallet for the zone ring.
7. Add the local node as an `initializer` member if its measured node address
   is available.
8. Store private zone material in process memory under `priv-zones`.
9. Store public zone definition under `zones`.
10. Add identity `zone/<name>` backed by the zone wallet.
11. If `encrypted-volumes` enables this zone, activate the encrypted store as
    described in section 8.11.

Response is `zone-status` as in section 8.5.

### 8.5 `GET|POST /~zone@1.0/status`

If no zone name is supplied:

```json
{
  "type": "zone-status",
  "version": "1.0",
  "initialized": true,
  "zones": {
    "<name>": {}
  }
}
```

If a zone name is supplied:

```json
{
  "type": "zone-status",
  "version": "1.0",
  "initialized": true,
  "name": "<name>",
  "identity": "zone/<name>",
  "encrypted-volume": {
    "enabled": true,
    "opened": true,
    "store-id": "<base64url sha256 id or null>"
  },
  "zone": {
    "type": "zone-definition",
    "version": "1.0",
    "name": "<name>",
    "identity": "zone/<name>",
    "ring-address": "<zone wallet address>",
    "ring-reference": {
      "type": "zone-ring-reference",
      "version": "1.0",
      "name": "<name>",
      "ring-address": "<zone wallet address>",
      "template-id": "<AO-Core ID>"
    },
    "template-id": "<AO-Core ID>",
    "template": {},
    "members": {}
  }
}
```

`template-id` is:

```text
hb_message:id({
  "type": "zone-template",
  "name": name,
  "template": clean-template(template)
}, all, Opts)
```

### 8.6 `POST /~zone@1.0/admit`

Admits a live joiner into an initialized zone.

Request fields:

- `name`: required unless node option `zone-name` is set.
- `joiner-url`: required. A trailing slash is stripped.
- `admission-nonce`: optional caller-supplied nonce echoed into the signed
  admission. `join` always supplies one.
- `trusted-ca`: optional transport field forwarded to peer HTTP.

Protocol:

1. Require the local zone ring to exist.
2. Construct the zone `ring-reference`.
3. Verify the joiner by calling local
   `~measurement@1.0/verify-peer` with:
   - `url = joiner-url`;
   - `peer-attestation-scope = ring-reference`.
4. Require the returned `zone-peer-attestation` to pass section 8.7.
5. Extract the joiner's boot measurement target and require it to match the
   zone template.
6. Extract `peer-credential-subject` from the peer attestation.
7. Wrap the zone AES secret to that subject using `~measurement@1.0`'s
   secret-recipient backend.
8. Encrypt the zone wallet with the zone AES secret.
9. Add/update the joiner as a `member`.
10. Return a ring-signed `zone-admission`.

Response body:

```json
{
  "type": "zone-admission",
  "version": "1.0",
  "name": "<name>",
  "issued-at-unix": 0,
  "validity": {
    "not-before-unix": 0,
    "expires-at-unix": 0
  },
  "admission-nonce": "<caller nonce or null>",
  "ring-reference": {},
  "zone": {},
  "joiner-url": "http://joiner:8734",
  "template": {},
  "peer-attestation": {},
  "credential": {},
  "encrypted-wallet": {
    "alg": "AES-256-GCM",
    "iv": "<base64url 12 bytes>",
    "tag": "<base64url 16 bytes>",
    "ciphertext": "<base64url ar_wallet JSON>"
  },
  "ring-address": "<zone wallet address>",
  "authorization": {}
}
```

Wallet encryption:

- algorithm: AES-256-GCM;
- key: zone AES secret;
- IV: 12 random bytes;
- plaintext: `ar_wallet:to_json(Wallet)`;
- AAD: exact UTF-8 bytes `zone-wallet-v1`;
- tag length: 16 bytes.

Admission validity:

- default TTL: 300 seconds;
- option: `zone-admission-ttl-seconds`;
- `not-before-unix` and `expires-at-unix` are signed metadata. The joiner only
  requires both integers and `not-before-unix <= expires-at-unix`; replay
  protection comes from `admission-nonce`.

### 8.7 Peer Attestation Requirements For Zones

`admit` requires the peer attestation to contain:

- `type = "zone-peer-attestation"`;
- positive integer `issued-at-unix`;
- `boot-verification.verified = true`;
- `verification.verified = true`;
- `freshness.verified = true`;
- `credential-activation.verified = true`;
- map `validity`;
- map `peer-scope`;
- map `peer-credential-subject`;
- map `peer-boot-attestation`;
- map `peer-fresh-attestation`.

Time validity:

- Default clock skew: 300 seconds via `zone-clock-skew-seconds`.
- Default maximum peer attestation age: 3600 seconds via
  `zone-peer-attestation-max-age-seconds`.
- `issued-at-unix` and `validity.not-before-unix` MUST be no later than
  `now + skew`.
- `validity.expires-at-unix`, if present, MUST be no earlier than
  `now - skew`.
- `issued-at-unix + max-age + skew` MUST be no earlier than `now`.

Scope binding:

- `peer-scope.consumer-scope.name` MUST equal `ring-reference.name`.
- `peer-scope.consumer-scope.ring-address` MUST equal
  `ring-reference.ring-address`.
- `peer-scope.consumer-scope.template-id` MUST equal
  `ring-reference.template-id`.
- `peer-scope.peer-url` MUST equal top-level `peer-url` after trailing slash
  normalization.
- `peer-scope.boot-attestation-id` MUST equal the AO-Core ID of
  `peer-boot-attestation`.
- `peer-scope.fresh-attestation-id` MUST equal the AO-Core ID of
  `peer-fresh-attestation`.
- `peer-scope.measurement-device` MUST equal
  `peer-credential-subject.measurement-device`.
- `peer-scope.secret-recipient-id` MUST equal
  `stable-id(peer-credential-subject)`.

### 8.8 Admission Authorization

`zone-admission.authorization` is an AO-Core committed message signed by the
zone ring wallet. It MUST be verified before a joiner accepts an admission.

Authorization scalar fields copied exactly from the admission:

- `name`;
- `issued-at-unix`;
- `admission-nonce`;
- `joiner-url`;
- `ring-address`.

Authorization ID fields:

| Authorization field | Admission field |
| --- | --- |
| `validity-id` | `validity` |
| `ring-reference-id` | `ring-reference` |
| `zone-id` | `zone` |
| `template-id` | `template` |
| `peer-attestation-id` | `peer-attestation` |
| `credential-id` | `credential` |
| `encrypted-wallet-id` | `encrypted-wallet` |

Each authorization ID value is `stable-authorization-payload-id` of the
corresponding admission field. For maps this is the AO-Core uncommitted ID after
loading links and recursively removing `commitments` and `ao-types`.

The authorization message also includes:

```json
{
  "type": "zone-admission-authorization",
  "version": "1.0",
  "template-matched": "true"
}
```

Joiners MUST verify:

- the authorization's AO-Core commitments verify;
- the signer list contains `ring-address`;
- every scalar field matches the admission;
- `template-matched = "true"`;
- every authorization ID field matches the corresponding admission payload.

### 8.9 `POST /~zone@1.0/join`

Joins an existing zone through a peer.

Request fields:

- `name`: required unless node option `zone-name` is set.
- `peer-url`: required unless node option `zone-peer-url` is set.
- `self-url`: required unless `zone-self-url` or `public-url` is set.
- `expected-ring-address`: required unless node option `zone-ring-address` is
  set.
- `trusted-ca`: optional transport field forwarded to peer HTTP.

Protocol:

1. Generate a base64url 32-byte `admission-nonce`.
2. POST to peer `/~zone@1.0/admit` with `name`, `joiner-url = self-url`, and
   the admission nonce.
3. Require response `type = "zone-admission"`.
4. Require response `name` matches request.
5. Require response `joiner-url` equals `self-url` after trailing slash
   normalization.
6. Require response `admission-nonce` equals generated nonce.
7. Require map fields: `validity`, `ring-reference`, `authorization`,
   `credential`, `encrypted-wallet`, and `peer-attestation`.
8. Require binary `ring-address`.
9. Verify admission authorization per section 8.8.
10. Require admission validity has integer `not-before-unix` and
    `expires-at-unix` with `not-before-unix <= expires-at-unix`.
11. Require admission `ring-address` equals `expected-ring-address`.
12. Require `peer-attestation.peer-url` equals `self-url`.
13. Require `ring-reference.ring-address` and `ring-reference.name` match
    top-level admission fields.
14. Unwrap `credential` locally through `~measurement@1.0`.
15. Decrypt `encrypted-wallet` with the unwrapped AES secret.
16. Require decrypted wallet address equals admission `ring-address`.
17. Install private zone AES/wallet and public zone definition in memory.
18. If `encrypted-volumes` enables this zone, activate the encrypted store as
    described in section 8.11.

Response is `zone-status`.

### 8.10 `GET|POST /~zone@1.0/member`

Returns a narrow zone-signed membership proof.

Request fields:

- zone name from `member`, `zone`, `name`, or node option `zone-name`;
- `target`: optional binary target included in the proof;
- `membership-codec-device`: optional commitment device used for the proof.

Response body before commitment:

```json
{
  "type": "zone-membership-proof",
  "version": "1.0",
  "address": "<local node address>",
  "member-of": "<zone name>",
  "identity": "zone/<zone name>",
  "ring-address": "<zone wallet address>",
  "issued-at-unix": 0,
  "member": {
    "address": "<member node address>",
    "url": "http://node:8734",
    "role": "member",
    "last-seen-unix": 0
  },
  "operator": "<optional operator>",
  "target": "<optional target>"
}
```

The proof is committed as identity `zone/<name>` using the zone wallet.

### 8.11 Zone Encrypted Stores

Encrypted stores are not a new public device protocol. They are live node
configuration changes performed by `~zone@1.0` after a zone AES secret has been
created by `init` or unwrapped by `join`.

Node option:

```json
{
  "encrypted-volumes": true
}
```

Accepted values:

- absent or `false`: do not open encrypted stores;
- `true`: open an encrypted store for every initialized or joined zone;
- list of binaries: open only when the list contains the zone name,
  `zone/<name>`, or the zone ring address.

Activation:

1. Compute `store-id = base64url(SHA-256(term_to_binary({andee_encrypted_volume, name, ring_address})))`.
2. Register the 32-byte zone AES secret in process memory under `store-id`.
3. Construct a store message:

```json
{
  "store-module": "hb_store_andee_encrypted",
  "name": "<private encrypted volume directory>",
  "zone": "<zone name>",
  "ring-address": "<zone wallet address>",
  "store-id": "<store-id>",
  "secret-ref": "<store-id>"
}
```

4. Start the store through `hb_store:start`.
5. Copy the existing live stores into the encrypted store through the normal
   `hb_store:type`, `hb_store:list`, `hb_store:read`, `hb_store:group`, and
   `hb_store:write` interface.
6. Ensure the encrypted root group is persisted.
7. Prepend the encrypted store to live `Opts.store`.

The store message MUST NOT contain the AES secret. Implementations MUST treat
`secret-ref` as an in-memory lookup key, not as key material.

`hb_store_andee_encrypted` holds live state in ETS and persists one
`store.bin` append-only log under the private volume directory. It MUST expose
the normal `hb_store` callbacks without requiring callers to use any
AndEE-specific read/write API. `write`, `group`, `link`, and `reset` MUST
update the live ETS state before returning, enqueue exactly one logical
operation record, and MUST NOT rewrite the full store image as part of the
normal operation path. `stop` and the explicit `hb_store_andee_encrypted:flush`
helper MUST flush pending records before returning.

The log is a byte stream of frames:

```erlang
<<FrameLength:32/unsigned-big-integer, Frame:FrameLength/binary, ...>>
```

Each `Frame` is an Erlang term envelope containing only metadata required to
decrypt one encrypted operation payload:

```erlang
#{
  <<"magic">> => <<"andee-encrypted-store-log-v1">>,
  <<"version">> => 1,
  <<"seq">> => Seq,
  <<"iv">> => IV,
  <<"tag">> => Tag,
  <<"ciphertext">> => CipherText
}
```

The encrypted plaintext is:

```erlang
#{
  <<"version">> => 1,
  <<"seq">> => Seq,
  <<"op">> => reset | {group, Key} | {write, Key, Value} | {link, New, Existing}
}
```

Encryption:

- algorithm: AES-256-GCM;
- content encryption key:
  `HMAC-SHA256(zone_aes, term_to_binary({magic, zone, ring_address}))`;
- IV: 12 fresh random bytes for every log frame;
- AAD:
  `term_to_binary({magic, zone, ring_address, store_id, seq})`;
- sequence: frames MUST replay from sequence `1` without gaps. A trailing
  partial frame MAY be ignored as an interrupted append, but a complete frame
  that fails decode, authentication, or sequence validation MUST make the store
  fail to open. If an implementation ignores a trailing partial frame, it MUST
  truncate the file back to the last complete authenticated frame before
  appending any new records.

Flush behavior:

- default periodic flush interval: 50 ms;
- `flush-interval-ms = 0`: enqueue an immediate owner-process flush message;
- `sync-on-flush = true`: call `file:sync/1` after a successful append batch;
- normal `hb_store` writes remain live immediately through ETS and do not block
  on disk unless a caller explicitly invokes the AndEE flush helper.

Android runtime root:

- production app path: app-private `noBackupFilesDir/encrypted-zones`;
- host/test override: node option `encrypted-volume-root`.

`zone-status.encrypted-volume` reports only public state:

- `enabled`: whether policy selects this zone;
- `opened`: whether the live node `Opts.store` contains the matching encrypted
  store;
- `store-id`: the deterministic public ID above, or `null` if no ring address
  is available.

## 9. Error Bodies

Device errors are AO-Core response bodies. Common errors:

| Device | HTTP status | `error` |
| --- | ---: | --- |
| `~measurement@1.0/boot` | 500 | `measurement-boot-failed` |
| `~measurement@1.0/fresh` | 500 | `measurement-fresh-failed` |
| `~measurement@1.0/verify-peer` | 400 | `missing-peer-url` |
| `~measurement@1.0/verify-peer` | 502 | `measurement-verify-peer-failed` |
| `~andee@1.0/measure` | 500 | `andee-measure-failed` |
| `~andee@1.0/unwrap-secret` | 500 | `andee-unwrap-secret-failed` |
| `~zone@1.0/*` expected user/protocol error | 400 | specific zone error |
| `~zone@1.0/*` unexpected failure | 500 | `zone-failed` |

Zone-specific `error` values include:

- `secret-material-forbidden`;
- `zone-not-initialized`;
- `node-address-unavailable`;
- `zone-not-member`;
- `encrypted-volume-failed`;
- `missing-name`;
- `missing-zone`;
- `missing-peer-url`;
- `missing-self-url`;
- `missing-joiner-url`;
- `empty-template`;
- `self-attestation-failed`;
- `template-mismatch`;
- `peer-verification-failed`;
- `peer-attestation-invalid`;
- `admission-request-failed`;
- `admission-invalid`;
- `expected-ring-address`;
- `credential-activation-failed`;
- `wallet-decryption-failed`;
- `bad-encrypted-wallet`;
- `ring-wallet-address-mismatch`;
- `measurement-device-unavailable`.

## 10. Minimal HTTP Interop Examples

Fetch boot evidence:

```sh
curl -sS 'http://ANDEE_HOST:8734/~measurement@1.0/boot'
```

Fetch nonce-bound fresh evidence:

```sh
NONCE="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
curl -sS "http://ANDEE_HOST:8734/~measurement@1.0/fresh?nonce=$NONCE"
```

Verify a peer from another AndEE:

```sh
curl -sS -X POST 'http://LOCAL_HOST:8734/~measurement@1.0/verify-peer' \
  -H 'content-type: application/json' \
  --data '{"url":"http://PEER_HOST:8734"}'
```

Initialize a zone:

```sh
curl -sS -X POST 'http://LOCAL_HOST:8734/~zone@1.0/init' \
  -H 'content-type: application/json' \
  --data '{"name":"example","template":{"measurement-device":"andee@1.0"}}'
```

Join a zone:

```sh
curl -sS -X POST 'http://JOINER_HOST:8734/~zone@1.0/join' \
  -H 'content-type: application/json' \
  --data '{
    "name":"example",
    "peer-url":"http://RING_HOST:8734",
    "self-url":"http://JOINER_HOST:8734",
    "expected-ring-address":"<zone ring address>"
  }'
```

For verifier development, prefer collecting materialized evidence through
`scripts/materialize-ao-json.py` or HyperBEAM/HyperBuddy formatting so `+link`
values are expanded before external validation.
