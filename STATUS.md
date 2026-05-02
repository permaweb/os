# LapEE Unattended Probe/Attestation Pass

## Mission

Finish the correction pass from `docs/probe-surface-correction-todo.md` and
leave a fully rebuilt, verifier-tested LapEE image ready for real hardware.

Acceptance means:

- Neutral `~system@1.0` remains in place.
- Useful read-oriented probe interfaces are not disabled just to reduce
  observability.
- Boot Guard reports a real MSR-backed observation when `/dev/cpu/0/msr` is
  present, otherwise a precise unavailable reason.
- The build picks up the corrected `dev_system.erl` source.
- Standard and no-TME images rebuild.
- QEMU boots the no-TME image and serves `~tpm@2.0a/boot-attestation` and
  `~system@1.0/all`.
- The interpreter/verifier dashboard runs against the QEMU capture.
- Local commits record stable checkpoints.

## Discipline

Unattended mode is active. Chat is only for blocking questions. Progress and
pivots go here. No pushes unless explicitly requested.

## Log

- Started from branch `agent/probe-boot-capture` at `0e78476`.
- Current dirty tree already contained the new boot-attestation shape,
  `~system@1.0`, EDAC additions, the TODO doc, and verifier/script updates.
- Live `.210` node answered, but reported old DRM offset `0x01053400`; current
  source is `0x45700`, so rebuild validation must confirm the packaged image is
  using the current overlay.
- Wrote decision note:
  `docs/decisions/read-oriented-probe-surface.md`.
- Implemented first correction pass:
  - `CONFIG_X86_MSR=y`
  - `CONFIG_X86_CPUID=y`
  - `~system@1.0` now reads Boot Guard MSR `0x13a` from `/dev/cpu/0/msr` when
    available and decodes the pcr0tool/coreboot-compatible fields.
  - `~system@1.0` now reports selected `/dev/cpu/0/cpuid` leaves when available.
  - The interpreter policy surface now exposes `tme-operator-override` so
    no-TME boots do not look like an accidental "TME unknown" only.
- Corrected probe hex rendering to emit actual uppercase hexadecimal strings
  (`0x00045700`, `0x000000000000013A`) instead of decimal strings with a
  `0x` prefix.
- `rebar3 as test compile` passed in the staged HyperBEAM checkout.
- `rebar3 as test eunit --module=dev_system` passed. A parallel attempt to run
  multiple EUnit modules collided on HyperBEAM's default test listener port;
  rerunning remaining modules serially with isolated ports.
- Serial EUnit with `HB_PORT=0` passed:
  - `dev_tpm_interpret`: 116 tests.
  - `dev_tpm2`: 22 tests.
- Checkpoint commit: `05e17f9 Add boot attestation system probe`.
- `JOBS=18 make buildroot` passed. It rebuilt Linux 6.19.12 and HyperBEAM,
  staged the overlay during the package build, passed post-build sanity checks,
  and produced:
  - `build/kernel/vmlinuz-lapee`
  - `build/initramfs/initramfs-lapee.cpio.zst`
- Buildroot validation after rebuild:
  - Final kernel has `CONFIG_X86_MSR=y` and `CONFIG_X86_CPUID=y`.
  - `DEBUG_FS`, `DEVMEM`, `PROC_KCORE`, `MODULE_UNLOAD`, HID, evdev,
    keyboard, mouse, and USB HID remain unavailable.
  - Final HyperBEAM release contains `dev_system.beam`, `dev_tpm2.beam`,
    `dev_tpm_interpret.beam`, `dev_tpm_tcg.beam`, `lapee_tpm_nif.beam`, and
    x86-64 `priv/lapee_tpm_nif.so`.
- Built standard and no-TME USB images:
  - `build/images/lapee-usb.img` (236 MiB)
  - `build/images/lapee-usb-no-tme.img` (236 MiB)
- Image hashes:
  - `build/images/lapee-usb.img`:
    `369040b4fb2d9dd640914a5421da5ca739365fe80d4696ad37b4706eda4ada17`
  - `build/images/lapee-usb-no-tme.img`:
    `740ddbb1d6db431f2d0b4b6385b0aa3fb9c813164ffa61584f5ab60156da531b`
  - `build/kernel/vmlinuz-lapee`:
    `1cfe160c491205ac0649c1c76bbdd2d8851c33b1e012e9321a83cdc89d47f872`
  - `build/initramfs/initramfs-lapee.cpio.zst`:
    `45c31d57dcd14976ff196058b0324e029cd39f89c4487147dba922d03313d6e0`
- `IMG=build/images/lapee-usb-no-tme.img ./scripts/boot-usb-image.sh --timeout 420`
  passed. It fetched:
  - `build/qemu-network-test/boot-attestation.json`
  - `build/qemu-network-test/system.json`
