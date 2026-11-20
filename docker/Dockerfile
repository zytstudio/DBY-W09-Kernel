# syntax=docker/dockerfile:1

# Build environment for the DBY-W09 (Huawei MatePad 11 2021) 4.19.157 kernel.
#
# It contains everything `make bootstrap` + `make images` need, including the
# pinned cross toolchain (Ubuntu clang 11.1.0-6 + binutils 2.38), so the host
# only has to download the Huawei tarball and dump the boot template, and the
# container build itself needs no network access.
#
#   docker build -f docker/Dockerfile -t dby-w09-kernel-builder:latest .
#   docker/run.sh make images      # normally you go through this wrapper
#
# Optional build args:
#   APT_MIRROR       e.g. mirrors.tuna.tsinghua.edu.cn (rewrites sources.list)
#   UBUNTU_ARCHIVE   mirror for the toolchain .debs, default
#                    http://archive.ubuntu.com/ubuntu
FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG APT_MIRROR=archive.ubuntu.com
ARG UBUNTU_ARCHIVE=http://archive.ubuntu.com/ubuntu

LABEL org.opencontainers.image.title="dby-w09-kernel-builder" \
      org.opencontainers.image.description="Build environment for the Huawei MatePad 11 (DBY-W09) kernel: clang 11.1.0-6, binutils 2.38, kbuild and patch tooling" \
      org.opencontainers.image.source="https://github.com/zytstudio/DBY-W09-Kernel" \
      org.opencontainers.image.licenses="GPL-2.0-only"

ENV DBY_TOOLCHAIN=/opt/dby-toolchain \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Ubuntu 22.04 on purpose: jammy is the release the pinned clang 11 debs and the
# gcc 11 host compiler come from. A 24.04+ gcc is too new for this 4.19 tree.
#
# libedit2/libxml2 are runtime dependencies of the unpacked clang and libLLVM
# (libxml2 brings libicu70 along); nothing else in the list pulls them, and
# without them `clang --version` fails with "libedit.so.2: cannot open ...".
RUN set -eux; \
    if [ "$APT_MIRROR" != "archive.ubuntu.com" ]; then \
      sed -i "s|http://archive.ubuntu.com/ubuntu|http://$APT_MIRROR/ubuntu|g" /etc/apt/sources.list; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      bc bison build-essential ca-certificates cpio curl diffutils \
      flex git gzip kmod libedit2 libelf-dev libncurses-dev libssl-dev \
      libxml2 patch python3 rsync xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Pinned toolchain, unpacked at image build time with the same debs the released
# images were built with. fetch_toolchain.sh honours $DBY_TOOLCHAIN, so it lands
# in /opt/dby-toolchain and the host's toolchain/ (if any) stays untouched.
COPY scripts/fetch_toolchain.sh /opt/dby-src/scripts/fetch_toolchain.sh
RUN set -eux; \
    DBY_TOOLCHAIN="$DBY_TOOLCHAIN" UBUNTU_ARCHIVE="$UBUNTU_ARCHIVE" \
      /opt/dby-src/scripts/fetch_toolchain.sh; \
    rm -rf /opt/dby-src "$DBY_TOOLCHAIN"/debs

COPY docker/entrypoint.sh /usr/local/bin/dby-entrypoint
RUN chmod 0755 /usr/local/bin/dby-entrypoint

# The repository is bind-mounted here by docker/run.sh; nothing is baked in.
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/dby-entrypoint"]
CMD ["make", "images"]
