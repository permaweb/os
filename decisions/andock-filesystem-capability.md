# Andock isolated filesystem capability

Status: accepted and implemented for ARM64 AndEE v1. This supersedes the
per-path Binder filesystem prototype retained on `agent/andock-1.0`.

## Decision

Give each member one complete writable sparse ext4 image. Pass only that
image's read-write descriptor to a dedicated Android isolated service. Parse
and mutate the image inside the isolated process with lwext4, and use PRoot
only to translate the Ubuntu/glibc process's Linux path and syscall surface to
the local image engine.

Do not use an overlay in v1. A full member image costs more storage, but it
keeps `/usr`, `/etc`, `/var`, `/tmp`, and `/root` uniformly writable and
removes the synchronous host round trip which made metadata-heavy package
installation unusable. Member creation preserves sparse extents, so the 8 GiB
logical capacity does not consume 8 GiB of Android storage.

The observable target is the Ouroboros `~docker@1.0` Linux environment: normal
APT, Python/pip/venv, Node/npm/node-gyp, compilers, Git, links, mmap, Unix
sockets, persistence, stop, destroy, timeouts, and host-controlled network
policy. Andock does not fork the seven-tool AO contract.

## Evidence behind the decision

The discarded prototype kept the immutable base and writable overlay in
app-private host directories. An isolated UID could not traverse those paths,
so each path operation crossed PRoot, a local socket, Binder, and a Kotlin
broker. On a Pixel 10 Pro Fold, CPU-only PyTorch installation took about
twelve minutes and a subsequent import/show/`du` workload took about three
minutes. More than two minutes were spent traversing roughly 13,000 files.

The implemented image-local engine reduced warm shell operations on the ARM64
emulator to about 0.23 seconds. Clean-member workload observations include:

- 10,000-file creation: 17.750 seconds; traversal: 1.838 seconds;
- CPU-only PyTorch installation: 86.497--87.189 seconds;
- Transformers installation: 64.988--69.629 seconds;
- warm PyTorch/Transformers composite: 16.6--16.9 seconds; and
- member clone plus first `true`: 0.636--0.757 seconds.

These are emulator release gates, not claims about physical-phone latency.
Real-phone performance remains an acceptance gate.

## Security boundary

PRoot is not the sandbox. The boundary is Android's kernel-enforced isolated
UID, SELinux `isolated_app` domain, and the descriptors explicitly delivered
over Binder. Each operation receives only:

1. the selected member image descriptor;
2. the bounded command transport; and
3. an Internet socket-creation capability only when `allow-network` is true.

The worker receives no descriptor for the app root, runtime directory,
immutable template, another member image, effective node configuration, node
wallet, provider credentials, crypto-agent socket, Android Keystore, or other
application data. Image and broker descriptors are close-on-exec and hidden
from the synthetic guest `/proc`; the tracee operates through the syscall
adapter rather than receiving the raw capabilities.

PRoot remains necessary even with the isolated UID. Android isolation does
not provide `chroot`, mount namespaces, a conventional Ubuntu root, glibc
loader resolution, or Linux pathname translation to an ext4 image. Removing
PRoot without replacing those compatibility semantics would produce a
Bionic/Android tool environment rather than the promised Linux environment.

The network-enabled path necessarily trusts the syscall adapter to mediate
destination-bearing calls before the brokered kernel socket is used. A
compromise of that adapter remains confined to the isolated UID and SELinux
domain, but a brokered public socket is an explicit capability. The
network-disabled path receives no Internet socket capability at all.

## Filesystem and descriptor model

Paths resolve by ext4 inode, never by concatenating guest text with an Android
host path. `/` is a virtual root; `..` cannot cross it. Absolute symlinks
restart at that root and relative symlinks at the containing directory.
Component, link-depth, and total-length bounds fail closed. Rename, link,
unlink, and directory operations resolve and revalidate their parent inodes.

Regular inodes are materialized into kernel memfds so native loaders, mmap,
locking, and descriptor APIs see ordinary file descriptions. Requested
read/write access is enforced by independently reopening the carrier with the
requested kernel mode. Read-only carriers cannot write or gain shared-write
access through `mmap` or `mprotect`. Legacy asynchronous I/O and guest
ancillary descriptor transfer are denied because they would bypass mutation
accounting or capability confinement.

Writable mappings and open descriptions hold explicit references. Dirty
ranges are coalesced and persisted on `fsync`, `fdatasync`, `msync`, last
close, teardown, and relevant truncation/size transitions. Mapping teardown
releases its carrier reference; cache eviction cannot invalidate a live
description or mapping.

Sparse files stay sparse end to end. The engine visits initialized ext4
extents rather than scanning logical holes, materializes only those extents,
tracks changed ranges, and writes back only data extents for a full sparse
rewrite. A regression creates a 512 MiB logical file with separated extents,
proves its ext4 block count remains bounded, reopens it, and verifies every
data and hole region.

## Linux compatibility limits

