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
  echo "$sha  $DEBS/$name" | sha256sum -c -
  dpkg-deb -x "$DEBS/$name" "$ROOT"
done

echo
echo "toolchain ready in $ROOT"
"$ROOT/usr/lib/llvm-11/bin/clang" --version | head -1
"$ROOT/usr/bin/aarch64-linux-gnu-ld" --version | head -1
