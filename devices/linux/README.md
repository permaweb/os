# Linux Docker execution device

This package owns the application-neutral `docker@1.0` execution device for
Linux PermawebOS. It implements the shared contract in
`devices/common/src/sandbox/`:
Read, Write, Append, Edit, Glob, Grep, Bash, BashSession, and the file-browser
routes.

Build and test the standalone trusted-device archive with:

```sh
make test
```

The device has no default container image. An operator must configure
`permawebos-docker-image`; readiness remains closed until the private Unix
socket daemon at `/run/lapee/docker-runtime/state/engine.sock` is healthy and
that image is present locally.

The configured image must provide Bash, Python 3, GNU `timeout`, ripgrep,
find, and the ordinary core file utilities. Its application entrypoint, user,
working directory, and health check are not executed or inherited.

Within one boot, containers are persistent per member. Their network policy is
fixed from member metadata before the first operation creates the container
and defaults to disabled; later execution calls cannot change it. The default
`permawebos-docker-volume` is `ephemeral`: the
adapter mounts each hashed workspace as a separately bounded tmpfs below the fixed
`/run/lapee/docker-runtime/members` root, then bind-mounts it at `/root`.
Files survive container stop/start but not a LapEE reboot. `zone` is a reserved
fail-closed mode: every routed AO-Core operation returns `{failure, ...}` until
a quota-enforced, executable workspace on the matching `zone@1.0` encrypted
volume is implemented. It never silently falls back to ephemeral storage.
The remaining root filesystem is read-only. Every capability is dropped,
`no-new-privileges` is enabled, and memory, CPU, PID, workspace-storage, and
temporary-filesystem defaults are explicit. Existing containers are rejected
unless their image ID, full member identity, workspace, and deterministic
configuration fingerprint match the current request. Image entrypoints, users,
working directories, and health checks cannot replace the adapter's fixed idle
process and workspace context.
