#!/bin/bash
# Configure a build directory (.config) for one of the supported variants.
#
#   configure.sh OUTDIR VARIANT
#
# VARIANT (kernel feature set; the enforcing/permissive split is done later by
# scripts/patch_permissive.py and does not touch .config):
#   noroot                stock feature set: no KernelSU, no SUSFS, no extra
#                         container options                        (image 1)
#   ksu                   KernelSU only                            (image 2)
#   ksu-susfs             KernelSU + full SUSFS feature set        (image 3)
#   ksu-droidspaces       KernelSU + Docker/DroidSpaces options    (image 4)
#   ksu-droidspaces-susfs same as 4 plus SUSFS, SUS_MOUNT off      (image 5)
#
# Legacy names (base/containers/susfs) are still accepted.
#
# Every variant starts from configs/running.config (the device's own
# /proc/config.gz) and disables RELOCATABLE + RANDOMIZE_BASE: the Huawei RTIC
# section cannot be relocated, the kernel must run at its link address.
set -e
WS=$(cd "$(dirname "$0")/.." && pwd)
OUT="${1:?usage: configure.sh OUTDIR VARIANT}"
VARIANT="${2:-ksu}"
. "$WS/scripts/env.sh"

case "$VARIANT" in
  base) VARIANT=noroot ;;
  containers) VARIANT=ksu-droidspaces ;;
  susfs) VARIANT=ksu-droidspaces-susfs ;;
esac

case "$VARIANT" in
  noroot|ksu|ksu-susfs|ksu-droidspaces|ksu-droidspaces-susfs) ;;
  *) echo "unknown variant: $VARIANT" >&2; exit 1 ;;
esac

mkdir -p "$OUT"
cp "$WS/configs/running.config" "$OUT/.config"
cd "$WS/src/kernel"
make O="$OUT" ARCH=arm64 CC=clang HOSTCC=gcc olddefconfig

# --- common -----------------------------------------------------------------
./scripts/config --file "$OUT/.config" -d RELOCATABLE -d RANDOMIZE_BASE

