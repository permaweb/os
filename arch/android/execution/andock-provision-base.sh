#!/usr/bin/env bash
set -euo pipefail

: "${ANDEE_UBUNTU_SNAPSHOT:?missing Ubuntu snapshot}"
: "${ANDEE_NODE_ARCHIVE:?missing Node.js archive}"
: "${ANDEE_PERMAGIT_ARCHIVE:?missing permagit archive}"
: "${ANDEE_PERMAGIT_PACKAGE_LOCK_SHA256:?missing permagit package lock digest}"
: "${ANDEE_PACKAGE_LOCK:?missing package lock}"

export DEBIAN_FRONTEND=noninteractive
export PIP_BREAK_SYSTEM_PACKAGES=1

snapshot="https://snapshot.ubuntu.com/ubuntu/$ANDEE_UBUNTU_SNAPSHOT"
cat >/etc/apt/sources.list.d/ubuntu.sources <<EOF
Types: deb
URIs: $snapshot
Suites: noble noble-updates noble-backports noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

# The minimal Ubuntu OCI image has no CA bundle. Bootstrap it from signed
# snapshot metadata, then immediately require normal TLS verification.
apt-get -o Acquire::https::Verify-Peer=false update
apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
    ca-certificates
apt-get update

mapfile -t packages < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' \
    "$ANDEE_PACKAGE_LOCK")
apt-get install -y --no-install-recommends "${packages[@]}"

tar -xJf "$ANDEE_NODE_ARCHIVE" -C /usr/local --strip-components=1
ln -sfn "$(command -v fdfind)" /usr/local/bin/fd
ln -sfn "$(command -v python3)" /usr/local/bin/python
ln -sfn "$(command -v pip3)" /usr/local/bin/pip

permagit_source="$(mktemp -d)"
tar -xzf "$ANDEE_PERMAGIT_ARCHIVE" -C "$permagit_source"
find "$permagit_source" -name '._*' -delete
printf '%s  %s\n' "$ANDEE_PERMAGIT_PACKAGE_LOCK_SHA256" \
    "$permagit_source/permagit/package-lock.json" | sha256sum -c -
mkdir -p /root/.permagit/app
cp -a "$permagit_source/permagit/src" "$permagit_source/permagit/bin" \
    /root/.permagit/app/
cp "$permagit_source/permagit/package.json" \
    "$permagit_source/permagit/package-lock.json" /root/.permagit/app/
(
    cd /root/.permagit/app
    npm ci --omit=dev --no-audit --no-fund
)
chmod 0755 \
    /root/.permagit/app/bin/git-remote-arweave.js \
    /root/.permagit/app/bin/permagit.js
ln -sfn /root/.permagit/app/bin/git-remote-arweave.js \
    /usr/local/bin/git-remote-arweave
ln -sfn /root/.permagit/app/bin/permagit.js /usr/local/bin/permagit

rm -rf "$permagit_source" /root/.npm /root/.cache
find /root/.permagit/app/node_modules \
    \( -name '*.a' -o -name '*.o' -o -name '*.d' \) -type f -delete
find /root/.permagit/app/node_modules \
    \( -name .deps -o -name obj.target \) -type d -prune -exec rm -rf {} +

cat >/etc/profile.d/andock.sh <<'EOF'
export PIP_BREAK_SYSTEM_PACKAGES=1
EOF
chmod 0644 /etc/profile.d/andock.sh

# Android isolated processes cannot change their saved UID. APT remains inside
# the isolated UID/SELinux boundary, so run its fetch helpers as guest root.
cat >/etc/apt/apt.conf.d/99andock <<'EOF'
APT::Sandbox::User "root";
EOF

# Runtime package installs use normal Ubuntu repositories. Only the immutable
# image build is pinned to the snapshot above.
cat >/etc/apt/sources.list.d/ubuntu.sources <<'EOF'
Types: deb
URIs: https://ports.ubuntu.com/ubuntu-ports/
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://ports.ubuntu.com/ubuntu-ports/
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

printf '127.0.0.1 localhost\n::1 localhost\n' >/etc/hosts
: >/etc/hostname
: >/etc/resolv.conf
: >/etc/machine-id
mkdir -p /root /tmp /var/tmp
chmod 0700 /root
chmod 1777 /tmp /var/tmp

dpkg-query -W > /tmp/andock-packages.txt
LC_ALL=C sort -o /tmp/andock-packages.txt /tmp/andock-packages.txt
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /tmp/node-compile-cache /var/log/apt/*
rm -f \
    /run/systemd/container \
    /var/cache/ldconfig/aux-cache \
    /var/log/alternatives.log \
    /var/log/dpkg.log \
    /.dockerenv
