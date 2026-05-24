# Common HyperBEAM Packaging

HyperBEAM is treated as the PermawebOS kernel. Common HyperBEAM packaging rules:

- Build stock pinned HyperBEAM source.
- Add PermawebOS behavior through normal HyperBEAM device packages.
- Keep generated HyperBEAM checkouts under `build/`.

The current Linux implementation performs this in
`arch/common/linux/buildroot-external/package/hyperbeam/`. Android performs its
own runtime packaging in `arch/android/scripts/build-hb-android-runtime.sh`.
Move code here only when both architectures can share it directly.