# --- KernelSU-Next ----------------------------------------------------------
# KSU_KPROBES_HOOK is the least invasive hook mode on this 4.19 vendor tree: it
# needs KPROBES/KRETPROBES and HAVE_SYSCALL_TRACEPOINTS (both available) and does
# not require manual ksu_handle_* call sites in the kernel sources.  The
# alternative modes are KSU_MANUAL_HOOK (needs those call sites) and
# KSU_SYSCALL_TABLE_HOOK (patches the syscall table at runtime).
if [ "$VARIANT" != "noroot" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e KPROBES -e KRETPROBES -e KPROBE_EVENTS -d KPROBES_SANITY_TEST \
    -e KSU -e KSU_KPROBES_HOOK -d KSU_MANUAL_HOOK -d KSU_SYSCALL_TABLE_HOOK \
    -d KSU_DEBUG -d KSU_DISABLE_MANAGER -d KSU_DISABLE_POLICY \
    -d KSU_ALLOWLIST_WORKAROUND
else
  ./scripts/config --file "$OUT/.config" -d KSU -d KSU_SUSFS \
    -d KPROBES -d KRETPROBES -d KPROBE_EVENTS
fi

# --- Docker / DroidSpaces requirements --------------------------------------
if [ "$VARIANT" = "ksu-droidspaces" ] || [ "$VARIANT" = "ksu-droidspaces-susfs" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e SYSVIPC -e DEVTMPFS -d DEVTMPFS_MOUNT \
    -e CGROUP_DEVICE -e CGROUP_PIDS -e CFS_BANDWIDTH -e CGROUP_NET_PRIO \
    -e NETFILTER_XT_MATCH_ADDRTYPE -e BRIDGE_NETFILTER -e MACVLAN \
    -e IP6_NF_NAT -e IP6_NF_TARGET_MASQUERADE -e BINFMT_MISC \
    -e NETFILTER_XT_TARGET_TCPMSS -e NF_CONNTRACK_NETLINK -e NF_NAT_REDIRECT \
    -e IP_ADVANCED_ROUTER -e IP_MULTIPLE_TABLES \
    -d ANDROID_PARANOID_NETWORK
fi

# --- SUSFS ------------------------------------------------------------------
# (3) ksu-susfs: full mount-hiding feature set. HAS_MAGIC_MOUNT (5ec1cff magic
#     mount) and SUS_OVERLAYFS (legacy KSU, "no auto hide") stay off by design:
#     KernelSU-Next is built in-tree and we enable the auto-add/auto-hide paths
#     instead. TRY_UMOUNT stays off too: susfs needs ksu_try_umount(), which
#     KernelSU-Next does not provide (susfs_try_umount_all would not link).
# (5) ksu-droidspaces-susfs: same minus the mount-hiding features, which are
#     incompatible with DroidSpaces' own bind mounts (verified on hardware).
if [ "$VARIANT" = "ksu-susfs" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
    -d KSU_SUSFS_TRY_UMOUNT -d KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -d KSU_SUSFS_SUS_OVERLAYFS -d KSU_SUSFS_HAS_MAGIC_MOUNT
elif [ "$VARIANT" = "ksu-droidspaces-susfs" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e KSU_SUSFS -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SPOOF_UNAME -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -d KSU_SUSFS_SUS_MOUNT -d KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
    -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT -d KSU_SUSFS_TRY_UMOUNT \
    -d KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
    -d KSU_SUSFS_SUS_OVERLAYFS -d KSU_SUSFS_HAS_MAGIC_MOUNT
elif [ "$VARIANT" = "ksu" ] || [ "$VARIANT" = "ksu-droidspaces" ]; then
  # Kconfig defaults KSU_SUSFS (and most of its sub-options) to y once KSU is
  # enabled, so variants without SUSFS must switch it off explicitly.
  ./scripts/config --file "$OUT/.config" -d KSU_SUSFS
fi

make O="$OUT" ARCH=arm64 CC=clang HOSTCC=gcc olddefconfig

# Sanity check: Kconfig silently drops symbols whose dependencies are missing
# (e.g. KSU needs KPROBES + EXT4_FS), and KernelSU-Next's Kbuild then aborts with
# "No hooks were defined" much later -- or worse, builds a kernel without root.
if [ "$VARIANT" != "noroot" ]; then
  for sym in CONFIG_KSU CONFIG_KSU_KPROBES_HOOK; do
    grep -q "^$sym=y" "$OUT/.config" || {
      echo "error: $sym did not end up =y in $OUT/.config" >&2
      echo "       its Kconfig dependencies are not met by configs/running.config;" >&2
      echo "       see 'depends on' in src/kernel/KernelSU-Next/kernel/Kconfig" >&2
      exit 1
    }
  done
  case "$VARIANT" in
    ksu-susfs|ksu-droidspaces-susfs)
      grep -q '^CONFIG_KSU_SUSFS=y' "$OUT/.config" || {
        echo "error: CONFIG_KSU_SUSFS is not set, is patches/ksu-next-port.diff applied?" >&2
        exit 1
      } ;;
  esac
  ksu_uapi=$(sed -n 's/^#define KERNEL_SU_UAPI_VERSION \([0-9]*\).*/\1/p' \
    "$WS/src/kernel/KernelSU-Next/uapi/supercall.h" 2>/dev/null | head -1)
  echo "KernelSU-Next UAPI: ${ksu_uapi:-unknown} (manager must speak the same version)"
fi

echo "configured $OUT for variant $VARIANT"
grep -E '^CONFIG_(KSU|KSU_SUSFS|KPROBES|SYSVIPC|RELOCATABLE|RANDOMIZE_BASE)=' "$OUT/.config" || true
