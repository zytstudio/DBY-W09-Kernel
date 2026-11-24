#!/bin/bash
# Fetch and prepare everything needed to build the DBY-W09 kernel.
#
#   1. extract the official Huawei open-source tarball into src/kernel
#   2. clone the pinned KernelSU-Next checkout into src/kernel/KernelSU-Next
#   3. wire KernelSU into the kernel build
#   4. apply the compile fixes (scripts/patch_source.py)
#   5. apply the SUSFS 1.5.5 kernel patch + the namespace/header fixups
#   6. apply the KernelSU-Next side SUSFS/port patch
#   7. apply the msm_gem_fault fix (container/Anland hang)
#
# Usage:
#   scripts/fetch_sources.sh [--force]
#
#   --force   throw away src/kernel and extract/prepare it from scratch
#
# Re-running on an already prepared tree is a no-op: a marker plus content
# checks guard against applying the patches twice. If the tree looks partially
# patched, the script refuses to continue and asks for --force.
#
# Environment:
#   DBY_TARBALL   path to DBY-W09_HarmonyOS4.0.0_opensource.tar.gz
#                 (default: ./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz)
#   DBY_SKIP_SHA  set to 1 to skip the tarball sha256 check
#   KSU_URL       KernelSU git remote (default KernelSU-Next/KernelSU-Next)
#   KSU_BRANCH    branch to clone (default legacy, the non-GKI branch)
#   KSU_COMMIT    pinned KernelSU commit
#   KSU_DIR       local KernelSU tree to copy instead of cloning
#   KSU_TARBALL   offline KernelSU archive instead of cloning (a single
#                 top-level directory is stripped if present)
#
# The tarball itself is not part of this repository (554 MB); download it from
# Huawei's open-source release page and check the sha256 in SOURCE-MANIFEST.md.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
cd "$WS"
mkdir -p "$WS/.cache"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) awk 'NR>1 && /^if \[ -z/{exit} NR>1{print}' "$0"; exit 0 ;;
    *) echo "error: unknown argument '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

TARBALL=${DBY_TARBALL:-$WS/DBY-W09_HarmonyOS4.0.0_opensource.tar.gz}
SHA256=52c38060cf2990e44bbc556f39271f6e97af90777a300165443946aa97c72e5f
KSU_URL=${KSU_URL:-https://github.com/KernelSU-Next/KernelSU-Next}
KSU_BRANCH=${KSU_BRANCH:-legacy}
KSU_COMMIT=${KSU_COMMIT:-465490a26667ba4cf00b3be975a7e28e53978829}
KERNEL=$WS/src/kernel
KSU=$KERNEL/KernelSU-Next
MARKER=$KERNEL/.dby_prepared

say() { printf '\n== %s\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command '$1' not found in PATH" >&2
    exit 1
  }
}
for c in git python3 patch tar sha256sum; do need "$c"; done

# Content checks that prove the kernel side is fully and exactly once patched.
verify_prepared() {
  local d=$KERNEL n
  [ -f "$d/fs/susfs.c" ] || return 1
  [ -f "$d/fs/susfs_prctl.c" ] || return 1
  [ -f "$d/include/linux/susfs.h" ] || return 1
  [ -f "$d/fs/namespace.c" ] || return 1
  grep -q 'KSU_SUSFS' "$d/fs/Makefile" 2>/dev/null || return 1
  n=$(grep -c 'DEFINE_IDA(susfs_mnt_id_ida)' "$d/fs/namespace.c" 2>/dev/null || true)
  [ "$n" = "1" ] || return 1
  if find "$d" -name '*.rej' -print -quit | grep -q .; then return 1; fi
  return 0
}

apply() {  # apply PATCH [DIR]   (DIR defaults to the kernel tree)
  local p=$1 d=${2:-$KERNEL} log=$WS/.cache/patch-dryrun.log
  if patch -p1 -R --dry-run -s -d "$d" < "$WS/$p" >/dev/null 2>&1; then
    echo "   $p (already applied)"
    return 0
  fi
  echo "   $p"
  # Dry run first so a partially applicable patch aborts with a readable
  # report instead of leaving .rej files scattered over the tree.
  if ! patch -p1 -N --dry-run -d "$d" < "$WS/$p" > "$log" 2>&1; then
    echo "error: $p does not apply cleanly to src/kernel:" >&2
    grep -E 'Hunk #[0-9]+ (FAILED|succeeded)|^patching file' "$log" >&2 || true
    echo "       The tree is not pristine. Re-run with --force to rebuild it." >&2
    exit 1
  fi
  patch -p1 -N -s -d "$d" < "$WS/$p"
}

