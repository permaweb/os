# Cut Ledger

Every production code removal must be recorded here with the reason and the
validation that covers the product behavior.

| Cut | Reason | Validation |
| --- | --- | --- |
| Public `~tpm-interpret@1.0` device and historical catalogues | The v1 product verifies TPM evidence through `~measurement@1.0` and `~tpm@2.0a`; broad OS/firmware archaeology is not an end-user service surface. | `~tpm@2.0a` retains EK roots, AIA fixtures, TPM quote/PCR/event-log verification, and QEMU/remote acceptance remains the product gate. |
| HyperBEAM source overlay model | PermawebOS should package stock HyperBEAM plus device packages, not patch the kernel checkout from this repository. | Linux and Android builds stage `devices/common/` and architecture overlays through the package flow; QEMU and remote SNP tests cover the packaged-device runtime. |
