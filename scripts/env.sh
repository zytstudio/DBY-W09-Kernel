#!/bin/sh
# Source me before building:  . scripts/env.sh
#
# Resolve this file's own directory: when the file is sourced, $0 is the calling
# shell, so use BASH_SOURCE when available and only fall back to $0 otherwise.
DBY_SRC=${BASH_SOURCE:-$0}
WS=$(cd "$(dirname "$DBY_SRC")/.." 2>/dev/null && pwd)
if [ ! -f "$WS/scripts/env.sh" ] && [ -f "$PWD/scripts/env.sh" ]; then
  WS=$PWD          # sourced by a shell that does not report its own path
fi
if [ ! -f "$WS/scripts/env.sh" ]; then
  echo "env.sh: cannot locate the repository root (source me from the repo)" >&2
  return 1 2>/dev/null || exit 1
fi

export PATH=$WS/toolchain/root/usr/lib/llvm-11/bin:$WS/toolchain/root/usr/bin:$PATH
export LD_LIBRARY_PATH=$WS/toolchain/root/usr/lib/x86_64-linux-gnu:$WS/toolchain/root/usr/lib/llvm-11/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
export HOSTCC=gcc
export PYTHON=python3
kmake() {
  km_out=$1; shift
  make -C "$WS/src/kernel" O="$km_out" ARCH=arm64 -j${JOBS:-16} \
    CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
    LD=aarch64-linux-gnu-ld AR=aarch64-linux-gnu-ar NM=aarch64-linux-gnu-nm \
    OBJCOPY=aarch64-linux-gnu-objcopy OBJDUMP=aarch64-linux-gnu-objdump \
    READELF=aarch64-linux-gnu-readelf STRIP=aarch64-linux-gnu-strip HOSTCC=gcc PYTHON=python3 "$@"
}
