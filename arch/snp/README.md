# Linux SNP Runtime

`make snp` builds the common Linux appliance for AMD SEV-SNP guests. SNP is the
virtualized PermawebOS architecture: HyperBEAM runs inside a guest whose memory
is protected by SEV-SNP hardware, and `~measurement@1.0` selects `~snp@1.0`
when real SNP guest support is present.

The image shares the Linux appliance and device package with the other Linux
targets. The architecture distinction is the hardware environment and
measurement backend, not a forked HyperBEAM protocol.
