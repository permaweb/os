OUROBOROS_SRC ?=

.PHONY: compile package package-boundary-test test

compile:
	rebar3 compile

package:
	OUROBOROS_SRC="$(OUROBOROS_SRC)" ./scripts/device.sh package

package-boundary-test: package
	./scripts/test-package-boundary.sh

test: compile package-boundary-test
	OUROBOROS_SRC="$(OUROBOROS_SRC)" ./scripts/device.sh test
