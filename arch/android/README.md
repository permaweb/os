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

Complete redacted operator overlays live in `../../sample-configs/`. Import a
private copy through the app's **Next boot config** picker; the overlay is
merged with this application-agnostic base config and measured at the next
boot. `scripts/prepare-deployment-config.py` can populate an ignored private
copy by applying any private JSON Merge Patch to any public template, without
knowing about its devices or applications and without printing secrets.

Android stages the package from `devices/common/` plus the Android-specific
overlay in `devices/android/`. The shared measurement and zone devices are
therefore identical to the Linux builds; the Android overlay contributes the
AndEE crypto-agent runtime for local measurements, Android system reporting,
app-private encrypted storage, service devices, the generic `andock@1.0`
execution device, and the generic `andee-inference@1.0` local-compute provider. The
`andee@1.0` name remains the measurement backend identifier.

## Local inference capability

The APK preloads `~andee-inference@1.0`, packages LiteRT-LM for CPU, GPU, and NPU
execution, and packages a pinned ARM64 llama.cpp runtime for CPU-only GGUF
models. A generic `inference@1.0` device can select it through an
`inference-providers` entry; the APK does not replace that multiplexer. The
backend is measured per model and cannot be selected by a request. The Android
emulator has no mobile NPU, so its acceptance test proves real model execution
on CPU without claiming hardware-accelerator evidence.

Models are not APK assets. Measured provider entries identify them by
43-character Arweave `model-id`, exact byte length, runtime, and backend.
HyperBEAM resolves every ID through `hb_cache` using the remote-indexed Arweave
store before the legacy gateway fallbacks, then passes an ID-derived private
path to Android. The Android broker has no model download client; host filenames,
URLs, and parallel model digests are not configuration. GGUF entries are ARM64
CPU-only.
The shipped `local-andee` provider defaults to the Tensor G5 Gemma 4 E2B
manifest `eq7Oh5TPjLMvEwpw7vlRtTsArjfYiCNCTAE3d3XhTIo` and also exposes the
FunctionGemma mobile-actions manifest
`wV_QpsZwdNW09poKoOCyo38BCx5Pg64aajoQTEao0d0` for CPU tool-use checks.
Run the end-to-end emulator proof against the measured catalogue and normal
AO-Core materializer:

```sh
ADB_SERIAL=emulator-NNNN \
make -C arch/android inference-emulator-smoke
```

On an Apple ARM64 emulator, that target first builds the exact LiteRT-LM
0.16.1 and XNNPACK revisions with SME dispatch disabled, verifies the JNI and
FunctionGemma constraint-provider digests, replaces only the emulator APK's
ARM64 JNI and its required constraint provider, re-signs it, and reruns the
generic artifact scan. This works around an emulator-only false SME/SME2
capability report; the normal APK retains Google's pinned Maven binary.

The pinned open LiteRT-LM runtime is part of the measured APK. Google Tensor
NPU models remain SoC-specific AOT artifacts and must include an explicit SoC
allowlist. The Tensor compiler/runtime terms and model licenses apply to the
operator-provisioned artifacts; they are not vendored by this repository.
The Tensor G5 E2B entry uses a 4,096-token context so a normal Ouroboros agent
prompt, tool catalogue, and reply budget fit without truncating the request.
The mobile-actions FunctionGemma artifact remains a small specialized router;
its compiled state is limited to 1,024 tokens. The provider preserves the
latest turn and tool contract and, when necessary, reports that it compacted
older system context in `andee-execution.context-compacted`. It is not a
replacement for the general Ouroboros agent model.
LiteRT-LM does not expose effective NPU partition delegation, so initialization
is readiness evidence, not TPU proof. Pixel 10 Pro Fold acceptance additionally
requires a witnessed Tensor G5 device trace or hardware counter.

## Andock execution capability

The APK preloads `~andock@1.0` and packages its generic local capability. Its
measured config identifies the default rootfs by a single native Arweave L1
transaction ID. HyperBEAM resolves that message through the same AO-Core cache
stack and passes its app-private sparse-image path to Android. Android validates
the exact ID, path, and source-pinned size, expands it, verifies the resulting
ext4 digest, and atomically installs a read-only template. It has no rootfs
network client. No rootfs bytes are packaged in the APK.

Each member receives a complete writable sparse ext4 image copied from that
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

`make -C arch/android android-build` validates the committed immutable template
manifest and cross-builds the pinned native PRoot/lwext4 adapter. Images remain
ignored under `arch/android/build/`; no rootfs or member state is committed to
git.

For Android application-only iteration, `make -C arch/android apk` packages and
verifies the already staged runtime without rebuilding BEAM, ERTS, NIFs, WAMR,
the preloaded store, or the Andock payload. It fails when no runtime is staged;
use `android-build` after changing any runtime, device, native, or measured
configuration input.

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
