# `andock@1.0`

`andock@1.0` implements the generic PermawebOS Linux execution-engine contract:
`read`, `write`, `append`, `edit`, `glob`, `grep`, and `bash`, plus the shared
`bash-session` control and file-browsing routes. `lib_permawebos_execution`
owns authorization, validation, deltas, clipping, errors, timeouts, and status
codes. `bash-session` uses the existing `Bash` capability and supports
incremental output cursors, bounded waits, optional runtime deadlines, and
termination.

One member has one execution lane. While its background Bash session is
running, another Bash or filesystem/tool request fails immediately with status
409 and `error=member-session-active`; the response identifies the active
`session-id` and `execution-status`, names `bash-session` as the control action,
and lists `poll`, `wait`, and `terminate` as the available operations. The
rejected request does not stop or otherwise disturb the active session. Poll,
stop, destroy, and service shutdown remain lifecycle controls rather than
competing executions.

The backend is available when HyperBEAM runs inside an AndEE Android app that
provides the private `ANDEE_EXECUTION_SOCKET` capability. Selecting the device
on another node fails closed with status 503; it does not fall back to host
execution or another backend.

## Isolation and storage

Each member has one complete persistent writable Ubuntu filesystem image.
Android runs each active member under a distinct isolated UID and SELinux
`isolated_app` domain. PRoot supplies Linux pathname, fake-root, executable,
and loader behavior; it is not the security boundary and the device does not
claim VM, namespace, cgroup, or container-kernel isolation.

The isolated worker receives only its member image, bounded command transport,
and the selected network capability. It does not receive the AndEE app root,
node wallet, provider keys, effective node configuration, crypto-agent socket,
immutable template, or another member image. Stop preserves the member image;
destroy removes it.

## Network policy

An Android isolated UID has no Internet permission. Network-disabled members
therefore cannot create IPv4 or IPv6 Internet sockets. When a member explicitly
allows networking, AndEE brokers individual permitted Internet socket
descriptors from the app process. The policy is outside the guest and is not
implemented by inspecting command strings.

## Package boundary

The Andock source package owns the device and its private local transport. It
imports the neutral contract from `devices/common/src/sandbox/` at package time and
builds from PermawebOS source alone. Its emitted archive contains no
application router, provider, UI, member model, node mode, or configuration.
