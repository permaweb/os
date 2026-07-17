# HyperBEAM fcdf runtime contracts

## Prompt

Advance LapEE and AndEE from exact HyperBEAM edge
`e445aad9da2a3017023ce99bd934540729e3b872` to
`fcdf5867686c64a8abe79e04e10f3590fbd62b7f`. Reassess the full upstream range
instead of assuming that an exact-pin replacement is sufficient, and preserve
real native execution on each packaged target.

## Evidence

The final upstream tree delta is only 25 added lines in
`src/core/http/hb_http.erl`. It adds a `get_host/2` helper and includes the
request host in HTTP response log metadata. There is no final-tree change to
HyperBEAM dependencies, Forge, devices, native code, build hooks, release
configuration, or submodules. Intermediate name-device edits in the commit
range are absent from the target tree.

Both LapEE packagers normalize `hb_buildinfo` from the selected source rather
than wall-clock time, so the source epoch changes from `1784173208` to fcdf's
commit epoch `1784211633` together with the source pin.

## Decision

Update only the six active dependency/build pin files and their normalized
epoch. Retain the e445 integration contracts unchanged:

- Forge reads and writes the real preloaded LMDB index.
- `trusted-device-signers` remains the remote implementation authorization
  boundary.
- Android and Buildroot package mandatory native components instead of
  fallbacks.
- Buildroot keeps host Forge separate from its x86-64 target release.
- The declared PermawebOS device source closure remains five paths.
- AO decoding and device resolution remain generic.

No measurement-device edit is required. Existing PermawebOS measurement
already commits the effective node message and packaged runtime artifacts, and
the package provenance itself changes to fcdf in both shipped `hb_buildinfo`
copies. Adding another measurement field for an HTTP logging-only upstream
change would duplicate evidence without creating a new trust boundary.

## Validation consequence

The upstream delta is small, but the exact source participates in attested
runtime artifacts. Therefore the acceptance gate remains a clean dependency
compile, device EUnit, complete Android runtime/APK build with native audits,
and complete Buildroot target build with preloaded-store and target-ELF audits.
The unchanged Buildroot replay must reproduce the kernel and initramfs hashes.
