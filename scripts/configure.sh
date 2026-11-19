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

# --- KernelSU ---------------------------------------------------------------
if [ "$VARIANT" != "noroot" ]; then
  ./scripts/config --file "$OUT/.config" \
    -e KPROBES -e KRETPROBES -e KPROBE_EVENTS -d KPROBES_SANITY_TEST \
    -e KSU -e KSU_HACK_ARM64_BRANCH_LINK -e KSU_LSM_SECURITY_HOOKS \
    -e KSU_FEATURE_ADBROOT -e KSU_HEURISTIC_IN_TREE_BUILD \
    -d KSU_DEBUG -d KSU_TAMPER_SYSCALL_TABLE -d KSU_HOSTSREDIRECT \
    -d KSU_ENABLE_FULL_UID_CHECKS -d KSU_THRONE_TRACKER_ALWAYS_THREADED \
    -d KSU_NOPRINTK -d KSU_SHELL_HAS_SU_ALWAYS
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
#     our KSU is backslashxx in-tree and we enable the auto-add/auto-hide paths
#     instead. TRY_UMOUNT is off too: it needs KernelSU's internal try_umount()
#     which this fork does not export (susfs_try_umount_all would be a no-op).
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
echo "configured $OUT for variant $VARIANT"
grep -E '^CONFIG_(KSU|KSU_SUSFS|KPROBES|SYSVIPC|RELOCATABLE|RANDOMIZE_BASE)=' "$OUT/.config" || true
