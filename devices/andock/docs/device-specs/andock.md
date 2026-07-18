# `andock@1.0`

`andock@1.0` implements the same public Linux tool contract as the execution
devices used by Ouroboros: `read`, `write`, `append`, `edit`, `glob`, `grep`,
and `bash`, plus the shared file-browsing routes. Authorization, validation,
deltas, clipping, errors, and status codes come from the same
`lib_ouroboros_execution` source used to package the other backends.

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

The Andock source package owns only the device adapter and its private local
transport. At package time it imports the canonical shared execution contract
from an Ouroboros source checkout; it does not fork that contract. Its emitted
archive contains no Ouroboros router, provider, UI, member model, node mode, or
configuration.
