# Android HandEE Architecture

This directory contains the Android HandEE architecture imported from
`~/src/handee` tip `5dc6af13e7a658792f8ac95cbf077185f9a24145`.

- `android/` is the Gradle Android app.
- `config/handee.json` is the base HyperBEAM config packaged into the runtime.
- `runtime-src/` contains the Android native launcher and Erlang overrides.
- `scripts/` contains Android SDK, runtime, emulator, and scenario harnesses.
- `secondary-external-verifier/` contains Android attestation verifier assets.
- `specs/` contains the HandEE device specification from the source branch.

The HyperBEAM device package for this architecture lives in
`devices/android/`. Android currently ships its own measurement/system/zone
implementation rather than linking the Linux TPM/SNP NIF package.
