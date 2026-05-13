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

## Active Checks

- Re-run static shell/Erlang validation.
- Rebuild signed runtime and provisioner images after hardening patches.
- Re-run `make qemu-provisioner-nonvolatile`.
- Re-run `make qemu-green-zone-nonvolatile`.
- Ask for an independent peer audit after the next green run.

## Open Review Questions

- Whether v1 should support more than one green-zone-backed persistent store.
  Current decision: no, first mounted store wins.
- Whether optional storage failure should prevent joining a green zone.
  Current decision: no, report status and keep the node live.
