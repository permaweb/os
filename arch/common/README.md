# Common Architecture Components

Common components are shared by more than one PermawebOS architecture.

- `linux/` owns the Buildroot-based appliance OS used by the current x86_64
  Linux targets.
- `hb/` records the shared rule for HyperBEAM packaging: use stock pinned
  HyperBEAM and preload PermawebOS behavior as device packages.

Keep shared code here only when it is genuinely architecture-neutral at this
layer. HyperBEAM device logic should normally live under `devices/`.
