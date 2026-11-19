#!/bin/bash
# Flash one boot image through adb (su dd) or fastboot.
#
#   scripts/flash_boot.sh output/boot_ksu_enforcing.img --yes
#   scripts/flash_boot.sh output/boot_ksu_enforcing.img --yes --fastboot
#
# Only /dev/block/by-name/boot is written. The --yes flag is mandatory: the
# script is meant to run after a human approved the flash.
set -e
IMG=${1:?usage: flash_boot.sh IMAGE --yes [--fastboot]}
CONFIRM=${2:-}
MODE=${3:-}
ADB=${ADB:-adb}
FB=${FB:-fastboot}

[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
SUM=$(sha256sum "$IMG" | awk '{print $1}')
echo "image : $IMG"
echo "sha256: $SUM"
echo "target: /dev/block/by-name/boot (slotless, 96 MiB)"
[ "$CONFIRM" = "--yes" ] || { echo "REFUSING: pass --yes after user approval"; exit 2; }

if [ "$MODE" = "--fastboot" ]; then
  "$FB" flash boot "$IMG"
  "$FB" reboot
else
  "$ADB" push "$IMG" /data/local/tmp/boot.img
  "$ADB" shell 'su -c "sha256sum /data/local/tmp/boot.img"'
  "$ADB" shell 'su -c "dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync"'
  "$ADB" shell 'su -c "sha256sum /dev/block/by-name/boot"'
  echo "expected: $SUM"
  "$ADB" reboot
fi
