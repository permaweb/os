# Non-Volatile Storage Production Review

## Prompt

Polish the LapEE non-volatile storage feature until it is end-to-end
production-ready, safe for real users, maintainable, and verified through QEMU
provisioning/runtime/reboot flows.

## Current Shape

The provisioner zero-erases exactly one operator-selected non-removable disk,
creates a GPT partition named `LAPEE_NONVOLATILE`, and writes a LapEE marker at
the partition start. The runtime ignores every other disk surface. After a
green-zone key exists, LapEE derives a disk key from the zone name and AES
secret, initializes or opens the labeled partition as LUKS2, mounts ext4 with
`nodev,nosuid,noexec`, prepends that LMDB store, and copies the boot LMDB into
it.

## What Is Sensible

- The destructive act is explicit and typed by the operator.
- The runtime does not partition arbitrary disks; it only first-formats a
  partition that has both the expected GPT name and the marker created by the
  provisioner.
- The encryption key is not operator supplied and is derived only after the
  node has joined a verified green zone.
- Existing LUKS volumes are not reformatted on later boots.
- The test harness now covers green-zone join, encrypted-disk creation,
  reboot, reopen, and membership proof production.

## What Needed Tightening

- The initial implementation trusted a candidate list captured before operator
  input. The disk is now revalidated by device, boot-disk exclusion,
  removability, path, writability, disk sequence, and size immediately before
  destructive writes run.
- The initial provisioning path could leave old plaintext past the new
  partition table. It now erases the selected disk before repartitioning, and
  the QEMU smoke test plants a sentinel string across the disk and fails if it
  survives.
- The initial provisioner QEMU validation was manual. It is now captured in
  `scripts/qemu-provisioner-nonvolatile.sh`.
- Upstream `hb_volume` remains too broad for this path: it shells via `sudo`,
  parses command strings, relies on probes that are not consistently present in
  LapEE, and can create filesystems based on those probes. The LapEE path keeps
  the appliance invariant narrower: exact marker partition, no request-driven
  disk operations, argv-based command execution, and fail-closed reuse.

## Security Decisions

- Fresh marker partitions may be formatted by runtime because the marker itself
  is written only after an operator-destructive full-disk wipe. Existing LUKS
  volumes are never reformatted.
- Multiple marker partitions are an error. There is no heuristic selection.
- Missing storage is a skip, not a node failure. This keeps green-zone admission
  independent from optional persistence.
- Storage activation is tied to the first mounted non-volatile store. Multi-zone
  per-zone storage is out of scope for v1 and should be designed explicitly if
  needed.
- Full-cluster cold restart is not solved by v1 storage. A rebooted node can
  reopen its store after rejoining a live holder of the same green-zone secret.
  Independent recovery would need a TPM-sealed recovery object or a different
  key hierarchy and should not be slipped into this patch.
