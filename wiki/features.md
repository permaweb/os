# LapEE Product Feature Contract

LapEE is a single-purpose HyperBEAM appliance OS for commodity laptops and
TEE-backed VMs. The product is not "Linux with many hardening knobs"; it is a
bootable node that produces useful AO-Core work and exposes enough measured
evidence for other nodes or users to decide whether to trust its results.

## End-User Features

1. Boot a signed appliance image from USB, join the configured network, detach
   boot media from the runtime path, and start exactly one HyperBEAM node.
2. Display the node URL and QR code on the local screen once HyperBEAM is
   serving.
3. Produce a cached boot measurement before the HTTP interface is publicly
   useful.
4. Produce fresh nonce-bound measurements on request.
5. Bind the measurement to the node message, system report, node signing key,
   and hardware measurement backend.
6. Support TPM 2.0 laptops and AMD SEV-SNP VMs through the same public
   measurement protocol.
7. Verify peer measurements live and publish signed peer attestations that can
   later be trusted by parties that trust the verifier address.
8. Create and join named zones whose templates match normalized measurement
   messages.
9. After admission, load a shared zone identity and return a membership proof
   signed by that zone identity.
10. Provision Secure Boot keys without Windows when firmware is in setup mode.
11. Provision optional encrypted zone storage on a user-selected disk.
12. Reopen encrypted zone storage only after a successful join to the matching
    zone.
13. Expose policy-neutral system evidence: Secure Boot state, PCR/event-log
    facts, node config, runtime command line, CPU/platform facts, memory/probe
    evidence, ACPI summaries, TPM evidence, and SNP evidence.

## Non-Features

These are not part of the v1 service and must not survive merely because old
code implemented them:

- A public `~tpm-interpret@1.0` verifier/explainer API.
- A TPM-specific peer verification protocol separate from `~measurement@1.0`.
- Trust scores or device-side policy judgments.
- Historical catalogue matching for arbitrary operating systems beyond what is
  needed to explain LapEE evidence.
- Compatibility shims for pre-v1 message shapes.
- Runtime debug shells, local input surfaces, or arbitrary protected-identity
  signing endpoints in production images.
- Broad firmware archaeology that does not feed a current measurement, system,
  zone, provisioning, or nonvolatile-storage flow.

## Compression Rule

When old code performs more work than this contract requires, keep the smaller
implementation. A removed branch is acceptable when:

- it is not needed by the feature list above,
- the cut ledger records the removal, and
- local or remote acceptance tests still pass.
