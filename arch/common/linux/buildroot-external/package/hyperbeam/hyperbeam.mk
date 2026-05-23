################################################################################
#
# hyperbeam — HyperBEAM release for LapEE.
#
# Cross-compiles HyperBEAM inside Buildroot. Two paths through
# the build:
#
#   1. Erlang code (.beam bytecode, platform-independent): compiled
#      by host-erlang's `erlc' driving stock rebar3.
#   2. LapEE C NIFs (lapee_tpm_nif): compiled by Buildroot's cross-gcc
#      (TARGET_CC) against staged libtss2 / OpenSSL headers from
#      $(STAGING_DIR)/usr/include.
#   3. Rust NIFs (hb_keccak via rustler): compiled by `cargo'
#      with a x86_64-unknown-linux-gnu cross target. The Rust
#      toolchain + target sysroot are installed in the build
#      container's Dockerfile; cargo links via TARGET_CC.
#
# The relx release is built using `--include-erts' pointing at
# the Buildroot-built target Erlang's erts directory under
# $(STAGING_DIR)/usr/lib/erlang, so the shipped beam.smp matches
# the rest of the target userspace.
#
# Output: /usr/lib/hyperbeam/{bin,lib,erts-*}/ in the rootfs,
# launched as PID 2 by /init.
#
################################################################################

# Track upstream HyperBEAM edge. LapEE-owned devices are packaged as
# an external Forge device source set and baked into the preloaded
# store without mutating the HyperBEAM checkout.
HYPERBEAM_VERSION ?= 8c19c6adb45fc658e1ac06e6555efd916fd305e5
HYPERBEAM_SITE = https://github.com/permaweb/HyperBEAM.git
HYPERBEAM_SITE_METHOD = git
HYPERBEAM_GIT_SUBMODULES = YES
HYPERBEAM_LICENSE = BSL-1.1
HYPERBEAM_LICENSE_FILES = LICENSE.md
HYPERBEAM_DEPENDENCIES = host-erlang erlang openssl tpm2-tss gmp

# rebar3 is not shipped in the HyperBEAM repo. Bootstrap from
# the canonical S3-hosted self-contained escript that the
# rebar3 project publishes. (GitHub-release URLs are flaky
# across versions; the S3 bucket has been the documented
# install method for years.)
HYPERBEAM_REBAR3_URL = https://s3.amazonaws.com/rebar3/rebar3

define HYPERBEAM_DOWNLOAD_REBAR3
	if [ ! -x $(@D)/rebar3 ]; then \
	    wget -q -O $(@D)/rebar3.tmp '$(HYPERBEAM_REBAR3_URL)' && \
	    chmod +x $(@D)/rebar3.tmp && \
	    mv $(@D)/rebar3.tmp $(@D)/rebar3; \
	fi
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_DOWNLOAD_REBAR3

HYPERBEAM_DEVICE_DIR ?= /build/common-devices

