# Generic Andock execution contract

Status: implemented on `impr/generic-andock`.

## Objective

PermawebOS owns `~andock@1.0` as an application-agnostic execution device.
AndEE packages the Android isolated-UID, SELinux, PRoot, filesystem-image, and
network capabilities which implement it. Applications such as Ouroboros are
loaded independently through HyperBEAM's measured `trusted-device-signers`
and `name-resolvers` configuration and may select `andock@1.0` as their Unix
execution backend.

An operating-system image must build without an Ouroboros checkout and must
never embed application source, device archives, payloads, pins, provenance,
or application-specific public device names.

## Established source facts

- The public Android device is already `~andock@1.0` in
  `devices/android/src/dev_andock.erl`.
- The reference container device is `~docker@1.0` in Ouroboros
  `src/dev_docker.erl`.
- No `~ouroboros-andock@1.0` public device exists in either selected tree.
- Ouroboros selects an execution device through its private node option
  `ouroboros-execution-device`; its default is `docker@1.0`, and arbitrary
  versioned device references are resolved through ordinary AO resolution.
- The architecture violation is source ownership, not the public device
  identity: the old standalone Andock packager imported its execution contract
  from an application checkout instead of owning the platform contract.
- The Android app already owns the private `andock-local@1` socket transport,
  isolated execution service, member-image lifecycle, native PRoot/lwext4
  adapter, Ubuntu template, and network broker. Those are generic platform
  capabilities and remain in AndEE.

## Public contract

`~andock@1.0` preserves the observable `~docker@1.0` execution-engine contract:

- `index` reports readiness and eight public routes;
- POST-only `read`, `write`, `append`, `edit`, `glob`, `grep`, `bash`, and
  `bash-session`;
- integration routes `read-file`, `write-file`, and `list-files`;
- required `member-id` and matching `member-context.id`;
- title-case tool authorization from `member-context.tools`;
- network selection from `member-context.metadata.allow-network`;
- `/root` relative-path resolution, `..` and NUL rejection;
- per-member serialization with independent members able to overlap;
- stable success/error maps with `ok`, `device`, `action`, `member-id`,
  `artifacts`, `deltas`, status and error fields;
- raw binary file integration, sorted directory metadata, MIME-safe file
  serving, 200,000-byte output clipping and the `truncated` signal;
- bounded foreground/poll waits, optional positive background runtime
  deadlines, incremental output cursors, termination, bounded terminal-session
  retention and output, with backend timeout/error status preserved; and
- backend capability differences expressed only by `index` metadata and the
  private backend callbacks for read, write, list, and execute.

Attachments and archives are application consumers of the raw file and Bash
routes; they are not separate execution-engine routes and require no
application code in Andock. Background termination is the public
`bash-session` route and remains authorized by the existing `Bash` capability.
Request serialization remains ordinary AO-Core message resolution; the
private Android socket framing is not public.

## Ownership and packaging decision

The backend-neutral contract becomes `lib_permawebos_execution`, background
session lifecycle becomes `lib_permawebos_bash_session`, and the tool schema
becomes `lib_permawebos_execution_tools`, all under `devices/android/src/`.
Only backend-neutral portions of the established Docker contract move.
Docker process management, image names, application option keys,
provider/member/router logic, and the general application utility module do
not move.

`lib_andock` supplies the four private backend callbacks and the Android socket
transport. It passes neutral private options (`execution-device` and
`execution-backend`) to the contract. `dev_andock` contains only normal AO
handlers and the public `andock@1.0` identity.

The portable session implementation composes the four ordinary backend
callbacks. Andock additionally implements neutral private `session-start` and
`session-poll` transport callbacks because Android's isolated worker cannot
detach a PRoot tracee from a synchronous command safely. The app retains the
member image, isolated worker, fixed network capability and bounded output for
the session lifetime; poll and termination operate on that owned session.
Foreground access to a member with a live session fails busy instead of
opening the same ext4 image concurrently. Stop, destroy and app shutdown
terminate owned sessions before releasing their capabilities.

The Android overlay emits a standalone Andock archive using only this
repository's `src/` directory. Its archive boundary must require the Andock and
neutral PermawebOS modules and reject every entry containing `ouroboros`,
Docker/QEMU backends, or application device modules.

Android staging copies the Android overlay, including the self-contained
Andock sources, into the measured `andee_devices` package. The normal
HyperBEAM preload then emits and stores the signed `~andock@1.0` archive
alongside the other PermawebOS devices.
The APK continues to contain the generic native Andock capability, but no
application device or source checkout participates in its build.

## Compatibility and removals

The public device names `andock@1.0` and `docker@1.0`, request keys, response
maps, and Ouroboros node option are live observable contracts and remain.
There is no evidence of a live `ouroboros-andock` public protocol, so no alias
or compatibility layer is retained.

Search-and-destroy removes `OUROBOROS_SRC`, all `lib_ouroboros_*` references
from the PermawebOS tree, the old package import checks, application-coupled
documentation, and tests which treat an Ouroboros checkout as an OS build
input. Permanent agent and architecture guidance will state that application
packages are runtime composition only.

## Validation

Acceptance requires:

1. self-contained package compile, archive-boundary, and device tests;
2. contract tests for authorization, paths, files, deltas, clipping, timeout,
   serialization, network selection, and backend errors;
3. representative cross-backend vectors against `docker@1.0` and
   `andock@1.0`;
4. clean Android build with a negative APK/runtime scan for all Ouroboros
   names, modules, archives, pins, provenance, and checkout paths;
5. measured runtime composition and reproducibility checks; and
6. isolated-emulator boot plus runtime-loaded trusted Ouroboros and a second
   non-Ouroboros consumer using the same public Andock contract.

No HyperBEAM/AO-Core source, physical phone, remote repository, published
artifact, or production process is modified by this work.
