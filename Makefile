# LapEE — top-level orchestrator.
#
# Two pieces:
#   - lapee-baremetal/  appliance build (kernel, HB release, USB image,
#                       verifier)
#   - lapee-paper/      paper sources + companion design notes
#
# Most build action lives in lapee-baremetal/Makefile; this one
# delegates so a fresh clone has a single `make' entry point.

.PHONY: help all build native-build paper clean

help:
	@echo "LapEE — top-level targets"
	@echo ""
	@echo "  make build              — fast build (Docker, host-arch container)"
	@echo "  make build REFERENCE=1  — reproducible build (linux/amd64 forced;"
	@echo "                            Rosetta on Apple Silicon, but byte-"
	@echo "                            identical output across hosts)"
	@echo "  make native-build       — Linux only, skip Docker"
	@echo "  make paper              — build the paper PDF + design notes"
	@echo "  make clean              — clean both subdirs"
	@echo ""
	@echo "First-time setup:"
	@echo "  cd lapee-baremetal && make toolchain"
	@echo ""
	@echo "Per-subdir help:"
	@echo "  make -C lapee-baremetal help"

# `make all' = paper + reference build (the publishable artefacts).
all: paper
	$(MAKE) -C lapee-baremetal build REFERENCE=1

build:
	$(MAKE) -C lapee-baremetal build $(if $(REFERENCE),REFERENCE=$(REFERENCE),)

native-build:
	$(MAKE) -C lapee-baremetal native-build

paper:
	$(MAKE) -C lapee-paper

clean:
	-$(MAKE) -C lapee-baremetal clean
	-$(MAKE) -C lapee-paper clean
