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
- Hardened provisioner selection by revalidating the selected disk immediately
  before destructive writes and checking the written GPT partition name from
  disk contents.
- Rebuilt fresh signed no-TME runtime and Secure Boot provisioner images.

## Active Checks

- Ask for an independent peer audit after the next green run.

## Latest Verification

- `sh -n buildroot-external/board/lapee/rootfs-overlay/init`
- `bash -n scripts/qemu-provisioner-nonvolatile.sh`
- `bash -n scripts/qemu-green-zone-cluster.sh`
- `git diff --check -- Makefile README.md STATUS.md decisions/nonvolatile-storage-production.md buildroot-external/board/lapee/rootfs-overlay/init hyperbeam-overlay/src/lapee_nonvolatile.erl scripts/qemu-provisioner-nonvolatile.sh`
- `make provisioner-image`
- `make runtime-image TME=0 WIFI=0`
- `make qemu-provisioner-nonvolatile`
  - `found LAPEE_NONVOLATILE partition`
  - `=== provisioner non-volatile QEMU smoke PASSED ===`
- `make qemu-green-zone-nonvolatile`
  - `node 4 rejected as expected`
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
