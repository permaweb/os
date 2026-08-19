# `docker@1.0`

`docker@1.0` is the generic Docker execution device for Linux PermawebOS. It
implements the platform execution contract with one persistent, isolated
container per member.

## Routes

`Read`, `Write`, `Append`, `Edit`, `Glob`, `Grep`, `Bash`, and `BashSession`
use the shared request and response contract. `read-file`, `write-file`, and
`list-files` provide the file-browser routes.

The index reports `readiness=ready` only when `DOCKER_HOST` identifies the fixed private
`/run/lapee/docker-runtime/state/engine.sock` Unix socket, the server answers
`docker info`, an operator configured
`permawebos-docker-image`, and that image resolves locally. Images are never
pulled implicitly, and images that declare additional Docker volumes are
rejected before readiness. Otherwise it reports `readiness=not-ready` with
HTTP status 503 and a bounded error.

## Volume policy

`permawebos-docker-volume` accepts `ephemeral` (the default) or `zone`.
Ephemeral workspaces survive container stop/start within one LapEE boot and
are lost on reboot. This is intentionally narrower than Andock's app-private
member images and a conventional Docker daemon on durable host storage, both
of which survive a host-runtime restart. `zone` is reserved for a future
workspace backed by the matching `zone@1.0` encrypted volume. Until its
executable mount and per-member quota contract is implemented, selecting
`zone` returns an AO-Core `{failure, ...}` with status 503 for every routed
operation. It never falls back to ephemeral storage. Invalid values fail in
the same way.

## Isolation and limits

Each member receives a stable container name and a host-controlled workspace
below the fixed `/run/lapee/docker-runtime/members` root, mounted at `/root`.
Each workspace is a separately sized tmpfs, so its contents survive container
stop/start while its storage limit applies to the actual writable files. No
caller-selected host path and no Docker socket is mounted. The rest of the
image is read-only. Before the first operation creates the member container,
the adapter binds its immutable network policy from member metadata; omission
disables networking. This ordering also applies to file and BashSession
bookkeeping operations. A later operation cannot change that policy and fails
with status 409 instead. Every container has all
capabilities dropped, `no-new-privileges`, and explicit memory, CPU, PID,
workspace-storage, and `/tmp` limits.

The defaults are 512 MiB memory, one CPU, 256 PIDs, a 512 MiB workspace,
and a 64 MiB `/tmp`. Operators may set `permawebos-docker-{memory,cpus,pids,
storage,tmpfs}` in measured node configuration. The image, resolved image ID,
full member hash, volume and network policies, workspace, and normalized
security/resource configuration are bound into container metadata and checked
before every reuse.

The adapter overrides application metadata from the image: the member
container always runs as numeric root in `/root`, uses `sleep infinity` only as
its idle process, and has image health checks disabled. The image supplies the
tools and filesystem, not an application entrypoint. Those effective fields
are inspected before every reuse alongside the resource and isolation settings.

Member metadata must explicitly set `allow-network` on the first member
operation to enable the Docker bridge. Omission fails closed for Docker without
changing the Andock default. Changing the policy will be a separate lifecycle
operation; execution calls never silently mutate it.
