# STATUS: v0.1 Gold Release Split

Branch: `main`

Gold base: `7493d138c6fe991282536ce95056af86e019c355`
(`Fix AndEE startup and store retry storms`).

## Current Decision

`main` is the v0.1 release line. It keeps the production PermawebOS launch
paths and the AndEE startup/store-storm fix.

The unfinished tunnel and late AO-payment edits are parked on
`feat/andee-tunnels` at
`7646a5183bb361b4d2448eb0a1db4cea8310d4e0`.

## Included In Gold

- Production PermawebOS launch paths through `5b7b0a43`.
- Linux appliance OTP 28.5 support.
- Security-finding fixes already merged before the tunnel/payment branch.
- AndEE startup and store retry-storm fix:
  - stream Android runtime/APK hashing instead of loading large files into
    Java byte arrays;
  - mark AndEE gateway stores read-only;
  - disable the LMDB-oriented default `match-index` on AndEE.

## Excluded From Gold

- `tunnel@1.0` packaging and runtime hooks.
- Public `smoke.solutions` tunnel deployment work.
- Tunnel metering and tunnel payment routes.
- Late AO-payment scheduler-shape and HTTP-client changes from the parked
  tunnel/payment stack.
- Any unpublished tunnel device archive IDs.

## Notes

- The AO-payment changes from the parked branch were not proven necessary for
  the core paid bundling launch flow. A prior configuration using trusted
  remote device archives is the safer release path unless targeted validation
  proves otherwise.
- `feat/andee-tunnels` has been pushed to `arweave://lapee`.
- The `Github` remote (`https://github.com/permaweb/os.git`) is configured in
  this checkout, but this shell has no GitHub HTTPS credentials, no GitHub SSH
  key access, and no `gh` CLI. GitHub push is blocked until credentials are
  supplied or the remote is pushed from an authenticated environment.

## Next Validation

- Build v0.1 gold SNP and no-TME images from `main`.
- Boot the SNP image on the remote SEV-SNP host.
- Start a zone on the SNP node.
- Join with real hardware against the gold zone.
