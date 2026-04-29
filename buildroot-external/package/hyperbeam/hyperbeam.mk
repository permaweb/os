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

# Pin the v1-ish LapEE HyperBEAM branch state. Current `edge' does
# not yet carry dev_tpm2, dev_tpm_interpret, the lapee rebar profile,
# or the lapee_tpm_nif sources, so building it would produce a node
# without the appliance's attestation surface.
HYPERBEAM_VERSION ?= a9b360674d4c6c963a55d577ec5438bc7e24a3d8
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

define HYPERBEAM_SANITIZE_HOST_PATHS
	sed -i \
		-e 's|-I /usr/local/include||g' \
		-e 's|-L /usr/local/lib||g' \
		-e 's|-L /usr/lib||g' \
		$(@D)/native/secp256k1/Makefile
	sed -i \
		-e 's|-I/usr/local/lib/erlang/usr/include/|-I$(STAGING_DIR)/usr/lib/erlang/usr/include|g' \
		$(@D)/rebar.config
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_SANITIZE_HOST_PATHS

define HYPERBEAM_FIX_OTP27_EI_TYPES
	perl -0pi -e 's|long ptr, size;\n        int type;\n        ei_decode_tuple_header\(buff, &index, &arity\);\n        ei_decode_long\(buff, &index, &ptr\);\n        ei_get_type\(buff, &index, &type, &size\);\n        long size_l = \(long\)size;\n        char\* wasm_binary;\n        int res = ei_decode_bitstring\(buff, &index, &wasm_binary, NULL, &size_l\);\n        DRV_DEBUG\("Decoded binary\. Res: %d\. Size \(bits\): %ld", res, size_l\);\n        long size_bytes = size_l / 8;|long ptr;\n        int size, type;\n        ei_decode_tuple_header(buff, &index, &arity);\n        ei_decode_long(buff, &index, &ptr);\n        ei_get_type(buff, &index, &type, &size);\n        size_t size_bits;\n        const char* wasm_binary;\n        int res = ei_decode_bitstring(buff, &index, &wasm_binary, NULL, &size_bits);\n        DRV_DEBUG("Decoded binary. Res: %d. Size (bits): %lu", res, (unsigned long)size_bits);\n        long size_bytes = (long)(size_bits / 8);|s' \
		$(@D)/native/hb_beamr/hb_beamr.c
	perl -0pi -e 's#uint64_t argc = prepared_args\.size;\n    uint64_t\* argv = malloc\(sizeof\(uint64_t\) \* argc\);\n    \n    // Convert prepared arguments to an array of 64-bit integers\n    for \(uint64_t i = 0; i < argc; \+\+i\) \{\n        argv\[i\] = prepared_args\.data\[i\]\.of\.i64;\n    \}#uint32_t argc = 0;\n    for (size_t i = 0; i < prepared_args.size; ++i) {\n        argc += (prepared_args.data[i].kind == WASM_I64 || prepared_args.data[i].kind == WASM_F64) ? 2 : 1;\n    }\n    uint32_t* argv = malloc(sizeof(uint32_t) * argc);\n    \n    // Convert prepared arguments into WAMR packed 32-bit cells.\n    uint32_t argv_index = 0;\n    for (size_t i = 0; i < prepared_args.size; ++i) {\n        switch (prepared_args.data[i].kind) {\n            case WASM_I64:\n                memcpy(&argv[argv_index], &prepared_args.data[i].of.i64, sizeof(int64_t));\n                argv_index += 2;\n                break;\n            case WASM_F64:\n                memcpy(&argv[argv_index], &prepared_args.data[i].of.f64, sizeof(float64_t));\n                argv_index += 2;\n                break;\n            case WASM_F32:\n                memcpy(&argv[argv_index], &prepared_args.data[i].of.f32, sizeof(float32_t));\n                argv_index += 1;\n                break;\n            default:\n                argv[argv_index++] = (uint32_t)prepared_args.data[i].of.i32;\n                break;\n        }\n    }#s' \
		$(@D)/native/hb_beamr/hb_wasm.c
	perl -0pi -e 's|wasm_runtime_get_exception\(proc->exec_env\)|wasm_runtime_get_exception(wasm_runtime_get_module_inst(proc->exec_env))|g' \
		$(@D)/native/hb_beamr/hb_wasm.c
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_FIX_OTP27_EI_TYPES

define HYPERBEAM_ENABLE_MAYBE_EXPR
	grep -q '{feature, maybe_expr, enable}' $(@D)/rebar.config || \
		sed -i \
			"s/{erl_opts, \[debug_info,/{erl_opts, [debug_info, {feature, maybe_expr, enable},/" \
			$(@D)/rebar.config
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_ENABLE_MAYBE_EXPR

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
		'set(CMAKE_SYSTEM_NAME Linux)' \
		'set(CMAKE_SYSTEM_PROCESSOR x86_64)' \
		'set(CMAKE_C_COMPILER $(TARGET_CC))' \
		'set(CMAKE_CXX_COMPILER $(TARGET_CXX))' \
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
HYPERBEAM_BUILD_ENV = \
	PATH=$(@D)/.lapee-build:$(HOST_DIR)/bin:/home/builder/.cargo/bin:$(BR_PATH) \
	CC="$(TARGET_CC)" \
	CXX="$(TARGET_CXX)" \
	AR="$(TARGET_AR)" \
	RANLIB="$(TARGET_RANLIB)" \
	CFLAGS="$(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include/tss2 -I$(STAGING_DIR)/usr/include" \
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
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$(TARGET_CC)" \
	CC_x86_64_unknown_linux_gnu="$(TARGET_CC)" \
	AR_x86_64_unknown_linux_gnu="$(TARGET_AR)" \
	CFLAGS_x86_64_unknown_linux_gnu="$(TARGET_CFLAGS)" \
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
	# Slim: drop verifier-side data + Erlang sources
	# (compiled .beam is the runtime artefact; .erl sources are
	# debug-only weight). Keep priv/html and priv/static so the
	# HyperBuddy UI is served by the appliance.
	rm -rf $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*/priv/tpm-interpret
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
