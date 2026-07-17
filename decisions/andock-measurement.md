# Andock measurement boundary

Status: accepted; no measurement-device change is required for Andock v1.

## Decision

Do not change `~measurement@1.0`, `~andee@1.0`, or `~system@1.0` for Andock.
The existing measurement body already commits to both relevant inputs:

1. `~system@1.0/all` commits to the installed APK set, signing certificate,
   runtime ZIP, native launcher, and native-library set; and
2. `~meta@1.0/info` commits to the effective node message, including the
   operator-selected execution device and its policy.

The deterministic ext4 template and its manifest are entries in the measured
runtime ZIP. PRoot, its loader, and the Andock launcher are entries in the
measured native-library set. Their pinned source revisions and individual
digests remain in the packaged build manifests. Adding a second projection of
the same facts to the measurement device would duplicate the trust decision
without strengthening the cryptographic commitment.

The parked `agent/andock-measurement` branch must not be merged. It describes
the obsolete app-broker prototype and adds an Andock-specific measurement
surface where none is needed.

## Mutable state

Per-member images are created outside the immutable runtime tree. Package
installs, workspace files, sparse allocation state, active worker IDs,
temporary memfds, and command output therefore do not enter the boot
measurement. This is intentional: ordinary member work must survive restart
without changing the immutable runtime identity.

## Verification consequences

An external policy can enforce Andock by checking the cryptographically
verified aggregate artifact facts and the measured effective node message. It
may additionally parse the packaged manifests when it needs the individual
PRoot, loader, launcher, template, Ubuntu snapshot, or provisioning revision.
That parser is verifier policy, not another AO device or subject algorithm.

The complete measurement-body ID is not expected to be stable across app
restarts: AndEE currently reports a generation timestamp and creates an
ephemeral node identity. Tests compare the immutable system-artifact projection
and the intended effective-config projection instead.

`RuntimeExtractor` verifies the template while expanding a newly installed
runtime and records the runtime marker. A subsequent launch trusts that cached
private extraction when the marker still matches. A debugger or rooted actor
with the application UID can therefore mutate the cached expanded image after
installation without changing the packaged runtime-ZIP digest. That actor is
outside the ordinary unrooted-phone threat boundary; the isolated Andock guest
cannot reach the cached template or application-private tree. Rehashing the
logical 8 GiB template at every launch would add material startup cost and is
not part of v1.

## Acceptance

- Changing any packaged execution binary, template, or immutable manifest
  changes an existing APK/runtime aggregate or fails fresh extraction.
- Changing the selected execution device or its measured node policy changes
  the effective-config projection.
- Member writes and package installs leave the immutable artifact projection
  unchanged.
- The Andock worker cannot read or modify the runtime ZIP, cached template,
  effective config, wallet, crypto socket, or another member image.
