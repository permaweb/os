# Architectures

`arch/` contains operating-environment packaging for the PermawebOS
distribution. HyperBEAM remains the kernel; each architecture decides how that
kernel is packaged, booted, measured, and given persistent storage.

- `common/linux/` contains the shared Buildroot Linux appliance used by laptop,
  no-TME, TME, and SNP-capable images.
- `android/` contains the HandEE Android app, Android runtime packaging, and
  Android-specific test harnesses.

Architecture targets are exposed from the top-level `Makefile`; keep new public
targets release/operator oriented and put mechanics inside the architecture
directory.
