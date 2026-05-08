################################################################################
#
# hyperbeam — HyperBEAM release for LapEE.
#
# Cross-compiles HyperBEAM inside Buildroot. Two paths through
# the build:
#
#   1. Erlang code (.beam bytecode, platform-independent): compiled
#      by host-erlang's `erlc' driving rebar3 in `lapee' profile.
#   2. C NIFs (lapee_tpm_nif): compiled by Buildroot's cross-gcc
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

# Track upstream HyperBEAM edge. LapEE-owned TPM devices and the
# `lapee' build profile are staged from this repository's
# hyperbeam-overlay tree during the package pre-build step.
HYPERBEAM_VERSION ?= c1c07345a9a9f20c1489e7c977098f3fe4054c5c
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

HYPERBEAM_OVERLAY_DIR ?= $(BR2_EXTERNAL_LAPEE_PATH)/../hyperbeam-overlay
HYPERBEAM_OVERLAY_SCRIPT ?= $(BR2_EXTERNAL_LAPEE_PATH)/../scripts/stage-hyperbeam-overlay.sh

define HYPERBEAM_STAGE_LAPEE_OVERLAY
	LAPEE_HB_OVERLAY_DIR='$(HYPERBEAM_OVERLAY_DIR)' \
		'$(HYPERBEAM_OVERLAY_SCRIPT)' $(@D)
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_STAGE_LAPEE_OVERLAY

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
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 as lapee compile
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 as lapee release \
		--include-erts $(TARGET_DIR)/usr/lib/erlang
endef

define HYPERBEAM_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib/hyperbeam
	cp -a $(@D)/_build/lapee/rel/hb/. $(TARGET_DIR)/usr/lib/hyperbeam/
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
