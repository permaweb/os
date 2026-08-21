.PHONY: compile unit-test andock-package andock-package-boundary-test \
	inference-package inference-package-boundary-test test

compile:
	rebar3 compile

unit-test:
	rebar3 eunit

andock-package:
	./scripts/andock-device.sh package

andock-package-boundary-test: andock-package
	./scripts/test-andock-package-boundary.sh
	./scripts/test-andock-application-boundary.sh

inference-package:
	./scripts/inference-device.sh package

inference-package-boundary-test: inference-package
	./scripts/test-inference-package-boundary.sh
	./scripts/test-andock-application-boundary.sh

test: compile unit-test andock-package-boundary-test inference-package-boundary-test
	./scripts/andock-device.sh test
	./scripts/inference-device.sh test
