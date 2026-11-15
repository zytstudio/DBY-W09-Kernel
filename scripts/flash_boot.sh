#!/bin/bash
# Usage: flash_boot.sh <local.img> [--yes]
# Requires explicit --yes; always prints the exact command first.
set -e
IMG="$1"; CONFIRM="$2"
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
SUM=$(sha256sum "$IMG" | awk '{print $1}')
echo "image : $IMG"
echo "sha256: $SUM"
echo "target: /dev/block/by-name/boot  (slotless, 96MiB)"
echo "cmd   : su -c 'dd if=/sdcard/Download/$(basename "$IMG") of=/dev/block/by-name/boot bs=4096 conv=fsync'"
[ "$CONFIRM" = "--yes" ] || { echo "REFUSING: pass --yes after user approval"; exit 2; }
scp -P 8022 -o StrictHostKeyChecking=no "$IMG" u0_a212@192.168.1.215:/sdcard/Download/ >/dev/null
/tmp/dsh.sh "su -c 'sha256sum /sdcard/Download/$(basename "$IMG")'" 2>/dev/null
/tmp/dsh.sh "su -c 'dd if=/sdcard/Download/$(basename "$IMG") of=/dev/block/by-name/boot bs=4096 conv=fsync'" 2>/dev/null
/tmp/dsh.sh "su -c 'sha256sum /dev/block/by-name/boot'" 2>/dev/null
echo "expected: $SUM"
