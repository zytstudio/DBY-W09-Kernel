#!/bin/bash
# Download and unpack the pinned build toolchain into toolchain/root.
#
#   scripts/fetch_toolchain.sh
#
# Packages are the ones the shipped images were built with:
#   Ubuntu clang 11.1.0-6  +  GNU binutils 2.38  (aarch64 cross)
# They are unpacked with dpkg-deb -x, so no root and no apt install needed.
#
# Set UBUNTU_ARCHIVE to use a mirror (default http://archive.ubuntu.com/ubuntu).
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
ARCHIVE=${UBUNTU_ARCHIVE:-http://archive.ubuntu.com/ubuntu}
DEBS=$WS/toolchain/debs
ROOT=$WS/toolchain/root

for c in curl dpkg-deb sha256sum; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "error: required command '$c' not found in PATH" >&2
    exit 1
  }
done

mkdir -p "$DEBS" "$ROOT"

# url path, file name, sha256
PKGS=(
"pool/universe/l/llvm-toolchain-11/clang-11_11.1.0-6_amd64.deb|clang-11_11.1.0-6_amd64.deb|3984af43028a64d5bac1fa7577c6e221a949a7c1695ab94a0c27de9356cbd4b7"
"pool/universe/l/llvm-toolchain-11/libclang-common-11-dev_11.1.0-6_amd64.deb|libclang-common-11-dev_11.1.0-6_amd64.deb|6d7112c58cb5faf520e7381024ed26cb3ae5d0205880647178a543a2e86be85a"
"pool/universe/l/llvm-toolchain-11/libclang-cpp11_11.1.0-6_amd64.deb|libclang-cpp11_11.1.0-6_amd64.deb|0bc7f4a7a8a525fae998222cf39589a4a957006e4537e3d4b828788c31acd93a"
"pool/universe/l/llvm-toolchain-11/libllvm11_11.1.0-6_amd64.deb|libllvm11_11.1.0-6_amd64.deb|706483d52db1d89826719b0f9095de1c375b2d5a02526587618c4452e2b859c4"
"pool/main/b/binutils/binutils-aarch64-linux-gnu_2.38-4ubuntu2.12_amd64.deb|binutils-aarch64-linux-gnu_2.38-4ubuntu2.12_amd64.deb|8b27d0c3811c025f76ee8683eb0c13bc57ec335fdfedc86d256c30c52a8b3982"
)

for entry in "${PKGS[@]}"; do
  IFS='|' read -r path name sha <<<"$entry"
  if [ ! -f "$DEBS/$name" ]; then
    echo "== downloading $name"
    curl -fL --retry 3 -o "$DEBS/$name.part" "$ARCHIVE/$path"
    mv "$DEBS/$name.part" "$DEBS/$name"
  fi
  if ! echo "$sha  $DEBS/$name" | sha256sum -c -; then
    echo "error: $name failed its sha256 check; delete it and re-run:" >&2
    echo "       rm $DEBS/$name" >&2
    exit 1
  fi
  dpkg-deb -x "$DEBS/$name" "$ROOT"
done

echo
echo "toolchain ready in $ROOT"

# The packages keep the clang runtime libraries in usr/lib/x86_64-linux-gnu
# (not next to the binary), so the unpacked clang only starts with
# LD_LIBRARY_PATH pointing there. env.sh exports the same two directories for
# the build itself; do it here too so the sanity check below works on a clean
# host that has no system-wide llvm-11.
export LD_LIBRARY_PATH="$ROOT/usr/lib/x86_64-linux-gnu:$ROOT/usr/lib/llvm-11/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

CLANG=$ROOT/usr/lib/llvm-11/bin/clang
CROSS_LD=$ROOT/usr/bin/aarch64-linux-gnu-ld

clang_ver=$("$CLANG" --version 2>&1 | head -1)
case "$clang_ver" in
  *"clang version 11.1.0-6"*) echo "  clang: $clang_ver" ;;
  *)
    echo "error: unpacked clang does not run or has the wrong version:" >&2
    echo "       $clang_ver" >&2
    echo "       try: rm -rf $ROOT && scripts/fetch_toolchain.sh" >&2
    exit 1
    ;;
esac

ld_ver=$("$CROSS_LD" --version 2>&1 | head -1)
case "$ld_ver" in
  *"2.38"*) echo "  ld:    $ld_ver" ;;
  *)
    echo "error: unexpected aarch64-linux-gnu-ld: $ld_ver" >&2
    echo "       try: rm -rf $ROOT && scripts/fetch_toolchain.sh" >&2
    exit 1
    ;;
esac

echo
echo "next: . scripts/env.sh    # PATH / LD_LIBRARY_PATH / ARCH / CROSS_COMPILE"
