# PermawebOS Smoke Tests

`scripts/smoke.sh` is the smoke registry. It names every durable smoke as a
case, groups cases into suites, and is the place to add new cases.

## Run Suites

```sh
make smoke-list
make smoke-full
make smoke-linux
make smoke-android
make smoke-mixed
make smoke-provisioner
```

`smoke-full` runs the local complete suite: Linux QEMU, Android AndEE, mixed
AndEE+QEMU, and provisioner tests. It does not run `remote-snp`; that suite
requires an explicit remote target:

```sh
TARGET=ssh://host make qemu-zone-remote-snp
./scripts/smoke.sh remote-snp
```

Architecture suites are named by their owning build/runtime surface:
`linux`, `android`, `provisioner`, and `remote-snp`.

Android suites require an active adb device or emulator. Start one first:

```sh
make -C arch/android emulator-start
```

The `android` suite runs `android-build` once, then runs the AndEE smoke and
scenario scripts against that APK/runtime. Individual Android runtime cases
expect the APK to exist; run `./scripts/smoke.sh android-build android-smoke`
when starting from a clean tree.

## Run Cases

```sh
./scripts/smoke.sh linux-config
./scripts/smoke.sh android-build android-smoke android-next-boot-config
./scripts/smoke.sh mixed-andee-qemu-ring
```

## Add A Smoke

Add a named case to `scripts/smoke.sh`, then attach it to the smallest suite
that owns it: `linux`, `android`, `mixed`, `provisioner`, or `remote-snp`.
Keep generated evidence under `build/` and make the harness fail on invariant
breakage, not just transport failure.
