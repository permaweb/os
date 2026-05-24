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
