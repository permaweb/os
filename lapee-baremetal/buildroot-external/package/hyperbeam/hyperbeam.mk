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

HYPERBEAM_VERSION = edge
HYPERBEAM_SITE = https://github.com/permaweb/HyperBEAM.git
HYPERBEAM_SITE_METHOD = git
HYPERBEAM_GIT_SUBMODULES = YES
HYPERBEAM_LICENSE = BSL-1.1
HYPERBEAM_LICENSE_FILES = LICENSE.md
HYPERBEAM_DEPENDENCIES = host-erlang erlang openssl tpm2-tss

# rebar3 is not shipped in the HyperBEAM repo. Bootstrap from
# the canonical rebar3 distribution (a self-contained escript).
# Pinning by version + sha256 is desirable but the upstream
# rebar3 binary changes per-release; for now use the GitHub
# release for a specific version. Bumping = update the version.
HYPERBEAM_REBAR3_VERSION = 3.24.1
HYPERBEAM_REBAR3_URL = https://github.com/erlang/rebar3/releases/download/$(HYPERBEAM_REBAR3_VERSION)/rebar3

define HYPERBEAM_DOWNLOAD_REBAR3
	if [ ! -x $(@D)/rebar3 ]; then \
	    wget -q -O $(@D)/rebar3.tmp '$(HYPERBEAM_REBAR3_URL)' && \
	    chmod +x $(@D)/rebar3.tmp && \
	    mv $(@D)/rebar3.tmp $(@D)/rebar3; \
	fi
endef
HYPERBEAM_PRE_BUILD_HOOKS += HYPERBEAM_DOWNLOAD_REBAR3

# Cross-compile environment for rebar3 + cargo. rebar3's
# port_specs honors CC/CFLAGS/LDFLAGS; rebar3_cargo passes the
# full env through to cargo.
HYPERBEAM_BUILD_ENV = \
	PATH=$(HOST_DIR)/bin:/root/.cargo/bin:$(BR_PATH) \
	CC="$(TARGET_CC)" \
	CXX="$(TARGET_CXX)" \
	AR="$(TARGET_AR)" \
	CFLAGS="$(TARGET_CFLAGS) -I$(STAGING_DIR)/usr/include/tss2 -I$(STAGING_DIR)/usr/include" \
	LDFLAGS="$(TARGET_LDFLAGS) -L$(STAGING_DIR)/usr/lib -Wl,-rpath,/usr/lib" \
	ERL_LIBS="$(HOST_DIR)/lib/erlang/lib" \
	CARGO_BUILD_TARGET=x86_64-unknown-linux-gnu \
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER="$(TARGET_CC)" \
	CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C link-arg=--sysroot=$(STAGING_DIR)"

define HYPERBEAM_BUILD_CMDS
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 as lapee compile
	cd $(@D) && $(HYPERBEAM_BUILD_ENV) ./rebar3 as lapee release \
		--include-erts $(TARGET_DIR)/usr/lib/erlang
endef

define HYPERBEAM_INSTALL_TARGET_CMDS
	mkdir -p $(TARGET_DIR)/usr/lib/hyperbeam
	cp -a $(@D)/_build/lapee/rel/hb/. $(TARGET_DIR)/usr/lib/hyperbeam/
	chmod +x $(TARGET_DIR)/usr/lib/hyperbeam/bin/hb
	# Slim: drop verifier-side data + browser UI + Erlang sources
	# (compiled .beam is the runtime artefact; .erl sources are
	# debug-only weight).
	rm -rf $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*/priv/html
	rm -rf $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*/priv/static
	rm -rf $(TARGET_DIR)/usr/lib/hyperbeam/lib/hb-*/priv/tpm-interpret
	find $(TARGET_DIR)/usr/lib/hyperbeam/lib -type d -name src \
		-exec rm -rf {} + 2>/dev/null || true
	# Ship the splash daemon's compiled .beam under a dedicated
	# lib path so init's `-pa /usr/local/lib/lapee-splash' picks
	# it up. lapee_splash.erl lives in this BR2_EXTERNAL tree;
	# compiled by the post-build script using host-erlang.
endef

$(eval $(generic-package))
