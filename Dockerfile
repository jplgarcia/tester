# syntax=docker.io/docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=FromPlatformFlagConstDisallowed

# Reproducible root filesystem: the base image is pinned by digest and every
# package comes from the Ubuntu snapshot service at APT_UPDATE_SNAPSHOT (the
# live mirror is never queried), so the same packages are installed no matter
# when the image is built. Build with scripts/build-snapshot.sh, which also
# fixes all file timestamps (SOURCE_DATE_EPOCH).
ARG UBUNTU_IMAGE=ubuntu:noble-20250910@sha256:353675e2a41babd526e2b837d7ec780c2a05bca0164f7ea5dbbd433d21d166fc
ARG APT_UPDATE_SNAPSHOT=20250915T030400Z
ARG MACHINE_GUEST_TOOLS_VERSION=0.18.0
ARG MACHINE_GUEST_TOOLS_SHA256SUM=204d4260defd68e11b957ae1f1b511b6c2c74345c918748be06f592733b72dcd

################################################################################
# riscv64 base stage
FROM --platform=linux/riscv64 ${UBUNTU_IMAGE} AS base

ARG APT_UPDATE_SNAPSHOT
ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
set -eu
# Only the snapshot (riscv64 is served under /ubuntu on snapshot.ubuntu.com).
# The previous recipe ran a plain `apt-get update` + `install ca-certificates`
# against the live mirror first, and `apt-get update --snapshot` did not change
# where later installs came from, so the rootfs followed the mirror.
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<EOT
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${APT_UPDATE_SNAPSHOT}
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOT
# No CA store in the base image. Integrity does not depend on TLS: apt checks
# the archive signature on InRelease and the signed hashes of every file.
echo 'Acquire::https::Verify-Peer "false";' > /etc/apt/apt.conf.d/99snapshot-bootstrap
apt-get update -o APT::Update::Error-Mode=any
EOF

################################################################################
# riscv64 builder stage
FROM base AS builder

ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
set -e
apt-get install -y --no-install-recommends \
  build-essential \
  ca-certificates \
  curl
rm -rf /var/lib/apt/lists/*
EOF

# libcmt (static library + headers) from the same pinned machine-guest-tools .deb
ARG MACHINE_GUEST_TOOLS_VERSION
ARG MACHINE_GUEST_TOOLS_SHA256SUM
ADD --checksum=sha256:${MACHINE_GUEST_TOOLS_SHA256SUM} \
  https://github.com/cartesi/machine-guest-tools/releases/download/v${MACHINE_GUEST_TOOLS_VERSION}/machine-guest-tools_riscv64.deb \
  /tmp/machine-guest-tools_riscv64.deb
RUN dpkg -x /tmp/machine-guest-tools_riscv64.deb /opt/libcmt

WORKDIR /opt/cartesi/dapp
COPY . .
RUN make LIBCMT_PREFIX=/opt/libcmt/usr

################################################################################
# runtime stage: produces final image that will be executed
FROM base

ARG MACHINE_GUEST_TOOLS_VERSION
ARG MACHINE_GUEST_TOOLS_SHA256SUM
ADD --checksum=sha256:${MACHINE_GUEST_TOOLS_SHA256SUM} \
  https://github.com/cartesi/machine-guest-tools/releases/download/v${MACHINE_GUEST_TOOLS_VERSION}/machine-guest-tools_riscv64.deb \
  /tmp/machine-guest-tools_riscv64.deb

ARG DEBIAN_FRONTEND=noninteractive
RUN <<EOF
set -e
apt-get install -y --no-install-recommends \
  busybox-static \
  /tmp/machine-guest-tools_riscv64.deb

rm /tmp/machine-guest-tools_riscv64.deb
rm -rf /var/lib/apt/lists/* /var/log/* /var/cache/* /etc/apt/apt.conf.d/99snapshot-bootstrap
EOF

ENV PATH="/opt/cartesi/bin:${PATH}"

WORKDIR /opt/cartesi/dapp
COPY --from=builder /opt/cartesi/dapp/dapp .

# The dapp uses libcmt directly (no rollup-http-server / rollup-init).
ENTRYPOINT ["/opt/cartesi/dapp/dapp"]
