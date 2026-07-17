# Andock measurement boundary

Status: accepted design; exact artifact values follow the frozen production
build.

## Decision

Do not change `~measurement@1.0` or the Android `~andee@1.0` evidence protocol
for Andock. The existing measurement body already commits to both:

1. `~system@1.0/all`, including Android/APK/runtime artifact identity; and
2. `~meta@1.0/info`, including the effective node message.

Andock adds verifier-readable facts beneath the Android system report. It does
not add another measurement engine, another subject calculation, or a special
Ouroboros attestation path.

## Immutable facts

The final `~system@1.0/all` runtime report must expose one `execution` map with
at least:

- device and protocol version (`andock@1.0`);
- Android ABI (`arm64-v8a`);
- PRoot source revision, patch-set revision, and packaged binary digest;
- filesystem engine name, source revision, patch-set revision, and packaged
  binary digest;
- immutable filesystem-template digest and logical size;
- Ubuntu snapshot, provisioner revision/digest, package-lock digest, and
  installed-package manifest digest;
- isolated-UID/SELinux policy version;
- network capability policy version; and
- default capacity/concurrency policy where it changes the trusted runtime.

These values originate in the Android packaging/runtime manifest, enter
HyperBEAM through reserved `ANDEE_*` environment facts, and cannot be
overridden by imported node configuration. Wire-visible digests are
base64url-encoded bytes rather than new hexadecimal identifiers.

The selected execution device and operator-selected resource/network policy
remain ordinary effective node-message fields. `~meta@1.0/info` already places
them in the measured body; AndEE must not special-case or duplicate them.

## Existing aggregate commitments

The filesystem template and native execution libraries are packaged as
immutable APK/runtime assets. The existing runtime ZIP, native-library set,
base APK, APK set, and Android signing-certificate facts therefore remain the
primary byte-level commitments. Explicit execution facts make verifier policy
readable; they do not replace or weaken those aggregate hashes.

Startup verifies every explicit digest against the packaged asset before the
execution service becomes available. A changed engine, PRoot build, template,
or immutable manifest must either produce a different measurement body or fail
startup.

## Explicit exclusions

Do not measure:

- per-member filesystem images;
- sparse allocation state or physical block count;
- installed packages or files added by a member;
- active worker PIDs/isolated UIDs;
- command output, temporary memfds, or lifecycle generation; or
- mutable workspace indexes.

Those are runtime state. Measuring them would make ordinary member work alter
the boot subject and destroy restart comparability.

## Branch consequence

`agent/andock-measurement` at `9ff70109` must not be merged. It describes the
parked `android-app-broker@1` prototype and changes the wrong layer. The final
measurement component is limited to reserved Android bootstrap facts,
`dev_system` reporting/tests, verifier expectations, and specification text
after the production artifact manifest is frozen.

## Acceptance

- Unchanged APK/runtime/config produces the same boot subject.
- Changing the selected execution device or measured policy changes the node
  portion of the subject.
- Changing any packaged execution binary, template, or immutable manifest
  changes the system portion or fails startup.
- An external verifier rejects an unexpected device, engine, template digest,
  or network policy.
- Writes and package installs inside a member image do not change the boot
  subject.
