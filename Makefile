# LapEE — top-level orchestrator.
#
# The repo is two pieces:
#   - lapee-baremetal/  (the appliance build: kernel, HB release,
#                       USB image, verifier)
#   - lapee-paper/      (the paper sources)
#
# Most build action lives in lapee-baremetal/Makefile; this one
# delegates so a fresh clone has a single `make' entry point.

.PHONY: help all baremetal paper clean

help:
	@echo "Targets:"
	@echo "  make all        — build everything (paper + baremetal)"
	@echo "  make baremetal  — alias for: make -C lapee-baremetal"
	@echo "  make paper      — build the paper PDF"
	@echo "  make clean      — remove generated files in both subdirs"
	@echo ""
	@echo "First-time setup:"
	@echo "  cd lapee-baremetal && make toolchain   # pull pinned bases"
	@echo "  cd lapee-baremetal && make hb-fetch    # clone HyperBEAM"
	@echo ""
	@echo "Per-subdir help:"
	@echo "  make -C lapee-baremetal help"

all: baremetal paper

# Bare-metal: run the full production chain in lapee-baremetal.
# `make -C lapee-baremetal' alone would invoke `help' (the first
# target there) and exit 0 without building anything — silently
# misleading. Be explicit.
baremetal:
	$(MAKE) -C lapee-baremetal all

paper:
	$(MAKE) -C lapee-paper

clean:
	-$(MAKE) -C lapee-baremetal clean
	-$(MAKE) -C lapee-paper clean
