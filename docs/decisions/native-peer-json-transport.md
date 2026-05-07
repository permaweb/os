# Decision: Native Peer JSON Transport

## Context

LapEE still has one bespoke peer HTTP helper:
`hyperbeam-overlay/src/lapee_http_json.erl`. This note records why it remains
for now and what should replace it once HyperBEAM exposes the right native
client surface.

## Root Cause

`lapee_http_json` is a local transport adapter, not a new application protocol.
It exists because the peer attestation and green-zone paths need to fetch and
post bundled AO-Core JSON messages over plain HTTP, with predictable timeout
handling and without depending on OS CA material. The normal `hb_http` path gets
close for GETs, but its current response handling can collapse `ao-result`
messages and its request machinery is broader than these peer handshakes need.

The bespoke part that conflicts with the preferred AO-Core shape is local:
manual HTTP framing, direct `hb_json` encode/decode, and JSON `ao-types` atom
repair before signature verification. The direct callers in `dev_tpm2` and
`dev_green_zone` then unwrap status/body maps around this helper. Replacing that
cleanly should happen through a HyperBEAM-native client surface, not by adding a
second LapEE compatibility layer.

Script harness JSON remains acceptable at the operator/test edge. The tracked
`build/hyperbeam/src-edge` references found in scripts and docs point at the
disposable generated checkout under `build/`; no tracked checkout artefacts were
found in this pass.

## Decision

Keep `lapee_http_json` for now and only harden behavior that does not affect the
wire contract.

The future path is to add or expose a HyperBEAM client mode that:

1. Sends `accept: application/json@1.0` and `accept-bundle: true`.
2. Supports GET and POST of AO-Core messages over plain HTTP.
3. Returns the decoded message envelope without the `ao-result` shortcut.
4. Uses `dev_codec_json`/message conversion rather than local `ao-types` repair.
5. Allows LapEE to keep explicit peer connect/read timeouts.

Once that exists upstream, replace the two direct callers and delete
`lapee_http_json`.
