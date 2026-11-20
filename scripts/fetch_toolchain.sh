#!/bin/bash
# Download and unpack the pinned build toolchain into toolchain/root.
#
#   scripts/fetch_toolchain.sh [--force]
#
#   --force   unpack the packages again even if the toolchain is already complete
#
# Packages are the ones the shipped images were built with:
#   Ubuntu clang 11.1.0-6  +  GNU binutils 2.38  (aarch64 cross)
# They are unpacked with dpkg-deb -x, so no root and no apt install needed.
#
# Environment:
#   DBY_TOOLCHAIN    install prefix (default: <repo>/toolchain). The docker image
#                    sets it to /opt/dby-toolchain, so `make bootstrap` inside a
#                    container neither touches the host tree nor downloads again.
#   UBUNTU_ARCHIVE   use a mirror (default http://archive.ubuntu.com/ubuntu)
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
ARCHIVE=${UBUNTU_ARCHIVE:-http://archive.ubuntu.com/ubuntu}
TC=${DBY_TOOLCHAIN:-$WS/toolchain}
DEBS=$TC/debs
ROOT=$TC/root

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) awk 'NR>1 && /^set -euo/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

CLANG=$ROOT/usr/lib/llvm-11/bin/clang
CROSS_LD=$ROOT/usr/bin/aarch64-linux-gnu-ld
TOOLCHAIN_PROBLEM=""
CLANG_VER=""
LD_VER=""

# The packages keep the clang runtime libraries in usr/lib/x86_64-linux-gnu
# (not next to the binary), so the unpacked clang only starts with
# LD_LIBRARY_PATH pointing there. env.sh exports the same two directories for
# the build itself; do it here too so the checks below work on a clean host that
# has no system-wide llvm-11.
export LD_LIBRARY_PATH="$ROOT/usr/lib/x86_64-linux-gnu:$ROOT/usr/lib/llvm-11/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# 0 when both the compiler and the cross linker are the pinned versions.
check_toolchain() {
  [ -x "$CLANG" ] && [ -x "$CROSS_LD" ] || return 1
  CLANG_VER=$("$CLANG" --version 2>&1 | head -1)
  case "$CLANG_VER" in
    *"clang version 11.1.0-6"*) ;;
    *) TOOLCHAIN_PROBLEM="clang: ${CLANG_VER:-does not run}" ; return 1 ;;
  esac
  LD_VER=$("$CROSS_LD" --version 2>&1 | head -1)
  case "$LD_VER" in
    *"2.38"*) ;;
    *) TOOLCHAIN_PROBLEM="ld: ${LD_VER:-does not run}" ; return 1 ;;
  esac
  return 0
}

# Already there? Re-running the script is then a no-op (--force re-unpacks).
if [ "$FORCE" = "0" ] && check_toolchain; then
  echo "toolchain already unpacked in $ROOT"
  echo "  clang: $CLANG_VER"
  echo "  ld:    $LD_VER"
  echo "next: . scripts/env.sh    # PATH / LD_LIBRARY_PATH / ARCH / CROSS_COMPILE"
  exit 0
fi

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

if ! check_toolchain; then
  echo "error: the unpacked toolchain does not work: $TOOLCHAIN_PROBLEM" >&2
  echo "       try: rm -rf $ROOT && scripts/fetch_toolchain.sh" >&2
  exit 1
fi
echo "  clang: $CLANG_VER"
echo "  ld:    $LD_VER"

echo
echo "next: . scripts/env.sh    # PATH / LD_LIBRARY_PATH / ARCH / CROSS_COMPILE"
