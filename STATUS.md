# LapEE Non-Volatile Storage Status

## Current Focus

Production hardening for encrypted non-volatile storage on
`feat/persistent-storage`.

## Completed

- Implemented provisioner disk listing and explicit `DESTROY N` flow.
- Implemented green-zone-keyed LUKS2/ext4 runtime activation.
- Reused existing LUKS volumes across reboot without reformatting.
- Prepended the mounted LMDB as primary store and merged the boot LMDB.
- Added QEMU green-zone non-volatile reboot acceptance test.
- Added provisioner QEMU smoke test for the destructive partition-label flow.
- Added `GREENZONE_PRIMARY` and `GREENZONE_<ring-address-prefix>` partition
  labels so a disk can either bind to the first joined zone or to a named zone
  prefix.
- Added peer-audited hardening for idempotent activation and first-format
  safety.
- Hardened provisioner selection by revalidating the selected disk immediately
  before destructive writes as a writable non-boot block device and checking
  the written GPT partition name from disk contents.
- Hardened first-format authorization: the provisioner writes a LapEE
  partition marker, and runtime refuses to first-format a non-LUKS partition
  without that marker.
- Hardened existing-volume behavior: existing LUKS volumes are mounted before
  any format decision, so weak filesystem probes cannot wipe a real store.
- Removed full-disk zeroing from provisioning. The provisioner repartitions and
  marks the selected disk; LUKS formatting overwrites the selected partition
  when the runtime first admits the node.
- Rebuilt fresh signed no-TME runtime and Secure Boot provisioner images.

## Active Checks

- None.

## Latest Verification

- `sh -n buildroot-external/board/lapee/rootfs-overlay/init`
- `bash -n scripts/qemu-provisioner-nonvolatile.sh`
- `bash -n scripts/qemu-green-zone-cluster.sh`
- `erlc -I build/hyperbeam/src-edge/src -o /tmp hyperbeam-overlay/src/lapee_nonvolatile.erl hyperbeam-overlay/src/dev_green_zone.erl`
- `git diff --check -- README.md STATUS.md decisions/nonvolatile-storage-production.md buildroot-external/board/lapee/rootfs-overlay/init hyperbeam-overlay/src/dev_green_zone.erl hyperbeam-overlay/src/lapee_nonvolatile.erl scripts/qemu-green-zone-cluster.sh scripts/qemu-provisioner-nonvolatile.sh`
- `make provisioner-image`
- `make runtime-image TME=0 WIFI=0`
  - `Signature verification OK`
  - signed image: `build/images/lapee-runtime-no-tme-signed.img`
- `make qemu-provisioner-nonvolatile`
  - `found GREENZONE_test-zone partition`
  - `=== provisioner non-volatile QEMU smoke PASSED ===`
- `make qemu-green-zone-nonvolatile`
  - `node 4 rejected as expected`
  - `rejected node 4 left its non-volatile disk unformatted`
  - `node 2 reopened the same encrypted non-volatile volume after reboot`
  - `node 1 produced ring-signed membership proof`
  - `node 2 produced ring-signed membership proof`
  - `node 3 produced ring-signed membership proof`
  - `=== green-zone QEMU cluster PASSED ===`

## Open Review Questions

- Whether v1 should support more than one green-zone-backed persistent store.
  Current decision: no, first mounted store wins.
- Whether optional storage failure should prevent joining a green zone.
  Current decision: no, report status and keep the node live.
- Full-cluster cold restart requires at least one live peer or a future
  TPM-sealed recovery design, because v1 derives the disk key from the
  green-zone secret rather than operator material.
