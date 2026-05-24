# Linux TME Runtime

`make tme` builds the common Linux LapEE appliance with TME/SME required by the
measured kernel command line. TME provides memory confidentiality, not SNP-style
integrity, rollback protection, or virtualization isolation. PermawebOS makes
that useful by running as a single-purpose appliance with HyperBEAM as the only
intended userspace service.

This target reuses `arch/common/linux/` and `devices/common/`.
