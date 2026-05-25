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
#   `make runtime-image'      — Docker chooses the platform that
#                               matches the host arch (linux/arm64
#                               on Apple Silicon, linux/amd64 on
#                               x86_64 hosts). Fast — no Rosetta
#                               on M-series. Output bytes may differ
#                               across host architectures.
#
#   `make runtime-image REFERENCE=1'
#                             — Docker forces linux/amd64 regardless
#                               of host. On Apple Silicon this means
#                               Rosetta. Output bytes are bit-identical
#                               on every host. Use for publishing / CI /
#                               known-good hashes.
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
        binutils-mingw-w64-x86-64 \
        binutils \
        bison \
        build-essential \
        ca-certificates \
        cmake \
        cpio \
        curl \
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
        libudev-dev \
        m4 \
        mtools \
        ninja-build \
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

# UKI assembly targets x86_64 laptops even when the build container
# itself is native arm64. Debian's native systemd-boot-efi package
# only ships linuxaa64.efi.stub on arm64, so install the amd64 package
# solely for linuxx64.efi.stub / systemd-bootx64.efi.
RUN dpkg --add-architecture amd64 && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        systemd-boot-efi:amd64 && \
    rm -rf /var/lib/apt/lists/*

# Rust toolchain for rebar3_cargo Rust NIFs (hb_keccak and
# friends). Pinned to a specific version + cross target so a
# Rust-stable bump doesn't silently change build outputs.
# x86_64-unknown-linux-gnu target lets cargo cross-compile from
# any host arch to the LapEE x86_64 Linux target.
ARG RUST_VERSION=1.91.0
ARG RUSTUP_VERSION=1.28.2
ARG RUSTUP_SHA256_AMD64=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c
ARG RUSTUP_SHA256_ARM64=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c
ARG TARGETARCH
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
        amd64|x86_64) \
            rustup_target=x86_64-unknown-linux-gnu; \
            rustup_sha="$RUSTUP_SHA256_AMD64"; \
            ;; \
        arm64|aarch64) \
            rustup_target=aarch64-unknown-linux-gnu; \
            rustup_sha="$RUSTUP_SHA256_ARM64"; \
            ;; \
        *) echo "unsupported rustup architecture: $arch" >&2; exit 1 ;; \
    esac; \
    curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init \
        "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustup_target}/rustup-init"; \
    echo "${rustup_sha}  /tmp/rustup-init" | sha256sum -c -; \
    chmod +x /tmp/rustup-init; \
    /tmp/rustup-init -y \
        --default-toolchain ${RUST_VERSION} \
        --profile minimal \
        --target x86_64-unknown-linux-gnu && \
    rm /tmp/rustup-init
ENV PATH="/root/.cargo/bin:${PATH}"

# Buildroot refuses to run as root (host-tar's configure also
# fails with "you should not run configure as root"); set up an
# unprivileged builder user that the build-buildroot.sh wrapper
# switches into. The Rust toolchain installed under /root/.cargo
# above needs to be accessible to `builder' too — add a per-user
# copy.
RUN useradd -m -s /bin/bash builder && \
    mkdir -p /home/builder/.cargo /home/builder/.rustup && \
    cp -a /root/.cargo/bin /home/builder/.cargo/ && \
    cp -a /root/.rustup/. /home/builder/.rustup/ && \
    chown -R builder:builder /home/builder
ENV PATH="/home/builder/.cargo/bin:${PATH}"
USER builder
WORKDIR /lapee
CMD ["/bin/bash"]
