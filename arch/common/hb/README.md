# Common HyperBEAM Packaging

HyperBEAM is treated as the PermawebOS kernel. Common HyperBEAM packaging rules:

- Build stock pinned HyperBEAM source.
- Add PermawebOS behavior through normal HyperBEAM Forge device packages.
- Keep generated HyperBEAM checkouts under `build/`.
- Do not patch HyperBEAM from this repository; changes that belong in the
  kernel must be upstream HyperBEAM changes.

The current Linux implementation performs this in
`arch/common/linux/buildroot-external/package/hyperbeam/`. Android performs its
own runtime packaging in `arch/android/scripts/build-hb-android-runtime.sh`.
Move code here only when both architectures can share it directly.