- QEMU `~system@1.0/all` validation:
  - `body.device = system@1.0`
  - `body.schema = lapee-system-report@1`
  - `body.cpu.cpuid.available = true`
  - `body.firmware.boot-guard.source = dev-cpu-msr`
  - `body.firmware.boot-guard.interface = /dev/cpu/0/msr`
  - `body.firmware.boot-guard.msr-offset = 0x000000000000013A`
  - `body.kernel.cmdline` contains `LAPEE_NO_TME=1`
- QEMU `~tpm@2.0a/boot-attestation` validation:
  - `body.system.schema = lapee-system-report@1`
  - `body.node.address = sN3-Tglc23bt4YgluQnHTM226IrF4KKdV1M8M41S0IY`
  - `body.tpm.quote` is present.
  - `body.tpm.extended-pcr = 15`
  - `body.tpm.extended-subject =
    66yHXCzmN4jcn33JpUUWSy4YG3bI3mkL4yFtxz2MiG0`
- `./scripts/interpret-local-capture.sh --label qemu-no-tme-boot-attestation
  build/qemu-network-test/boot-attestation.json` passed and produced:
  - `build/hyperbeam/src-edge/out/local-capture/qemu-no-tme-boot-attestation/dashboard.html`
  - Expected QEMU verdict: `untrusted` with score `4`, due swtpm/no EK and
    setup-mode Secure Boot evidence.
  - Verified signals include:
    `wallet-tpm-binding-verified=true`, `quote-signature-verified=true`,
    `pcr-replay-consistent=true`, `hashpath-continuity-verified=true`,
    `ak-pubkey-extend-verified=true`, `freshness-indicator=ok`, and
    `tme-operator-override=true`.

## Live `.210` Follow-Up

- Live node `http://192.168.1.210:8734` answered:
  - `~system@1.0/all`
  - `~tpm@2.0a/boot-attestation`
- Live system report showed:
  - `body.cpu.cpuid.available = true`
  - `body.firmware.boot-guard.source = dev-cpu-msr`
  - `body.firmware.boot-guard.raw-hex = 0x000000030000007F`
  - Boot Guard decoded as capability=true, measured=true, verified=true,
    tpm-success=true.
  - EDAC reported LPDDR-class memory:
    `Low-Power-DDR3-RAM`.
- Live analyzer output:
  - Dashboard:
    `build/hyperbeam/src-edge/out/local-capture/live-210-boot-attestation/dashboard.html`
  - Verdict remained `untrusted` because:
    - Secure Boot is disabled/setup-mode on this boot.
    - EK issuer is `ODCA 2 CSME MTL SOC SVN 01 PTT   CA`, but the live
      attestation carried no intermediate EK chain bytes.
- Root cause found:
  - The attester read the EK leaf from `0x01C00002` and only probed the
    adjacent chain slot `0x01C00003`.
  - Intel PTT 11th-gen+ ODCA stores the embedded intermediate CA chain in
    the TCG EK-chain NV range beginning at `0x01C00100`.
- Fix implemented:
  - `dev_tpm2` now probes both the adjacent chain slot and
    `0x01C00100..0x01C0010F`.
  - The verifier still treats those certs only as intermediates, never as
    trust anchors.
  - Added EUnit coverage for the Intel ODCA chain-handle set.
- Validation after fix:
  - `HB_PORT=0 rebar3 as test eunit --module=dev_tpm2`: 23 tests passed.
  - `JOBS=18 make buildroot` passed.
  - Rebuilt images:
    - `build/images/lapee-usb.img`:
      `3ce1fc6a9d672e8c2978ed77a090a19f68de5f910c4d8a50d09f5dad9360aff5`
    - `build/images/lapee-usb-no-tme.img`:
      `170cf584fff8f07e957b24bc0bb809b400130dace91d66d96f986a0d00f12379`
    - `build/initramfs/initramfs-lapee.cpio.zst`:
      `6c6c5c0e80b7230b9d9d6b19af1c3bc55f8d99c654c930a0064b5b4c04782686`
    - `build/kernel/vmlinuz-lapee`:
      `1cfe160c491205ac0649c1c76bbdd2d8851c33b1e012e9321a83cdc89d47f872`
  - `IMG=build/images/lapee-usb-no-tme.img ./scripts/boot-usb-image.sh
    --timeout 420` passed.
  - `./scripts/interpret-local-capture.sh --label qemu-no-tme-odca-chain-fix
    build/qemu-network-test/boot-attestation.json` passed:
    - Dashboard:
      `build/hyperbeam/src-edge/out/local-capture/qemu-no-tme-odca-chain-fix/dashboard.html`
    - Expected QEMU verdict: `untrusted`, score `4`.
    - Verified signals include wallet binding, quote signature, PCR replay,
      hashpath continuity, freshness, and no-TME operator override.
