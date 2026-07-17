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

Android stages one device package from `devices/common/` plus the
Android-specific overlay in `devices/android/`. The shared measurement and zone
devices are therefore identical to the Linux builds; Android contributes the
AndEE crypto-agent runtime for local measurements, Android system reporting,
app-private encrypted storage, and service devices. The `andee@1.0` device
name remains the current AO-Core backend identifier for this architecture.

## Andock execution capability

The APK also packages the generic local capability used by `~andock@1.0`.
Each member receives a complete writable sparse ext4 image copied from a
measured, deterministic Ubuntu 24.04 template. An Android isolated service
receives only that image descriptor and the command/network capabilities for
one operation. PRoot supplies Linux pathname and syscall compatibility; the
security boundary is Android's separate isolated UID and SELinux domain, not
PRoot. The worker cannot open the app-private runtime, config, wallet, crypto
socket, cached template, or another member image.

The release build is ARM64-only. Build the pinned template independently with:

```sh
make -C arch/android andock-template
```

`make -C arch/android android-build` validates or rebuilds the template,
cross-builds the pinned native PRoot/lwext4 adapter, and packages both into the
normal AndEE runtime and APK. Images remain ignored under `arch/android/build/`;
no rootfs or member state is committed to git.
