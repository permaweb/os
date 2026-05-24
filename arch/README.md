# Architectures

`arch/` contains operating-environment packaging for the PermawebOS
distribution. HyperBEAM remains the kernel. Each architecture decides how that
kernel is packaged, booted, measured, and given persistent storage while
sharing the common device protocols under `devices/common/`.

- `common/linux/` contains the shared Buildroot Linux appliance used by laptop,
  no-TME, TME, and SNP-capable images. LapEE is the laptop execution
  environment built from this layer.
- `snp/`, `tme/`, and `no-tme/` document the release targets layered on the
  common Linux appliance.
- `android/` contains AndEE, the Android Execution Environment: Android app
  packaging, runtime packaging, and Android-specific test harnesses.

Architecture targets are exposed from the top-level `Makefile`; keep new public
targets release/operator oriented and put mechanics inside the architecture
directory.
