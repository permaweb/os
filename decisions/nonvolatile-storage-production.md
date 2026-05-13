# Non-Volatile Storage Production Review

## Prompt

Polish the LapEE non-volatile storage feature until it is end-to-end
production-ready, safe for real users, maintainable, and verified through QEMU
provisioning/runtime/reboot flows.

## Current Shape

The provisioner repartitions exactly one operator-selected non-boot disk,
creates a GPT partition named either `GREENZONE_PRIMARY` or
`GREENZONE_<ring-address-prefix>`, and writes a LapEE marker at the partition
start. It is deliberately not a secure erase. After a green-zone key exists,
LapEE derives a disk key from the zone name, ring address, and AES secret,
initializes or opens the best matching labeled partition as LUKS2, mounts ext4 with
`nodev,nosuid,noexec`, prepends that LMDB store, and copies the boot LMDB into
it.

## What Is Sensible

- The destructive act is explicit and typed by the operator.
- The runtime does not partition arbitrary disks; it only first-formats a
  partition that has both the expected GPT name and the marker created by the
  provisioner.
- Runtime prefers a zone-specific `GREENZONE_<ring-address-prefix>` partition
  and only falls back to `GREENZONE_PRIMARY` when no zone-specific partition is
  present.
- The encryption key is not operator supplied and is derived only after the
  node has joined a verified green zone.
- Existing LUKS volumes are not reformatted on later boots.
- The test harness now covers green-zone join, encrypted-disk creation,
  reboot, reopen, and membership proof production.

## What Needed Tightening

- The selected disk is rechecked immediately before destructive writes run. The
  check is intentionally narrow: still a block device, still writable, still
  non-empty, still not the boot disk, and not an obvious pseudo device.
- The initial provisioner QEMU validation was manual. It is now captured in
  `scripts/qemu-provisioner-nonvolatile.sh`.
- Upstream `hb_volume` remains too broad for this path: it shells via `sudo`,
  parses command strings, relies on probes that are not consistently present in
  LapEE, and can create filesystems based on those probes. The LapEE path keeps
  the appliance invariant narrower: exact marker partition, no request-driven
  disk operations, argv-based command execution, and fail-closed reuse.

## Security Decisions

- Fresh marker partitions may be formatted by runtime because the marker is
  written only by the explicit provisioner flow after operator confirmation.
  Existing LUKS volumes are never reformatted.
- Multiple marker partitions are an error. There is no heuristic selection.
- `GREENZONE_PRIMARY` is intentionally an open binding: the first successful
  zone join formats it, and later joins must possess that same zone secret to
  reopen it. Zone-specific labels let operators avoid even attempting a store
  with the wrong zone.
- Missing storage is a skip, not a node failure. This keeps green-zone admission
  independent from optional persistence.
- Storage activation is tied to the first mounted non-volatile store. Multi-zone
  per-zone storage is out of scope for v1 and should be designed explicitly if
  needed.
- Full-cluster cold restart is not solved by v1 storage. A rebooted node can
  reopen its store after rejoining a live holder of the same green-zone secret.
  Independent recovery would need a TPM-sealed recovery object or a different
  key hierarchy and should not be slipped into this patch.
