# TODO: Correct Probe Surface Regression

## Context

The current working tree moved in the right direction by adding a neutral
`~system@1.0` report and by reshaping `~tpm@2.0a/boot-attestation` around:

- `~system@1.0/all`
- `~meta@1.0/info`
- a PCR15 extension over the combined subject
- a signed, cached boot-attestation message

However, part of the same pass over-corrected toward production surface
minimization. That conflicts with the later architecture decision: hardware
and firmware probes should be neutral, on-demand, broad, and maintainable. The
devices should collect and structure all useful evidence available from normal
kernel/userspace interfaces; policy consumers decide what to trust.

The key distinction:

- Keep local input and write/exfiltration hardening: keyboard, mouse, HID,
  writable boot media, USB storage reattachment, debug console, etc.
- Do not disable useful read-oriented kernel probe interfaces merely because
  they increase observability.

## Current Delta To Review

Compared with `HEAD`, the current tree changes:

- `buildroot-external/board/lapee/linux-m1-fragment.config`
  - Adds EDAC/RAS support.
  - Adds explicit `# CONFIG_X86_MSR is not set`.
  - Adds explicit `# CONFIG_X86_CPUID is not set`.
  - `DEBUG_FS` and `DEVMEM` were already disabled in the committed baseline.
- `hyperbeam-overlay/src/dev_system.erl`
  - New neutral `~system@1.0` device.
  - Reads generic `/proc` and `/sys` data.
  - Reads EDAC.
  - Attempts Intel Meteor Lake memory type via DRM PCI `resource0`.
  - Reports Boot Guard as unavailable because no generic VFS source is present.
- `hyperbeam-overlay/src/dev_tpm2.erl`
  - Adds `boot-attestation`.
  - Calls `~system@1.0/all`, signs the node message, extends PCR15 with the
    combined subject, quotes, signs, caches, and links the result.
- `hyperbeam-overlay/src/dev_tpm_interpret.erl`
  - Adapts the verifier/interpreter to the new boot-attestation envelope shape.
- `buildroot-external/board/lapee/rootfs-overlay/etc/lapee/lapee.json`
  - Registers `tpm@2.0a`.
  - Registers `system@1.0`.
  - Changes startup hook from `tpm2@2.0a/extend` to
    `tpm@2.0a/boot-attestation`.

## Correction Plan

1. Preserve the neutral `~system@1.0` direction.

   Do not revert the existence of `dev_system.erl`. It is the right layer for
   broad, descriptive machine evidence. Keep its fields neutral: every probe
   should report source, method, status, raw values where sensible, decoded
   values where known, and errors. It must not decide trust policy.

2. Undo probe-surface minimization from the kernel fragment.

   Remove the new explicit disables for:

   - `# CONFIG_X86_MSR is not set`
   - `# CONFIG_X86_CPUID is not set`

   Then decide deliberately whether the production kernel should enable:

   - `CONFIG_X86_CPUID=y`, because `/dev/cpu/*/cpuid` is read-only in normal
     use and gives broad, useful, low-maintenance CPU evidence.
   - `CONFIG_X86_MSR=y`, only if the implementation keeps usage tightly scoped
     to read-only access from `~system@1.0` and clearly reports provenance.

   Do not couple this to local input hardening. Input lockdown can remain.

3. Reassess `DEBUG_FS` separately.

   Do not assume debugfs is required for production. It is not a stable kernel
   ABI and it exposes a large miscellaneous surface. Use it for exploratory
   builds if needed, but prefer stable sysfs/procfs/devfs sources first.

   If a production probe truly requires debugfs, document the exact file, mount
   it read-only where possible, read only that source, and make the trade-off
   explicit before enabling it.

4. Add a real Boot Guard probe when a source exists.

   Current `dev_system:boot_guard_report/1` only returns unavailable. Replace
   that with layered neutral probing:

   - If `/dev/cpu/0/msr` exists, open it read-only and read MSR `0x13a`
     (`MSR_BOOT_GUARD_SACM_INFO`).
   - Report raw 64-bit value, decoded fields, CPU index, source path, and method.
   - If unavailable or read fails, report the exact failure without aborting the
     rest of `~system@1.0/all`.
   - Keep TCG event-log Boot Guard strings/measurements as separate firmware
     evidence, not a substitute for the status MSR.

   Avoid adding a kernel patch or C helper unless the VFS route is genuinely
   unavailable or unsafe.

5. Keep the memory-topology probes broad and non-authoritative.

   Preserve EDAC/RAS support. Preserve the Intel DRM read-only `resource0` probe
   with the corrected Meteor Lake offset (`0x45700`) and retry on real hardware.

   If the corrected `resource0` probe still returns `EIO`, treat that as kernel
   ownership/protection of the BAR rather than a security failure. Then evaluate
   the next least-invasive source:

   - existing i915/xe sysfs/debugfs exports, if any;
   - EDAC as the generic fallback;
   - a tiny kernel export only if there is no maintainable userspace path.

6. Keep boot attestation shape, but verify the exact semantics.

   `~tpm@2.0a/boot-attestation` should continue to return one signed message
   containing:

   - `system`
   - `node`
   - `tpm`

   The PCR15 extend must be over the AO-Core ID/digest of the combined
   `{system, node}` subject. The cached path must link to the signed message ID,
   not the unsigned cache ID.

7. Keep verifier/interpreter changes mechanical.

   `~tpm-interpret@1.0` can normalize the new boot-attestation shape and expose
   parsed subtrees, but it should not bless individual system-probe sources as
   trusted. It should preserve provenance and make it easy for policy devices or
   callers to match against their own requirements.

8. Verification before committing.

   Run:

   ```sh
   git diff --check
   make buildroot
   make hb-usb-no-tme-image
   ./scripts/boot-usb-image.sh --image build/images/lapee-usb-no-tme.img --timeout 180
   ```

   Then on live hardware:

   ```sh
   curl -fsSL "http://<node-ip>:8734/~system@1.0/all?accept=application/json&accept-bundle=true" | jq
   curl -fsSL "http://<node-ip>:8734/~tpm@2.0a/boot-attestation?accept=application/json&accept-bundle=true" | jq
   ./scripts/interpret-local-capture.sh --url "http://<node-ip>:8734" --label "<machine-label>"
   ```

   Confirm:

   - Boot still reaches the splash and HyperBEAM.
   - Wi-Fi still comes up on Framework and Lenovo machines.
   - `~system@1.0/all` includes EDAC/memory evidence.
   - Boot Guard reports either a decoded MSR value or a precise unavailable
     reason.
   - The interpreter dashboard still validates the wallet/TPM binding.

