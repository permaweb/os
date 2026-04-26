# Buildroot host environment for the LapEE x86_64 kernel build.
#
# Buildroot itself uses Bootlin's pre-built x86_64 musl stable
# toolchain (see configs/lapee_defconfig:
#   BR2_TOOLCHAIN_EXTERNAL_BOOTLIN_X86_64_MUSL_STABLE=y
# ). Buildroot downloads the toolchain tarball on first build and
# caches it in the docker volume — there is no host-gcc build, no
# manual cross-compiler install. This image only provides the
# tools Buildroot needs to orchestrate the build (gawk/perl/cpio
# /etc.) plus the headers used by a handful of host helpers.
#
# FROM is pinned to a specific debian:12-slim digest so an
# upstream point-release that bumps glibc cannot silently break
# the bundled erts at runtime — the regression that motivated
# this rebuild.
FROM debian:12-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        file \
        flex \
        g++ \
        gawk \
        gzip \
        libelf-dev \
        libncurses-dev \
        libssl-dev \
        perl \
        pkg-config \
        python3 \
        rsync \
        sed \
        unzip \
        wget \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Buildroot refuses to run as root.
RUN useradd -m -s /bin/bash builder
USER builder
WORKDIR /lapee
CMD ["/bin/bash"]
