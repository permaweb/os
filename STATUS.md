# PermawebOS Architecture Split Status

Branch: `agent/permawebos-arch-handee`

Mission: keep upstream HyperBEAM as the kernel and reshape this repository as a
PermawebOS distribution that builds multiple operating environments around that
kernel: Linux LapEE runtime/provisioner images, Linux SNP-capable images, and
Android HandEE packages.

## Overnight Focus

- Start time: `Fri May 22 20:49:41 EDT 2026`.
- Goal 1: make HandEE a normal PermawebOS architecture using the shared device
  protocols and validate the full Android path under emulator/harness.
- Goal 2: add cross-architecture validation infrastructure for local QEMU,
  remote SNP QEMU, and Android nodes, including mixed-template zones.
- Goal 3: run a conservative 1-2 hour deep-clean pass after validation is green.
- Goal 4: only after the above, branch separately for Ouroboros-on-PermawebOS.
- Decision log: `decisions/permawebos-device-sharing.md`.

## Current State

- Base branch: `main` at `46a7cdf2abeca0380cd5c612a6abad1e3993e8ae`.
- HyperBEAM pin: `8c19c6adb45fc658e1ac06e6555efd916fd305e5`.
- Linux Buildroot content lives under `arch/common/linux/`.
- Shared PermawebOS devices are normalized under `devices/common/`.
- Android HandEE architecture content from `~/src/handee` tip
  `5dc6af13e7a658792f8ac95cbf077185f9a24145` lives under `arch/android/`
  and `devices/android/`.
- The HandEE cache-ignore commit
  `5e46e818efc70650c36d668b0520d89f03903dc7` is represented by the
  generalized `devices/*/cache-http` and `devices/*/cache-mainnet`
  `.gitignore` rules.
- Public build surface now includes architecture targets:
  `make tme`, `make no-tme`, `make snp`, `make android`,
  `make provisioner`, and `make all EXCLUDE_ARCH=...`.

## Intentional Boundaries

- Linux and Android now use the same `~measurement@1.0` and `~zone@1.0`
  modules. Android stages those shared devices with the Android-only HandEE
  overlay before compiling its runtime package.
- The Linux Buildroot package still copies the selected device package into
  `/build/common-devices` inside the Buildroot volume. That path is an
  internal compatibility mount point, not a source-tree layout promise.
- Android packaging is imported as an architecture package. It should be tested
  independently before shared measurement/device convergence work.

## Validation To Run

- `make verify-config-invariants`
- `bash -n scripts/build-buildroot.sh`
- `sh -n arch/common/linux/buildroot-external/board/lapee/rootfs-overlay/init`
- `find arch/android/scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n`
- `make -n tme no-tme snp android-check provisioner`
- `make -C arch/android verify-config-invariants`
- `make -C arch/android erl-compile`
- `git diff --check`

Full Linux image and Android APK builds have been run in this branch; see the
completed validation log below.

## Validation Completed

- `make verify-config-invariants`: pass.
- `bash -n scripts/build-buildroot.sh`: pass.
- `sh -n arch/common/linux/buildroot-external/board/lapee/rootfs-overlay/init`:
  pass.
- `find arch/android/scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n`:
  pass.
- `make -n tme no-tme snp android-check provisioner`: pass.
- `make -n all EXCLUDE_ARCH=android,snp`: pass.
- `make -C arch/android verify-config-invariants`: pass.
- `make -C arch/android android-check`: pass.
- `make -C arch/android erl-compile`: pass.
- `make -C arch/android runtime`: pass; produced
  `arch/android/android/app/src/main/assets/handee-runtime.zip`.
- `make -C arch/android apk`: pass; produced
  `arch/android/android/app/build/outputs/apk/debug/app-debug.apk`.
- `make hb-fetch`: pass; fetched stock HyperBEAM at the pinned commit and
  reported `devices/common` as the packaged device source.
- `JOBS="$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN)" make runtime-image TME=0`:
  pass; produced signed Linux no-TME image at
  `build/images/lapee-runtime-no-tme-signed.img`.
- `make qemu IMAGE=build/images/lapee-runtime-no-tme-signed.img`: pass;
  HyperBEAM `/info`, `~measurement@1.0/boot`, and `~system@1.0/all`
  answered from the signed no-TME image under QEMU/swtpm.
- `ZONE_TEMPLATE_LIST=1 make qemu-zone IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
  pass; three local swtpm nodes joined a zone through alternative templates,
  node 4 was rejected, and membership proofs verified.
- `ZONE_TEMPLATE_LIST=1 make qemu-zone-nonvolatile IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
  pass; node 2 reopened the same encrypted nonvolatile store after reboot,
  and the cached pre-reboot boot measurement was unreadable before rejoin but
  readable after zone activation.
- `BASE_PORT=23040 ZONE_TEMPLATE_LIST=1 make qemu-zone-remote-snp IMAGE=build/images/lapee-runtime-no-tme-signed.img`:
  pass; four real SNP guests booted on `hb@dev-1.forward.computer`, three
  matching nodes joined, the mismatched node was rejected, and membership
  proofs verified.
- `make -C arch/android android-check runtime apk smoke android-zone-storage-smoke zone-storage-scenario`:
  pass; Android runtime, APK, emulator smoke, Android encrypted store, and
  host HandEE zone-storage scenario all completed.
- `git diff --check`: pass.
