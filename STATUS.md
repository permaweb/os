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
    `0x01C00100..0x01C001FF`.
  - The ODCA range scan stops at the first missing range index, because the
    chain is provisioned contiguously from `0x01C00100`.
  - The verifier still treats those certs only as intermediates, never as
    trust anchors.
  - Added EUnit coverage for the Intel ODCA chain-handle set.
- Validation after fix:
  - `HB_PORT=0 rebar3 as test eunit --module=dev_tpm2`: 23 tests passed.
  - `JOBS=18 make buildroot` passed.
  - Rebuilt images:
    - `build/images/lapee-usb.img`:
      `213177176d29e56dfe18e3fc07c8b2a3b471a75041f6396104f69515562839ab`
    - `build/images/lapee-usb-no-tme.img`:
      `61746cc6380529755dd9962e4d7246a563f7c4a31a4bb3b409757ebd2d676c09`
    - `build/initramfs/initramfs-lapee.cpio.zst`:
      `1230754a8d021997ba729e745e2f2a33ef8b8a5fb1fc25c1752a77012a230ad2`
    - `build/kernel/vmlinuz-lapee`:
      `1cfe160c491205ac0649c1c76bbdd2d8851c33b1e012e9321a83cdc89d47f872`
  - `IMG=build/images/lapee-usb-no-tme.img ./scripts/boot-usb-image.sh
    --timeout 420` passed.
  - `./scripts/interpret-local-capture.sh --label qemu-no-tme-odca-full-chain
    build/qemu-network-test/boot-attestation.json` passed:
    - Dashboard:
      `build/hyperbeam/src-edge/out/local-capture/qemu-no-tme-odca-full-chain/dashboard.html`
    - Expected QEMU verdict: `untrusted`, score `4`.
    - Verified signals include wallet binding, quote signature, PCR replay,
      hashpath continuity, freshness, and no-TME operator override.

## Live `.210` Disk/ODCA Chain Validation

- Sam rebooted `.210` and reinserted the USB stick into this machine.
- macOS currently reports no external physical disk in `diskutil list`, so I
  could not do a fresh raw `cmp` against the stick without the device
  reappearing.
- The live `.210` attestation is still enough to rule out "wrong stale disk":
  it contains fields added by `397b93d`, including:
  - `chain_source = tpm-nv:0x01C00100`
  - `chain_handles = ["0x01C00100"]`
  - `chain_cert_count = 2`
- Extracted live EK data showed:
  - EK leaf issuer:
    `ODCA 2 CSME MTL SOC SVN 01 PTT   CA`
  - TPM-supplied chain cert 1:
    `ODCA 2 CSME MTL SOC ROM CA`
  - TPM-supplied chain cert 2:
    `ODCA 2 CSME MTL SOC SVN 01 Kernel CA`
- Diagnosis:
  - The latest flashed image did boot.
  - The remaining EK-chain failure is not a disk-selection problem.
  - The Intel ODCA NV blob is still missing the PTT CA in the parsed chain.
  - The previous parser stopped trusting raw concatenation shape too much; Intel
    ODCA chain NV blobs may include non-cert bytes between DER certificates.
- Fix implemented:
  - `split_concatenated_ders/1` now scans for X.509 DER certs across non-cert
    gaps and accepts a SEQUENCE only if OTP decodes it as an X.509 certificate.
  - `dev_tpm_interpret` now validates EK chains by building issuer/subject paths
    across both TPM-supplied intermediates and bundled public intermediates,
    while keeping only self-signed roots as trust anchors.
  - Added Intel OnDie ODCA public certs from Intel's `tsci.intel.com` AIA
    endpoints:
    - OnDie CA Root
    - ODCA CA2 CSME Intermediate
    - MTL `00003043` ODCA CA2 product CA
- Validation:
  - `./scripts/stage-hyperbeam-overlay.sh build/hyperbeam/src-edge` passed.
  - `HB_PORT=0 rebar3 as test eunit --module=dev_tpm2`: 24 tests passed.
  - `HB_PORT=0 rebar3 as test eunit --module=dev_tpm_interpret`: 116 tests
    passed.
  - `JOBS=18 make buildroot && make hb-usb-image &&
    make hb-usb-no-tme-image` passed.
  - Final image hashes:
    - `build/images/lapee-usb.img`:
      `41e615b9c97bb89953d103cb578c804d93dc27bfe6f9abc86cd02cc2c6f498ae`
    - `build/images/lapee-usb-no-tme.img`:
      `3197142c483560b7f6386d435ef00e9c7cc0ecee40b7dede1706a2470843cdc1`
    - `build/kernel/vmlinuz-lapee`:
      `1cfe160c491205ac0649c1c76bbdd2d8851c33b1e012e9321a83cdc89d47f872`
    - `build/initramfs/initramfs-lapee.cpio.zst`:
      `bdf40dac921a18edf123918365c5fd5060daaa99494081242627b813ca0524a1`
  - `IMG=build/images/lapee-usb-no-tme.img ./scripts/boot-usb-image.sh
    --timeout 420` passed.
  - `./scripts/interpret-local-capture.sh
    --label qemu-no-tme-odca-parser-path-fix-final
    build/qemu-network-test/boot-attestation.json` passed:
    - Dashboard:
      `build/hyperbeam/src-edge/out/local-capture/qemu-no-tme-odca-parser-path-fix-final/dashboard.html`
    - Expected QEMU verdict: `untrusted`, score `4`.
    - Verified signals include wallet binding, quote signature, PCR replay,
      hashpath continuity, freshness, and no-TME operator override.
- Remaining physical validation:
  - QEMU cannot prove the Intel ODCA NV parser because `swtpm` does not expose
    the Lenovo's real ODCA blob layout.
  - Next real-hardware boot should show whether the gap-tolerant parser recovers
    the missing PTT CA from `0x01C00100`.
