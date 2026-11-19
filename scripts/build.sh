#!/bin/bash
set -e
WS=$(cd "$(dirname "$0")/.." && pwd)
. "$WS/scripts/env.sh"
OUT="$1"; shift
make -C "$WS/src/kernel" O="$OUT" ARCH=arm64 -j${JOBS:-16} \
  CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- \
  LD=aarch64-linux-gnu-ld AR=aarch64-linux-gnu-ar NM=aarch64-linux-gnu-nm \
  OBJCOPY=aarch64-linux-gnu-objcopy OBJDUMP=aarch64-linux-gnu-objdump \
  READELF=aarch64-linux-gnu-readelf STRIP=aarch64-linux-gnu-strip \
  HOSTCC=gcc PYTHON=python3 KCFLAGS="-Wno-error -Wno-strict-prototypes -fno-builtin-wcslen" "$@"
