# Common Linux Appliance

This directory contains the shared Buildroot Linux appliance used by the
current LapEE Linux images:

- TME-enforced runtime (`make tme` / `make runtime-image TME=1`).
- Measured no-TME runtime (`make no-tme` / `make runtime-image TME=0`).
- SNP-capable Linux runtime (`make snp`).
- Secure Boot and encrypted-storage provisioner (`make provisioner`).

The Buildroot external tree builds a stock pinned HyperBEAM checkout, then
preloads the selected PermawebOS device package from `devices/common/`.
Do not patch the fetched HyperBEAM source from here; package devices instead.