# Buildroot exports HyperBEAM from a git checkout into a plain source
# tree, so rebar's build-info hooks cannot rely on `.git' being
# present. Provide a tiny delegating wrapper: only `git rev-parse
# HEAD' is synthetic; clone/submodule operations still go to real git.
define HYPERBEAM_CREATE_BUILD_HELPERS
	mkdir -p $(@D)/.lapee-build
	printf '%s\n' \
		'#!/bin/sh' \
		'if [ "$$1" = rev-parse ] && [ "$$2" = HEAD ]; then' \
		'    echo "$(HYPERBEAM_VERSION)"; exit 0' \
		'fi' \
		'if [ "$$1" = rev-parse ] && [ "$$2" = --short ] && [ "$$3" = HEAD ]; then' \
		'    echo "$(HYPERBEAM_VERSION)" | cut -c1-12; exit 0' \
		'fi' \
		'exec /usr/bin/git "$$@"' \
		> $(@D)/.lapee-build/git
	chmod +x $(@D)/.lapee-build/git
	printf '%s\n' \
		'#!/bin/sh' \
		'set -e' \
		'crate=$$(basename "$$(pwd)")' \
		'if { [ "$$crate" = b64rs ] || [ "$$crate" = elmdb_nif ]; } && [ "$${1:-}" = build ]; then' \
		'    mkdir -p target' \
		'    /home/builder/.cargo/bin/cargo "$$@" >target/lapee-target-cargo.json' \
		'    target_so=$$(find target ../../target -path "*/$${CARGO_BUILD_TARGET:-__none__}/release/lib$$crate.so" -type f -print -quit 2>/dev/null || true)' \
		'    if [ -n "$$target_so" ]; then' \
		'        mkdir -p target/lapee-target/release' \
		'        cp -af "$$target_so" "target/lapee-target/release/lib$$crate.so"' \
		'    fi' \
		'    env -u CARGO_BUILD_TARGET \' \
		'        -u CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER \' \
		'        -u CC_x86_64_unknown_linux_gnu \' \
		'        -u AR_x86_64_unknown_linux_gnu \' \
		'        -u CFLAGS_x86_64_unknown_linux_gnu \' \
		'        -u __CARGO_TEST_CHANNEL_OVERRIDE_DO_NOT_USE_THIS \' \
		'        -u CARGO_UNSTABLE_HOST_CONFIG \' \
		'        -u CARGO_UNSTABLE_TARGET_APPLIES_TO_HOST \' \
		'        -u CARGO_TARGET_APPLIES_TO_HOST \' \
		'        -u LAPEE_REAL_CC -u LAPEE_REAL_CXX \' \
		'        -u CC -u CXX -u AR -u RANLIB \' \
		'        -u CFLAGS -u LDFLAGS \' \
		'        -u PKG_CONFIG_ALLOW_CROSS -u PKG_CONFIG_SYSROOT_DIR \' \
		'        -u PKG_CONFIG_PATH -u CMAKE_TOOLCHAIN_FILE \' \
		'        /home/builder/.cargo/bin/cargo "$$@"' \
		'    exit 0' \
		'fi' \
		'/home/builder/.cargo/bin/cargo "$$@"' \
		'for dir in target/*/release; do' \
		'    [ -d "$$dir" ] || continue' \
		'    mkdir -p target/release' \
		'    cp -af "$$dir"/*.so target/release/ 2>/dev/null || true' \
		'done' \
		> $(@D)/.lapee-build/cargo
	chmod +x $(@D)/.lapee-build/cargo
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -euo pipefail' \
		'real=$${LAPEE_REAL_CC:?}' \
		'args=()' \
		'while (($$#)); do' \
		'    arg=$$1; shift' \
		'    case "$$arg" in' \
		'        -I|-L|-isystem|-idirafter|-iquote)' \
		'            if (($$#)) && [[ "$$1" =~ ^/usr(/|$$) ]]; then' \
		'                shift' \
		'                continue' \
		'            fi' \
		'            args+=("$$arg")' \
		'            ;;' \
		'        -I/usr|-I/usr/*)' \
		'            ;;' \
		'        -L/usr|-L/usr/*)' \
		'            ;;' \
		'        -isystem/usr|-isystem/usr/*)' \
		'            ;;' \
		'        -idirafter/usr|-idirafter/usr/*)' \
		'            ;;' \
		'        -iquote/usr|-iquote/usr/*)' \
		'            ;;' \
		'        -Wl,-rpath,/usr|-Wl,-rpath,/usr/*|-Wl,-rpath-link,/usr|-Wl,-rpath-link,/usr/*)' \
		'            ;;' \
		'        *)' \
		'            args+=("$$arg")' \
		'            ;;' \
		'    esac' \
		'done' \
		'exec "$$real" "$${args[@]}"' \
		> $(@D)/.lapee-build/cc-filter
	chmod +x $(@D)/.lapee-build/cc-filter
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		'set -euo pipefail' \
		'export LAPEE_REAL_CC=$${LAPEE_REAL_CXX:?}' \
		'exec "$$(dirname "$$0")/cc-filter" "$$@"' \
		> $(@D)/.lapee-build/cxx-filter
	chmod +x $(@D)/.lapee-build/cxx-filter
	printf '%s\n' \
		'set(CMAKE_SYSTEM_NAME Linux)' \
		'set(CMAKE_SYSTEM_PROCESSOR x86_64)' \
		'set(CMAKE_C_COMPILER $(@D)/.lapee-build/cc-filter)' \
		'set(CMAKE_CXX_COMPILER $(@D)/.lapee-build/cxx-filter)' \
		'set(CMAKE_AR $(TARGET_AR))' \
		'set(CMAKE_RANLIB $(TARGET_RANLIB))' \
		'set(CMAKE_FIND_ROOT_PATH $(STAGING_DIR) $(TARGET_DIR))' \
		'set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)' \
		'set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)' \
		'set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)' \
		'set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)' \
		> $(@D)/.lapee-build/toolchain.cmake
	touch $(@D)/config.flat
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_CREATE_BUILD_HELPERS

# Cross-compile environment for rebar3 + cargo. rebar3's
# port_specs honours CC/CFLAGS/LDFLAGS; rebar3_cargo passes the
# full env through to cargo.
#
# Upstream native builds still inject absolute host include/library
# paths such as /usr/local/include and /usr/lib. Route native compile
# commands through cc-filter so the temporary HyperBEAM checkout stays
# unpatched while Buildroot's cross compiler only sees staged target
# headers and libraries.
#
# Upstream edge's native BEAMR C currently trips GCC 14 against OTP 27
# ei.h pointer types. Keep that as a single explicit compiler
# compatibility boundary instead of mutating upstream HyperBEAM source.
HYPERBEAM_C_NATIVE_COMPAT_FLAGS = \
	-Wno-error=incompatible-pointer-types

HYPERBEAM_BUILD_ENV = \
	PATH=$(@D)/.lapee-build:$(HOST_DIR)/bin:/home/builder/.cargo/bin:$(BR_PATH) \
	__CARGO_TEST_CHANNEL_OVERRIDE_DO_NOT_USE_THIS="nightly" \
	CARGO_UNSTABLE_HOST_CONFIG="true" \
	CARGO_UNSTABLE_TARGET_APPLIES_TO_HOST="true" \
	CARGO_TARGET_APPLIES_TO_HOST="false" \
	LAPEE_REAL_CC="$(TARGET_CC)" \
	LAPEE_REAL_CXX="$(TARGET_CXX)" \
	CC="$(@D)/.lapee-build/cc-filter" \
	CXX="$(@D)/.lapee-build/cxx-filter" \
	AR="$(TARGET_AR)" \
	RANLIB="$(TARGET_RANLIB)" \
	CFLAGS="$(TARGET_CFLAGS) $(HYPERBEAM_C_NATIVE_COMPAT_FLAGS) -I$(STAGING_DIR)/usr/include/tss2 -I$(STAGING_DIR)/usr/include" \
	LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib -L$(STAGING_DIR)/usr/lib/erlang/usr/lib -Wl,-rpath,/usr/lib" \
	PKG_CONFIG_ALLOW_CROSS=1 \
	PKG_CONFIG_SYSROOT_DIR="$(STAGING_DIR)" \
	PKG_CONFIG_PATH="$(STAGING_DIR)/usr/lib/pkgconfig:$(STAGING_DIR)/usr/share/pkgconfig" \
	OPENSSL_DIR="$(STAGING_DIR)/usr" \
	OPENSSL_LIB_DIR="$(STAGING_DIR)/usr/lib" \
	OPENSSL_INCLUDE_DIR="$(STAGING_DIR)/usr/include" \
	OPENSSL_NO_VENDOR=1 \
	CMAKE_TOOLCHAIN_FILE="$(@D)/.lapee-build/toolchain.cmake" \
	CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu \
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$(@D)/.lapee-build/cc-filter" \
	CC_x86_64_unknown_linux_gnu="$(@D)/.lapee-build/cc-filter" \
	AR_x86_64_unknown_linux_gnu="$(TARGET_AR)" \
	CFLAGS_x86_64_unknown_linux_gnu="$(TARGET_CFLAGS) $(HYPERBEAM_C_NATIVE_COMPAT_FLAGS)" \
	ERL_LIBS="$(HOST_DIR)/lib/erlang/lib"

define HYPERBEAM_BUILD_CMDS
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 compile
	rm -rf $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_tpm2/lapee_tpm_nif.beam \
	    $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_tpm2/lapee_tpm_nif.so \
	    $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_lapee_snp/lapee_snp_nif.beam \
	    $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_lapee_snp/crates/lapee_snp_nif
	mkdir -p $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_tpm2 \
	    $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_lapee_snp/crates/lapee_snp_nif
	cd $(HYPERBEAM_DEVICE_DIR)/src && \
	    $(HOST_DIR)/bin/erlc -o priv/dev_tpm2 lapee_tpm_nif.erl
	$(TARGET_CC) $(TARGET_CFLAGS) $(HYPERBEAM_C_NATIVE_COMPAT_FLAGS) \
	    -std=c11 -Wall -Wextra -Wno-unused-parameter -fPIC -O2 -shared \
	    -I$(STAGING_DIR)/usr/lib/erlang/usr/include \
	    -I$(STAGING_DIR)/usr/include/tss2 \
	    -I$(STAGING_DIR)/usr/include \
	    -o $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_tpm2/lapee_tpm_nif.so \
	    $(HYPERBEAM_DEVICE_DIR)/native/lapee_tpm_nif/lapee_tpm_nif.c \
	    $(HYPERBEAM_DEVICE_DIR)/native/lapee_tpm_nif/tpm_helpers.c \
	    $(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib \
	    -ltss2-esys -ltss2-mu -ltss2-tctildr -ltss2-rc -lcrypto
	cd $(HYPERBEAM_DEVICE_DIR)/src && \
	    $(HOST_DIR)/bin/erlc -o priv/dev_lapee_snp lapee_snp_nif.erl
	cd $(HYPERBEAM_DEVICE_DIR)/native/lapee_snp_nif && \
	    $(HYPERBEAM_BUILD_ENV) cargo build --release
	cp -af $(HYPERBEAM_DEVICE_DIR)/native/lapee_snp_nif/target/x86_64-unknown-linux-gnu/release/liblapee_snp_nif.so \
	    $(HYPERBEAM_DEVICE_DIR)/src/priv/dev_lapee_snp/crates/lapee_snp_nif/lapee_snp_nif.so
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 release \
		--include-erts $(TARGET_DIR)/usr/lib/erlang
	rm -rf $(@D)/_build/lapee-preload-src $(@D)/_build/preloaded-store
	mkdir -p $(@D)/_build/lapee-preload-src
	cp -a $(@D)/src/preloaded $(@D)/_build/lapee-preload-src/preloaded
	rm -f $(@D)/_build/lapee-preload-src/preloaded/auth/dev_snp.erl
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 device preload \
	    --device-src _build/lapee-preload-src/preloaded,$(HYPERBEAM_DEVICE_DIR)/src \
	    --output-dir _build/preloaded-store
endef

define HYPERBEAM_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib/hyperbeam
	cp -a $(@D)/_build/default/rel/hb/. $(TARGET_DIR)/usr/lib/hyperbeam/
	mkdir -p $(TARGET_DIR)/usr/lib/hyperbeam/_build
	cp -a $(@D)/_build/preloaded-store \
		$(TARGET_DIR)/usr/lib/hyperbeam/_build/preloaded-store
	cp -a $(@D)/_build/hb_preloaded_index.hrl \
		$(TARGET_DIR)/usr/lib/hyperbeam/_build/hb_preloaded_index.hrl
	mkdir -p $(TARGET_DIR)/usr/lib/hyperbeam/scripts
	cp -a $(@D)/scripts/schema.gql \
		$(TARGET_DIR)/usr/lib/hyperbeam/scripts/schema.gql
	cp -a $(@D)/scripts/hyper-token.lua \
		$(@D)/scripts/hyper-token-p4.lua \
		$(TARGET_DIR)/usr/lib/hyperbeam/scripts/
	for hb_app in $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*; do \
	    mkdir -p "$$hb_app/priv/lapee-p4"; \
	    cp -a $(@D)/scripts/hyper-token.lua \
	        $(@D)/scripts/hyper-token-p4.lua \
	        "$$hb_app/priv/lapee-p4/"; \
	done
	# relx runs under host-erlang, so OTP app priv/ binaries in
	# the release can be host-arch. Replace OTP apps with the
	# Buildroot target copies before target-finalize validates ELF
	# architecture.
	for d in $(TARGET_DIR)/usr/lib/hyperbeam/lib/*; do \
	    name=$$(basename "$$d"); \
	    if [ -d "$(TARGET_DIR)/usr/lib/erlang/lib/$$name" ]; then \
	        rm -rf "$$d"; \
	        cp -a "$(TARGET_DIR)/usr/lib/erlang/lib/$$name" \
	            "$(TARGET_DIR)/usr/lib/hyperbeam/lib/"; \
	    fi; \
	done
	if [ -f $(@D)/_build/default/lib/b64rs/native/b64rs/target/lapee-target/release/libb64rs.so ]; then \
	    for d in $(TARGET_DIR)/usr/lib/hyperbeam/lib/b64rs-*; do \
	        [ -d "$$d" ] || continue; \
	        mkdir -p "$$d/priv"; \
	        cp -af $(@D)/_build/default/lib/b64rs/native/b64rs/target/lapee-target/release/libb64rs.so \
	            "$$d/priv/b64rs.so"; \
	    done; \
	fi
	elmdb_target=$(@D)/_build/default/lib/elmdb/native/elmdb_nif/target/lapee-target/release/libelmdb_nif.so; \
	if [ ! -f "$$elmdb_target" ]; then \
	    elmdb_target=$(@D)/_build/default/lib/elmdb/priv/crates/elmdb_nif/elmdb_nif.so; \
	fi; \
	if [ -f "$$elmdb_target" ]; then \
	    for d in $(TARGET_DIR)/usr/lib/hyperbeam/lib/elmdb-*; do \
	        [ -d "$$d" ] || continue; \
	        mkdir -p "$$d/priv/crates/elmdb_nif"; \
	        cp -af "$$elmdb_target" \
	            "$$d/priv/crates/elmdb_nif/elmdb_nif.so"; \
	        cp -af "$$elmdb_target" \
	            "$$d/priv/libelmdb_nif.so"; \
	        ln -sf libelmdb_nif.so "$$d/priv/elmdb_nif.so"; \
	    done; \
	fi
	chmod +x $(TARGET_DIR)/usr/lib/hyperbeam/bin/hb
	# Slim: drop verifier catalogues + Erlang sources while keeping
	# TPM EK root CAs. The root-cas bundle is runtime trust data:
	# LapEE nodes use it to verify peers without accepting caller-
	# supplied root certificates.
	for d in $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*/priv/tpm-interpret; do \
	    [ -d "$$d" ] || continue; \
	    find "$$d" -mindepth 1 -maxdepth 1 ! -name root-cas \
	        -exec rm -rf {} +; \
	done
	find $(TARGET_DIR)/usr/lib/hyperbeam/lib -type d -name src \
		-exec rm -rf {} + 2>/dev/null || true
	for d in $(TARGET_DIR)/usr/lib/hyperbeam/lib/*; do \
	    rm -rf "$$d/doc" "$$d/examples" "$$d/man" "$$d/c_src"; \
	done
	test -f $(TARGET_DIR)/usr/lib/hyperbeam/lib/asn1-*/priv/lib/asn1rt_nif.so
	find $(TARGET_DIR)/usr/lib/hyperbeam $(TARGET_DIR)/usr/lib/erlang \
	    -type f \( -perm /111 -o -name '*.so*' \) -print0 \
	    | xargs -0 -r file \
	    | awk '/ELF/ && $$0 !~ /x86-64/ {print; bad=1} END {exit bad}'
	for tool in ct_run dialyzer typer erlc; do \
	    find $(TARGET_DIR)/usr/lib/hyperbeam/erts-* -name "$$tool" \
	        -delete 2>/dev/null || true; \
	done
	printf '%s\n' \
	    '[' \
	    '    {prometheus, [' \
	    '        {cowboy_instrumenter, [' \
	    '            {duration_buckets,' \
	    '                [0.001, 0.01, 0.1, 0.25, 0.5, 0.75, 1, 2, 4, 10, 30, 60]}' \
	    '        ]}' \
	    '    ]},' \
	    '    {os_mon, [' \
	    '        {start_disksup, false},' \
	    '        {start_memsup,  false},' \
	    '        {start_cpu_sup, false},' \
	    '        {start_os_sup,  false}' \
	    '    ]}' \
	    '].' \
	    > $(TARGET_DIR)/usr/lib/hyperbeam/releases/0.0.1/sys.config
	# Ship the splash daemon's compiled .beam under a dedicated
	# lib path so init's `-pa /usr/local/lib/lapee-splash' picks
	# it up. lapee_splash.erl lives in this BR2_EXTERNAL tree;
	# compiled by the post-build script using host-erlang.
endef

$(eval $(generic-package))
