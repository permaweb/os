# Provisioning Protocol

The provisioner image is a separate signed PermawebOS appliance mode for
destructive setup operations that should never be available in production
runtime mode.

## Secure Boot Enrollment

The provisioner:

1. Shows a severe red warning screen.
2. Requires the exact input `I UNDERSTAND.` before changing firmware state.
3. Detects setup mode.
4. Enrolls PermawebOS public Secure Boot material.
5. Re-enables Secure Boot when supported by firmware variables.
6. Shows a post-provisioning report in the same warning panel.

It must never require signing private keys on the USB. It should be signed so
machines that already trust PermawebOS can boot it.

## Encrypted Zone Storage

The provisioner lists writable non-boot disks and prompts:

```text
Type `SKIP` or `DESTROY N[ -> ID]`.
```

`DESTROY N` provisions the selected disk for the first zone joined.
`DESTROY N -> ID` provisions it for a zone whose ring address starts with
`ID`. Labels are discovery hints only. After join, runtime writes
authenticated storage metadata binding the full ring-reference, zone definition
ID, and storage version. Unlock must require authenticated metadata to match
the joined zone.

The provisioner must report partitioning and formatting results. It must never
select the boot USB as a destructive target.
