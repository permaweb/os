# Android AndEE Architecture

AndEE is the Android Execution Environment for PermawebOS. It packages
HyperBEAM as an Android app/runtime and uses Android Verified Boot plus
Android Keystore/StrongBox attestation as the local measurement engine.

- `android/` is the Gradle Android app.
- `config/andee.json` is the base HyperBEAM config packaged into the runtime.
- `runtime-src/` contains the Android native launcher and Erlang overrides.
- `scripts/` contains Android SDK, runtime, emulator, and scenario harnesses.
- `secondary-external-verifier/` contains Android attestation verifier assets.
- `specs/andee-device-specification.md` contains the AndEE device
  specification.

Android stages the package from `devices/common/` plus the Android-specific
overlay in `devices/android/`. The shared measurement and zone devices are
therefore identical to the Linux builds; the Android overlay contributes the
AndEE crypto-agent runtime for local measurements, Android system reporting,
app-private encrypted storage, service devices, and the generic `andock@1.0`
execution device. The `andee@1.0` name remains the measurement backend
identifier.

## Andock execution capability

The APK preloads `~andock@1.0` and packages its generic local capability.
Each member receives a complete writable sparse ext4 image copied from a
measured, deterministic Ubuntu 24.04 template. An Android isolated service
receives only that image descriptor and the command/network capabilities for
one operation. PRoot supplies Linux pathname and syscall compatibility; the
security boundary is Android's separate isolated UID and SELinux domain, not
PRoot. The worker cannot open the app-private runtime, config, wallet, crypto
socket, cached template, or another member image.

The member image is intentionally not an overlay: `/usr`, `/etc`, `/var`,
`/tmp`, and `/root` are all writable, so APT, pip, venv, npm, native compilers,
and ordinary root-oriented build tools can modify the system normally. Sparse
copy and sparse writeback avoid charging holes to Android storage, while both
member creation and runtime writeback preserve 512 MiB of host free space.
Guest ownership is fake-root rather than a multi-user DAC boundary, and
runtime xattrs are limited to `user.*`; Android UID/SELinux isolation remains
the authority boundary.

When networking is disabled, the isolated worker receives no Internet socket
capability. When enabled, the app brokers only TCP/UDP descriptors and the
native syscall layer rejects local/private/reserved destinations on every
destination-bearing operation. Inbound/listening Internet sockets are not
supported. UDP clients may bind only a wildcard ephemeral port; each
unconnected send pins kernel receive filtering to that authorized reply peer
and drains datagrams queued before the peer was selected. Multi-message sends
on an unconnected socket must use one peer, and receive calls fail until a peer
is selected. Repeated sends to the same peer preserve queued replies; UDP
disconnect is denied so another thread cannot remove the receive filter.
Physical-phone IPv6/NAT64 behavior is a release acceptance gate.

The release build is ARM64-only. Build the pinned template independently with:

```sh
make -C arch/android andock-template
```

`make -C arch/android apk` validates or rebuilds the runtime and template,
cross-builds the pinned native PRoot/lwext4 adapter, and packages both into the
normal AndEE runtime and APK. Images remain ignored under `arch/android/build/`;
no rootfs or member state is committed to git.

The APK is an application-agnostic platform artifact. Application device
packages are loaded after boot through measured JSON configuration,
`trusted-device-signers`, and `name-resolvers`; no application checkout,
archive, payload, or provenance participates in the Android build.

The packaged HyperBEAM preload uses a public, deterministic Ed25519 build
identity rather than the node wallet. That identity is not an authorization
root: the measured APK/runtime remains the trust boundary. The build rewrites
the preload through a sorted LMDB dump/load pass and packages the runtime with
fixed timestamps and entry order, so unchanged inputs on the pinned build
host/toolchain produce byte-identical runtime ZIP and APK artifacts.

The running node follows stock HyperBEAM `priv-key-location` semantics. When
the operator does not select a location, Android supplies an app-private file
under `noBackupFilesDir/node-identity/`; it survives service and app-process
restarts but is removed with app data. Its path and key material are not
runtime facts and are never passed to an Andock worker.

The normal HyperBEAM primary store is likewise an app-private LMDB sibling of
the replaceable runtime directory. LMDB provides atomic link replacement under
concurrent cache writes, while a bounded write batch limits the uncommitted
overlay used by the pinned stock backend. Release acceptance force-stops the
app immediately after acknowledged application operations and proves recovery
of their process graph; an arbitrary write-only LMDB call is not claimed to be
synchronously durable merely because it returned. Stateful devices retain
process graphs and bootstrap links without an Android-specific state protocol.
Gateway-fetched archives are verified through the measured preloaded store but
are not redundantly materialized into the primary store.

The complete design, compatibility limits, and release gates are recorded in
`../../decisions/andock-filesystem-capability.md`.
