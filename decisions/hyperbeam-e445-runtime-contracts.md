# HyperBEAM e445 runtime contracts

## Prompt

Update LapEE and AndEE from their pinned HyperBEAM predecessor to
`e445aad9da2a3017023ce99bd934540729e3b872`. Preserve portable AO/device
behavior and produce real, non-fallback native runtimes on supported targets.

## Decisions

### Consume the preloaded index from the store

e445 removed the generated `_build/hb_preloaded_index.hrl` file and the
`HB_PRELOADED_DEVICES_INDEX` environment-variable bootstrap. Forge now writes
the index ID as the LMDB link `~meta@1.0/preloaded-devices-index`. Packaging
therefore verifies that link through `hb_store_lmdb`; boot only requires the
verified preloaded store. Recreating the deleted header would fork Forge's
contract and create two index authorities.

### Use trusted signers as the remote-loading switch

e445 removed `load-remote-devices`. A nonempty `trusted-device-signers` list is
now both the enablement and authorization boundary. PermawebOS continues to
measure the effective node message, allows an operator to supply trusted
signers and public `name-resolvers`, and strips the obsolete switch. Empty
signers keep remote loading disabled. Resolver bindings remain unprivileged:
the implementation archive must still verify against a trusted signer, and the
effective bindings are committed by measurement.

### Package mandatory native components

e445 replaces `b64rs` with `b64veryfast` and makes `hb_util_string` a required
NIF. AndEE cross-builds those components with the NDK. It also packages the
secp256k1 NIF and the `hb_beamr` driver with a statically linked WAMR and
`libei`, rather than advertising modules whose native implementation is
missing. Buildroot explicitly passes its target architecture to
`b64veryfast` and fails installation if any required native component is
absent.

### Separate build-host Forge from the target release

Forge creates the preloaded store during the build and therefore executes
under host Erlang. It cannot load the x86-64 target NIFs while the Buildroot
container itself is ARM64. Buildroot now compiles host-native HyperBEAM/Forge
dependencies first, creates the architecture-independent LMDB store, removes
all host native artifacts, and then builds the x86-64 runtime and release.
The install gate rejects any non-x86-64 ELF in HyperBEAM or ERTS. This is a
real two-phase build, not a foreign-architecture execution fallback.

Upstream currently passes an unconditional x86 SSE flag to one host NIF and
defaults Linux WAMR to x86. Narrow build-host wrappers remove that flag only
on ARM hosts and set WAMR's actual host architecture. Target compilation still
uses the Buildroot compiler, sysroot, and `BR2_ARCH` without either adjustment.

### Declare the PermawebOS device input closure

Only `cargo-locks`, `native`, `src`, `rebar.config`, and `rebar.lock` are inputs
to the external device package. The Buildroot driver hashes and copies exactly
those paths. Copying the whole developer directory would pull ignored `_build`
caches and potentially `hyperbeam-key.json` into the builder and make an
unrelated local file influence an attested image.

The transient Buildroot container is named from the selected build volume
unless explicitly overridden. This makes the volume, source closure, process,
and artifacts one isolated build namespace instead of allowing one worktree to
remove another's globally named build container.

### Normalize build metadata after the final build hook

HyperBEAM's compile hook writes wall-clock time into `hb_buildinfo`. Both
packagers replace every shipped copy after their final rebar invocation with
the pinned source SHA, its 12-character short form, and the source commit
epoch. This preserves useful provenance without making identical source builds
attest to unrelated wall-clock values.

Forge's default preload command generates a build-only signing identity when
no key is supplied. PermawebOS excludes developer wallets from the declared
input closure and does not package that ephemeral private key. Consequently,
the signed store is immutable and measured once built, but a clean build is not
claimed to reproduce the same store bytes without an explicitly managed
packaging identity.

### Preserve the generic AO boundary

No application-specific decoder or message protocol is introduced. Android's
existing typed AO JSON decoder remains generic, and its EUnit coverage is part
of the upgrade gate. Remotely loaded devices continue through e445's normal
Forge package and trusted-signer resolution paths.

### Keep measurement unchanged

No measurement-device fork is required for this upgrade. PermawebOS already
commits the effective node message—including `trusted-device-signers`—and its
packaged runtime artifacts. The e445 source identity is also normalized into
the packaged `hb_buildinfo`. Changing `dev_measurement` would duplicate those
existing inputs without adding a new trust boundary.

## Alternatives rejected

- Retaining a pure-Erlang base64 override: silently changes a mandatory e445
  runtime capability and masks cross-build failures.
- Keeping `load-remote-devices` as a compatibility option: creates a second,
  misleading policy switch that upstream no longer reads.
- Treating native driver absence as an Android limitation: the required
  libraries cross-compile successfully with the pinned NDK, so omission would
  be a packaging bug rather than an honest platform constraint.
