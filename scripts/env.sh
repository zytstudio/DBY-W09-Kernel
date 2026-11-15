#!/bin/sh
WS=/home/zyt/dby-w09-kernel
export PATH=$WS/toolchain/root/usr/lib/llvm-11/bin:$WS/toolchain/root/usr/bin:$PATH
export LD_LIBRARY_PATH=$WS/toolchain/root/usr/lib/x86_64-linux-gnu:$WS/toolchain/root/usr/lib/llvm-11/lib
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
export HOSTCC=gcc
export PYTHON=python3
kmake() { make -C "$WS/src/kernel" O="$1" ARCH=arm64 -j16 \
  CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  LD=aarch64-linux-gnu-ld AR=aarch64-linux-gnu-ar NM=aarch64-linux-gnu-nm \
  OBJCOPY=aarch64-linux-gnu-objcopy OBJDUMP=aarch64-linux-gnu-objdump \
  READELF=aarch64-linux-gnu-readelf STRIP=aarch64-linux-gnu-strip HOSTCC=gcc PYTHON=python3 "${@:2}"; }