say "1/7 kernel source"
[ "$FORCE" = "1" ] && rm -rf "$KERNEL"
if [ -f "$KERNEL/Makefile" ] && [ -f "$KERNEL/init/main.c" ]; then
  if [ -f "$MARKER" ] && verify_prepared; then
    echo "   src/kernel already prepared, leaving it alone"
  elif [ -f "$KERNEL/fs/susfs.c" ] || [ -f "$KERNEL/include/linux/susfs.h" ]; then
    echo "error: src/kernel looks partially patched but has no valid marker." >&2
    echo "       Re-run with --force to extract and prepare it from scratch." >&2
    exit 1
  else
    echo "   src/kernel present but not patched yet, continuing"
  fi
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
  mkdir -p "$WS/.cache"
  tmp=$WS/.cache/extract.$$
  rm -rf "$tmp"
  mkdir -p "$tmp"
  echo "   extracting (about 1.5 GB) ..."
  tar xzf "$TARBALL" -C "$tmp" Code_Opensource/kernel || {
    echo "error: cannot extract Code_Opensource/kernel from $TARBALL." >&2
    echo "       Is it the DBY-W09 HarmonyOS 4.0.0 kernel source archive?" >&2
    rm -rf "$tmp"
    exit 1
  }
  mkdir -p "$WS/src"
  rm -rf "$KERNEL"
  mv "$tmp/Code_Opensource/kernel" "$KERNEL"
  rm -rf "$tmp"
  rm -f "$MARKER"
fi

say "2/7 KernelSU (pinned $KSU_COMMIT)"
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
  entries=$(ls -A "$tmpk" | wc -l)
  src=$tmpk
  if [ "$entries" -eq 1 ] && [ -d "$tmpk/$(ls -A "$tmpk")" ]; then
    src=$tmpk/$(ls -A "$tmpk")
  fi
  cp -a "$src"/. "$KSU"/
  rm -rf "$tmpk"
elif [ ! -d "$KSU/.git" ]; then
  rm -rf "$KSU"
  echo "   cloning $KSU_URL ($KSU_BRANCH)"
  git clone --branch "$KSU_BRANCH" "$KSU_URL" "$KSU" || {
    echo "error: could not clone $KSU_URL" >&2
    echo "       behind a firewall/proxy? Either" >&2
    echo "         KSU_URL=<mirror> scripts/fetch_sources.sh" >&2
    echo "       or use a local copy / archive:" >&2
    echo "         KSU_DIR=/path/to/KernelSU scripts/fetch_sources.sh" >&2
    echo "         KSU_TARBALL=/path/to/KernelSU-<commit>.tar.gz scripts/fetch_sources.sh" >&2
    rm -rf "$KSU"
    exit 1
  }
fi
if [ -d "$KSU/.git" ]; then
  git -C "$KSU" fetch --all --tags --quiet || true  # KSU_BRANCH is not needed here
  git -C "$KSU" checkout -f "$KSU_COMMIT" || {
    echo "error: cannot check out $KSU_COMMIT in $KSU" >&2
    exit 1
  }
  git -C "$KSU" log --oneline -1
else
  echo "   (offline archive, no git metadata)"
fi

say "3/7 wire KernelSU into the kernel build"
"$WS/scripts/wire_kernelsu.sh" "$KERNEL"

say "4/7 vendor source compile fixes"
python3 "$WS/scripts/patch_source.py" "$KERNEL"

say "5/7 SUSFS 1.5.5 kernel patch"
if [ -f "$MARKER" ] && verify_prepared; then
  echo "   already prepared, skipping"
else
  find "$KERNEL" \( -name '*.rej' -o -name '*.orig' \) -delete
  apply patches/susfs-kernel.diff
  apply patches/susfs-kernel-fixes.diff
  if ! verify_prepared; then
    echo "error: the kernel tree is not in the expected patched state." >&2
    echo "       Remove src/kernel and run again with --force." >&2
    find "$KERNEL" -name '*.rej' | head
    exit 1
  fi
  touch "$MARKER"
fi

say "6/7 KernelSU-Next port: SUSFS prctl glue, Kconfig, one 4.19 compat fix"
apply patches/ksu-next-port.diff "$KSU"

say "7/7 msm_gem_fault fix"
python3 "$WS/scripts/patch_msm_fault.py" --srcdir "$KERNEL"

say "done"
cat <<EOF
Next:
  scripts/fetch_toolchain.sh          # clang 11 / binutils 2.38 into toolchain/
  scripts/dump_boot_template.sh       # artifacts/boot_stock_device.img from device
  make images                         # 5 variants x enforcing/permissive
EOF
