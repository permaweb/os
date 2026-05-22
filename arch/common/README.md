# Common Architecture Components

Common components are shared by more than one PermawebOS architecture.

- `linux/` owns the Buildroot-based appliance OS used by the current x86_64
  Linux targets.

Keep shared code here only when it is genuinely architecture-neutral at this
layer. HyperBEAM device logic should normally live under `devices/`.
