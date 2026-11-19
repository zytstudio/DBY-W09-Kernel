#!/bin/bash
# Fetch and prepare everything needed to build the DBY-W09 kernel:
#
#   1. extract the official Huawei open-source tarball into src/kernel
#   2. clone the pinned KernelSU fork into src/kernel/KernelSU
#   3. wire KernelSU into the kernel build
#   4. apply the compile fixes (scripts/patch_source.py)
#   5. apply the SUSFS 1.5.5 kernel patch + the namespace/header fixups
#   6. apply the KernelSU-side SUSFS patch
#   7. apply the msm_gem_fault fix (container/Anland hang)
#
# Usage:
#   scripts/fetch_sources.sh
#
# Environment:
#   DBY_TARBALL   path to DBY-W09_HarmonyOS4.0.0_opensource.tar.gz
#                 (default: ./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz)
#   DBY_SKIP_SHA  set to 1 to skip the tarball sha256 check
#   KSU_URL       KernelSU git remote (default backslashxx/KernelSU)
#   KSU_COMMIT    pinned KernelSU commit
#
# The tarball itself is not part of this repository (554 MB); download it from
# Huawei's open-source release page and check the sha256 in SOURCE-MANIFEST.md.
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
cd "$WS"

TARBALL=${DBY_TARBALL:-$WS/DBY-W09_HarmonyOS4.0.0_opensource.tar.gz}
SHA256=52c38060cf2990e44bbc556f39271f6e97af90777a300165443946aa97c72e5f
KSU_URL=${KSU_URL:-https://github.com/backslashxx/KernelSU}
KSU_COMMIT=${KSU_COMMIT:-b1365d093208a4ab37a6045f0ab0d89977fad637}

say() { printf '\n== %s\n' "$*"; }

say "1/7 kernel source"
if [ -f "$WS/src/kernel/Makefile" ]; then
  echo "   src/kernel already present, skipping extraction"
else
  [ -f "$TARBALL" ] || {
    echo "error: $TARBALL not found." >&2
    echo "       download DBY-W09_HarmonyOS4.0.0_opensource.tar.gz or set DBY_TARBALL." >&2
    exit 1
  }
  if [ "${DBY_SKIP_SHA:-0}" != "1" ]; then
    echo "   verifying sha256 ..."
    echo "$SHA256  $TARBALL" | sha256sum -c -
  fi
  tmp=$(mktemp -d)
  echo "   extracting (about 1.5 GB) ..."
  tar xzf "$TARBALL" -C "$tmp" Code_Opensource/kernel
  mkdir -p "$WS/src"
  rm -rf "$WS/src/kernel"
  mv "$tmp/Code_Opensource/kernel" "$WS/src/kernel"
  rm -rf "$tmp"
fi

say "2/7 KernelSU (pinned $KSU_COMMIT)"
if [ ! -d "$WS/src/kernel/KernelSU/.git" ]; then
  rm -rf "$WS/src/kernel/KernelSU"
  git clone "$KSU_URL" "$WS/src/kernel/KernelSU"
fi
git -C "$WS/src/kernel/KernelSU" fetch --all --tags --quiet || true
git -C "$WS/src/kernel/KernelSU" checkout -f "$KSU_COMMIT"
git -C "$WS/src/kernel/KernelSU" log --oneline -1

say "3/7 wire KernelSU into the kernel build"
"$WS/scripts/wire_kernelsu.sh" "$WS/src/kernel"

say "4/7 vendor source compile fixes"
python3 "$WS/scripts/patch_source.py" "$WS/src/kernel"

say "5/7 SUSFS 1.5.5 kernel patch"
apply() {
  local p=$1
  echo "   $p"
  patch -p1 -N -r - -d "$WS/src/kernel" < "$WS/$p" >/dev/null || true
}
apply patches/susfs-kernel.diff
apply patches/susfs-kernel-fixes.diff
if find "$WS/src/kernel" -name '*.rej' -print -quit | grep -q .; then
  echo "error: rejected hunks, see the .rej files under src/kernel" >&2
  find "$WS/src/kernel" -name '*.rej' | head
  exit 1
fi

say "6/7 KernelSU-side SUSFS patch"
python3 "$WS/scripts/apply_ksu_susfs.py" "$WS/src/kernel/KernelSU"

say "7/7 msm_gem_fault fix"
python3 "$WS/scripts/patch_msm_fault.py" --srcdir "$WS/src/kernel"

say "done"
cat <<EOF
Next:
  scripts/fetch_toolchain.sh          # clang 11 / binutils 2.38 into toolchain/
  scripts/dump_boot_template.sh       # artifacts/boot_stock_device.img from device
  make images                         # 5 variants x enforcing/permissive
EOF
