#!/bin/sh
# Entry point of the dby-w09-kernel-builder image (see docker/Dockerfile).
#
# Checks that the container is wired to a repository and to the baked toolchain,
# prints which toolchain is in use, then runs the command it was given
# (default: make images).
set -eu

TOOLCHAIN=${DBY_TOOLCHAIN:-/opt/dby-toolchain}
WORK=${DBY_WORKDIR:-/work}
export DBY_TOOLCHAIN="$TOOLCHAIN"
export HOME=${HOME:-/tmp}

CLANG=$TOOLCHAIN/root/usr/lib/llvm-11/bin/clang
if [ ! -x "$CLANG" ]; then
  echo "error: no toolchain at $TOOLCHAIN (expected $CLANG)" >&2
  echo "       the image bakes one at /opt/dby-toolchain; DBY_TOOLCHAIN is overridden?" >&2
  exit 1
fi

if [ ! -x "$WORK/scripts/env.sh" ]; then
  echo "error: $WORK does not look like the dby-w09-kernel repository" >&2
  echo "       start the container through docker/run.sh, which mounts the repo at $WORK" >&2
  exit 1
fi

LD_LIBRARY_PATH="$TOOLCHAIN/root/usr/lib/x86_64-linux-gnu:$TOOLCHAIN/root/usr/lib/llvm-11/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

echo "== dby builder"
echo "   clang: $("$CLANG" --version | head -1)"
echo "   work:  $WORK   user: $(id -u):$(id -g)   jobs: ${JOBS:-default}"

# The two things the build needs from the host; warn early, fail late, so
# `make bootstrap` can still create them.
[ -f "$WORK/src/kernel/.dby_prepared" ] ||
  echo "   note:  sources not prepared yet, 'make bootstrap' extracts them here"
[ -f "$WORK/artifacts/boot_stock_device.img" ] ||
  echo "   note:  no boot template, run scripts/dump_boot_template.sh on the host"

exec "$@"