Andock presents effective UID/GID 0 to guest userland. It preserves the
template's real numeric ownership metadata, modes, timestamps, links, and
capabilities, while runtime ownership-changing calls use PRoot fake-root
semantics. This is sufficient for package managers and build tools but is not
a multi-user discretionary-access-control environment.

Runtime xattr access is deliberately limited to `user.*`. Template
construction preserves the Linux metadata needed by provisioned executables,
including `security.capability`, but untrusted commands cannot read, list,
add, or replace privileged xattr namespaces. `listxattr` filters unsupported
names rather than exposing entries which subsequent calls deny.

Device nodes, raw block access, and arbitrary host descriptors are not
representable. Synthetic `/dev` and `/proc` expose only the bounded interfaces
needed by normal userland. Direct audio devices, inbound Internet listeners,
kernel namespaces, cgroups, and Docker-equivalent privilege boundaries are
not part of v1.

## Member lifecycle and capacity

The deterministic Ubuntu template is packaged inside `andee-runtime.zip` as
an Android sparse image. Extraction expands it into an app-private sparse raw
image while hashing the complete logical byte stream. Startup verifies its
manifest, architecture, size, and digest before enabling Andock.

New members are created by a same-directory temporary sparse copy, fsynced,
atomically renamed, and followed by a directory fsync. Startup deletes
abandoned temporary images. Destroy stops and unbinds the worker before
deleting only the selected member image. Stop and app restart preserve the
image.

Creation requires the template's allocated size plus 512 MiB of host free
space. The native engine independently preserves the same 512 MiB host reserve
before metadata allocation and during writeback. This protects the Android app
from a guest consuming the final host blocks; the ext4 image's own capacity is
reported through guest `statfs`.

## Network capability

An isolated UID cannot create `AF_INET` or `AF_INET6` sockets. When networking
is enabled, the normal app UID creates only supported TCP/UDP sockets and
passes them as kernel descriptors. The syscall layer authorizes each numeric
destination at `connect`, `sendto`, `sendmsg`, and `sendmmsg`:

- loopback, unspecified, private, carrier-grade NAT, link-local, multicast,
  broadcast, documentation, benchmark, reserved, current-interface, and
  directly attached prefixes are denied;
- IPv4-mapped IPv6 is canonicalized before policy;
- private/link-local DNS is allowed only to the active Android resolvers on
  TCP or UDP port 53; and
- redirects, reconnects, and every unconnected UDP datagram are rechecked.

Raw, packet, netlink, SCTP, ICMP, inbound, and listening Internet sockets are
not brokered. Network-disabled commands receive no broker and fail Internet
socket creation with `EACCES`. Python, Node, copied binaries, subprocesses,
and static probes all encounter the same syscall boundary; no command-string
or environment-variable policy is involved.

Public IPv6/NAT64 behavior must be repeated on the physical phone because the
emulator does not prove every carrier network topology.

## Device, package, and measurement boundary

AndEE packages only the generic image engine, isolated-service lifecycle,
PRoot syscall layer, template, and private local transport. It contains no
Ouroboros router, provider, UI, member model, Python development server, or
authorization fork.

Ouroboros `~andock@1.0` is a standalone backend package. It selects the local
transport and delegates tools, validation, member lookup, serialization,
clipping, errors, files, attachments, and archives to
`lib_ouroboros_execution`, exactly as the Docker and QEMU backends do.

No Andock-specific measurement projection is added. The existing APK-set,
signing-certificate, runtime-ZIP, native-library-set, and effective node
message facts commit to the immutable implementation, template, manifests,
and selected execution configuration. Mutable member images remain outside
the measurement. See `andock-measurement.md`.

## Release acceptance

The host suites cover the image engine, path traversal, inode/descriptor and
mapping lifetime, sparse persistence, xattr filtering, network protocol, and
launcher. The emulator ladder must additionally prove:

- clean install and first boot;
- all seven operations and representative failures;
- APT, pip/venv/native wheels, Node/npm/node-gyp, compilers, Git, SQLite,
  archives, mmap/IPC, Unix sockets, PyTorch, Transformers, and offline model
  loading;
- persistence over stop, restart, and force-stop; deletion on destroy;
- serialized same-member operations and independent members;
- filesystem, config, wallet, crypto socket, sibling, and Android-data denial;
- disabled and enabled IPv4/IPv6/TCP/UDP/DNS/redirect network policy; and
- the ordinary AndEE config, build, smoke, scenario, zone-storage, Android,
  and mixed gates with measurement preflight.

Current emulator thresholds are 500 ms for an ordinary warm command, 95
seconds for the pinned CPU-only PyTorch installation, and 20 seconds for the
warm ML composite. Threshold changes cannot substitute for fixing a product
regression. Package preinstallation, command detection, hidden host execution,
or weakened isolation cannot satisfy a gate.

The release remains pending until the same performance, isolation,
persistence, network, provider-backed agent, and browser flow pass on a real
unrooted ARM64 phone.
