# STATUS: AndEE Tunnel + Payments Launch Hardening

Branch: `agent/andee-tunnel-payments`

Base: `main` at `5b7b0a43` (`Prepare production PermawebOS launch paths`),
pushed to `arweave://lapee`.

## Commander's Intent

Make PermawebOS launch-ready for AndEE nodes that stay reachable through a
public LapEE/SNP tunnel coordinator:

1. Find and fix why AndEE becomes extremely slow under live tunnel/zone use.
2. Prove an emulator AndEE can keep a working public tunnel through
   `https://www.smoke.solutions`.
3. Prove real AO-payment flows for tunneling, bundling, and oracle services.
4. Deploy the fixed `tunnel@1.0` archive from `~/src/devices/tunnel@1.0`
   once the core AndEE work is stable.
5. Keep a conservative improvement list for anything not safe to change tonight.

## Current External State

- Smoke SNP node: `https://www.smoke.solutions`, backend on
  `hb@dev-1.forward.computer:/home/hb/permawebos-smoke-solutions`, host port
  `2001`.
- Current smoke node address observed after latest restart:
  `3rQ3FE_ptqlvJtrlDe8ml6vv6BFIUC-z_cAb_zrtTQ8`.
- Current trusted `tunnel@1.0` archive:
  `DJb6D9QKd7tYcggYopvrrln0a0QQhfxWa1H2GQM8NG0`.
- Remote updater prepared:
  `/home/hb/permawebos-smoke-solutions/update-tunnel-device.sh NEW_ARCHIVE_ID`.

## First Hypotheses For AndEE Slowness

- Store retry storm observed on real AndEE events endpoint:
  `store_error.store_call_failed_retrying` was previously around `309915`.
- Suspect mis-shaped `loaded-devices` / trusted device config may cause repeated
  remote load attempts or gateway-store misses.
- Need distinguish:
  - Android-side store/config issue.
  - Tunnel registration/call loop issue.
  - HyperBEAM remote device loading/store materialization issue.

## Work Log

- [x] Pushed `main` checkpoint `5b7b0a43`.
- [x] Created working branch `agent/andee-tunnel-payments`.
- [ ] Reproduce AndEE slowness with emulator and collect event counters.
- [ ] Minimize root cause and patch only if the fix is local to PermawebOS.
- [ ] Validate sustained public tunnel from emulator AndEE through smoke node.
- [ ] Prove payment flows for tunnel, bundler, and oracle.
- [ ] Publish/deploy fixed `tunnel@1.0` archive.
- [ ] Final conservative cleanup and launch validation.

## Potential Issues / Improvements Not Yet Acted On

- Manual wildcard certificate renewal for `smoke.solutions` needs operator
  follow-up before `2026-08-24`, unless DNS automation is added.
- The smoke SNP QEMU has no persistent HB identity yet; its address changes on
  reboot. Fine for testing, likely wrong for permanent production service.
