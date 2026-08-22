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
private copy before use. Never commit the private copy.

To materialize an ignored deployment copy from an existing Ouroboros JSON
containing provider credentials:

```sh
arch/android/scripts/prepare-deployment-config.py \
  --secrets ~/src/ouroboros/custom.json \
  --location-url https://NODE.smoke.solutions
```

The command writes
`arch/android/build/deployment/andee-ouroboros-smoke.json` with mode `0600`.
Providers without a key in the source file are omitted from that private copy;
the committed sample retains their redacted entries as documentation.
