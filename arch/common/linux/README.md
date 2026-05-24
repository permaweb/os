# Common Linux Appliance

This directory contains the shared Buildroot Linux appliance used by the
current Linux PermawebOS images:

- LapEE with TME enforced (`make tme` / `make runtime-image TME=1`).
- LapEE no-TME, typically used for LPDDR or debugging policy (`make no-tme` /
  `make runtime-image TME=0`).
- SNP-capable Linux runtime for AMD SEV-SNP guests (`make snp`).
- Secure Boot and encrypted-zone-storage provisioner (`make provisioner`).

The Buildroot external tree builds a stock pinned HyperBEAM checkout, then
preloads PermawebOS devices from `devices/common/`. Do not patch the fetched
HyperBEAM source from here; package devices instead.
