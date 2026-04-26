# LapEE

**LapEE** (Laptop Execution Environment) is an attested-appliance
reference implementation for HyperBEAM. You write one ~1 GB image
to a USB stick, plug the stick into a commodity TPM2 laptop, and
the laptop boots as a measured + signed HyperBEAM node: the TPM
endorses its own identity in silicon, the firmware event log
records every measurement from UEFI handoff through UKI load, and
HyperBEAM emerges as PID 2 serving a TPM-quoted attestation
envelope at `/~tpm2@2.0a/attestation`. A verifier parses the
envelope into an auditable dashboard. Zero synthesised values
anywhere in the runtime path — every field comes from a live
hardware signal or is recorded as explicitly absent.

This repo is two pieces:

- **`lapee-paper/`** — the paper. Spec + threat model +
  architecture + worked example. Build the PDF with
  `make -C lapee-paper`.
- **`lapee-baremetal/`** — the appliance build. Kernel,
  HyperBEAM release, init, splash, USB image, and the offline
  verifier. Build the USB stick with
  `make -C lapee-baremetal toolchain && make -C lapee-baremetal …`.

Quick start in [lapee-baremetal/README.md](lapee-baremetal/README.md).

## Toolchain

The build is hermetic — pinned upstream Docker bases (by SHA-256
digest) wrap a Bootlin pre-built x86_64 musl cross-toolchain
(downloaded automatically by Buildroot on first build). Bumping a
toolchain piece means changing one line in
[`lapee-baremetal/Makefile`](lapee-baremetal/Makefile); a previous
LapEE generation lost a working build because an unpinned
`erlang:27` floated to a newer glibc than the bundled erts had
linked against, and this revision is what stops that recurring.

The output is always x86_64 Linux. Host architecture detection in
the Makefile sets `--platform=linux/amd64` only on non-x86_64
hosts (Apple Silicon, etc.), so the same `make` works native on
x86_64 hosts and via Rosetta on M-series Macs.

## Where things came from

- The appliance source originates from two HyperBEAM worktrees
  (`agent/lapee` and `agent-/sharp-lichterman`), curated to drop
  Docker custom-builder artefacts and dead Buildroot packages.
- The HyperBEAM source itself is fetched separately by
  `make -C lapee-baremetal hb-fetch` (clones from
  `https://github.com/permaweb/HyperBEAM.git`, or rsyncs a local
  checkout when `HB_SRC=path` is set).

## Repo conventions

- Operating notes for collaborators (including AI assistants) live
  in [`lapee-baremetal/CLAUDE.md`](lapee-baremetal/CLAUDE.md).
  Two failure modes — reward-hacking and time-anchoring — recur
  on this project; the doc is the antidote.
- `secureboot/` and `wifi.conf` (operator-private) are
  gitignored; never commit them.
- The paper PDF in `lapee-paper/main.pdf` is committed so a fresh
  clone has a readable artefact without a TeX install.
