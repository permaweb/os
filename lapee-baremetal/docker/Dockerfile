# Single LapEE build image. Carries:
#
#   * Buildroot host dependencies (the toolchain and userspace are all
#     compiled from source by Buildroot itself; this image only
#     provides the host-side tools the Buildroot orchestration layer
#     needs).
#   * Image-assembly tools (parted, mtools, dosfstools, sbsigntool,
#     efitools) used by build-usb-image.sh / boot-usb-image.sh /
#     sb-setup.sh — historically a separate `lapee-tools' image,
#     folded in here so a fresh clone is one image to build.
#
# The image is built two ways:
#
#   `make build'              — Docker chooses the platform that
#                               matches the host arch (linux/arm64
#                               on Apple Silicon, linux/amd64 on
#                               x86_64 hosts). Fast — no Rosetta
#                               on M-series. Output bytes may differ
#                               across host architectures.
#
#   `make build REFERENCE=1'  — Docker forces linux/amd64 regardless
#                               of host. On Apple Silicon this means
#                               Rosetta. Output bytes are bit-
#                               identical on every host. Use for
#                               publishing / CI / known-good hashes.
#
# The Dockerfile itself is identical for both — only the host arch
# of the resulting image differs.
#
# Pinned to a specific debian:12-slim digest so an upstream point-
# release that bumps glibc / coreutils can't silently change build
# behaviour. Bumping = update this one line.
FROM debian:12-slim@sha256:f9c6a2fd2ddbc23e336b6257a5245e31f996953ef06cd13a59fa0a1df2d5c252

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
        bc \
        binutils \
        bison \
        build-essential \
        ca-certificates \
        cpio \
        dosfstools \
        efitools \
        file \
        flex \
        g++ \
        gawk \
        git \
        gzip \
        libelf-dev \
        libncurses-dev \
        libssl-dev \
        mtools \
        openssl \
        parted \
        perl \
        pkg-config \
        python3 \
        rsync \
        sbsigntool \
        sed \
        unzip \
        uuid-runtime \
        wget \
        xz-utils \
        zlib1g-dev \
        zstd \
    && rm -rf /var/lib/apt/lists/*

# Buildroot refuses to run as root; set up an unprivileged builder
# user that the build-buildroot.sh wrapper switches into.
RUN useradd -m -s /bin/bash builder
WORKDIR /lapee
CMD ["/bin/bash"]
