.PHONY: compile unit-test package package-boundary-test test

compile:
	rebar3 compile

unit-test:
	HB_PORT=0 rebar3 eunit

package:
	./scripts/device.sh package

package-boundary-test: package
	./scripts/test-package-boundary.sh
	./scripts/test-application-boundary.sh

test: compile unit-test package-boundary-test
	./scripts/device.sh test
