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
#   KSU_DIR       local KernelSU tree to copy instead of cloning
#   KSU_TARBALL   offline KernelSU archive (repo tarball/zip) to use instead of
#                 cloning; a single top-level directory is stripped if present
#
# The tarball itself is not part of this repository (554 MB); download it from
# Huawei's open-source release page and check the sha256 in SOURCE-MANIFEST.md.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
cd "$WS"

TARBALL=${DBY_TARBALL:-$WS/DBY-W09_HarmonyOS4.0.0_opensource.tar.gz}
SHA256=52c38060cf2990e44bbc556f39271f6e97af90777a300165443946aa97c72e5f
KSU_URL=${KSU_URL:-https://github.com/backslashxx/KernelSU}
KSU_COMMIT=${KSU_COMMIT:-b1365d093208a4ab37a6045f0ab0d89977fad637}

say() { printf '\n== %s\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' not found in PATH" >&2
    exit 1
  }
}
for c in git python3 patch tar sha256sum; do need "$c"; done

say "1/7 kernel source"
if [ -f "$WS/src/kernel/Makefile" ] && [ -f "$WS/src/kernel/init/main.c" ]; then
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
  tar xzf "$TARBALL" -C "$tmp" Code_Opensource/kernel || {
    echo "error: cannot extract Code_Opensource/kernel from $TARBALL." >&2
    echo "       Is it the DBY-W09 HarmonyOS 4.0.0 kernel source archive?" >&2
    rm -rf "$tmp"
    exit 1
  }
  mkdir -p "$WS/src"
  rm -rf "$WS/src/kernel"
  mv "$tmp/Code_Opensource/kernel" "$WS/src/kernel"
  rm -rf "$tmp"
fi

say "2/7 KernelSU (pinned $KSU_COMMIT)"
KSU=$WS/src/kernel/KernelSU
if [ -n "${KSU_DIR:-}" ]; then
  echo "   copying KernelSU from $KSU_DIR"
  [ -d "$KSU_DIR/kernel" ] || { echo "error: $KSU_DIR is not a KernelSU tree" >&2; exit 1; }
  rm -rf "$KSU"
  mkdir -p "$KSU"
  cp -a "$KSU_DIR"/. "$KSU"/
elif [ -n "${KSU_TARBALL:-}" ]; then
  echo "   using offline archive $KSU_TARBALL"
  rm -rf "$KSU"
  mkdir -p "$KSU"
  tmpk=$(mktemp -d)
  tar xf "$KSU_TARBALL" -C "$tmpk" || {
    echo "error: cannot extract $KSU_TARBALL" >&2
    rm -rf "$tmpk"
    exit 1
  }
  # GitHub archives have one top-level directory, `git archive` does not.
  entries=$(ls -A "$tmpk" | wc -l)
  src=$tmpk
  if [ "$entries" -eq 1 ] && [ -d "$tmpk/$(ls -A "$tmpk")" ]; then
    src=$tmpk/$(ls -A "$tmpk")
  fi
  cp -a "$src"/. "$KSU"/
  rm -rf "$tmpk"
elif [ ! -d "$KSU/.git" ]; then
  rm -rf "$KSU"
  echo "   cloning $KSU_URL"
  git clone "$KSU_URL" "$KSU" || {
    echo "error: could not clone $KSU_URL" >&2
    echo "       behind a firewall/proxy? Either" >&2
    echo "         KSU_URL=<mirror> scripts/fetch_sources.sh" >&2
    echo "       or download the repo archive and run" >&2
    echo "         KSU_TARBALL=/path/to/KernelSU-<commit>.tar.gz scripts/fetch_sources.sh" >&2
    rm -rf "$KSU"
    exit 1
  }
fi
if [ -d "$KSU/.git" ]; then
  git -C "$KSU" fetch --all --tags --quiet || true
  git -C "$KSU" checkout -f "$KSU_COMMIT" || {
    echo "error: cannot check out $KSU_COMMIT in $KSU" >&2
    exit 1
  }
fi
if [ -d "$KSU/.git" ]; then
  git -C "$KSU" log --oneline -1
else
  echo "   (offline archive, no git metadata)"
fi

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
