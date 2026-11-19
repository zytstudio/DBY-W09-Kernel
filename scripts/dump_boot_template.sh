#!/bin/bash
# Dump the device's stock boot partition to artifacts/boot_stock_device.img.
#
#   scripts/dump_boot_template.sh
#
# The 96 MiB image is the template used by scripts/pack_boot.py: the new kernel
# is spliced into it, the stock ramdisk/DTB/cmdline are kept. It is not part of
# the git repository (too large), so every builder dumps it once from a device
# that still has the stock boot partition (or any known-good backup).
#
# Expected sha256 (stock HarmonyOS 4.3.0.196):
#   8ce0842bb35ab36431f68f6ea17693b894c5af5bc6d895dcfeb6a9ea736b57f7
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
OUT=$WS/artifacts/boot_stock_device.img
TMP=/data/local/tmp/boot_stock_device.img
EXPECT=8ce0842bb35ab36431f68f6ea17693b894c5af5bc6d895dcfeb6a9ea736b57f7

need_root() { "$ADB" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; }
need_root || { echo "error: adb device with KernelSU/root is required" >&2; exit 1; }

mkdir -p "$WS/artifacts"
echo "== dumping /dev/block/by-name/boot (96 MiB) on the device"
"$ADB" shell "su -c 'dd if=/dev/block/by-name/boot of=$TMP bs=4096'"

echo "== pulling"
"$ADB" pull "$TMP" "$OUT"

echo "== sha256"
sha256sum "$OUT"
sum=$(sha256sum "$OUT" | awk '{print $1}')
if [ "$sum" = "$EXPECT" ]; then
  echo "OK: stock boot image matches the known sha256"
else
  echo "WARN: sha256 differs from the known stock image."
  echo "      That is fine for a different firmware, but boot images built"
  echo "      against it are not byte-comparable with the released ones."
fi
