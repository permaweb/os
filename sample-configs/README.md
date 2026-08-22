# Sample operator configurations

These files are operator overlays, not replacement AndEE base configurations.
Import one through the AndEE **Next boot config** picker, then terminate and
reopen AndEE. The app deep-merges the overlay with its measured,
application-agnostic base configuration and measures the resulting effective
node configuration at boot.

`andee-ouroboros-smoke.json` pins the published Ouroboros and tunnel device
implementations, explicitly includes the `local-andee` provider and measured
model catalogue, keeps the preloaded `inference@1.0` multiplexer in use, and
adds authenticated remote providers. Every `****` value must be replaced in a
private copy before use. Replace `**[base32 encoded node address]**` with the
base32 encoding of the boot node address. Never commit the private copy.

To materialize an ignored deployment copy from an existing Ouroboros JSON
containing provider credentials:

```sh
arch/android/scripts/prepare-deployment-config.py \
  --secrets ~/src/ouroboros/custom.json \
  --location-url https://BASE32_NODE_ADDRESS.smoke.solutions
```

The command writes
`arch/android/build/deployment/andee-ouroboros-smoke.json` with mode `0600`.
The location URL also supplies the corresponding `node-host`.
Providers without a key in the source file are omitted from that private copy;
the committed sample mirrors the deployed provider set with credentials
replaced by `****`.

The tunnel-backed sample intentionally omits the `name@1.0` request hook.
Tunnel host routing removes its routing `Host` before local execution, while
`name@1.0` treats a root request without a host as a 404. Keeping the manifest
and blacklist hooks allows the root `default-request` redirect to run normally.
