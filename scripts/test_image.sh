#!/bin/bash
# Flash ONE boot image to /dev/block/by-name/boot and sample SELinux state.
#
#   scripts/test_image.sh output/boot_ksu-droidspaces_permissive.img
#
# Requires adb (and fastboot for the no-root fallback) in PATH, or set
#   ADB=/path/to/adb FB=/path/to/fastboot
#
# Behaviour: if the running system still has KernelSU root, push + `su -c dd`;
# otherwise reboot to the bootloader and use fastboot. Only the boot partition
# is written. Needs the user's go-ahead for the flash.
set -u
ADB=${ADB:-adb}
FB=${FB:-fastboot}

IMG=${1:?usage: test_image.sh IMAGE}
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
SUM=$(sha256sum "$IMG" | awk '{print $1}')
echo "== image: $IMG"
echo "== sha256: $SUM"

has_root() { "$ADB" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; }

if has_root; then
  echo "== flashing via adb (su dd)"
  "$ADB" push "$IMG" /data/local/tmp/boot.img >/dev/null 2>&1
  "$ADB" shell 'su -c "sha256sum /data/local/tmp/boot.img"' 2>/dev/null | tr -d '\r'
  "$ADB" shell 'su -c "dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync"' >/dev/null 2>&1
  "$ADB" shell 'su -c "sha256sum /dev/block/by-name/boot"' 2>/dev/null | tr -d '\r'
  "$ADB" reboot
else
  echo "== no root, flashing via fastboot"
  "$ADB" reboot bootloader
  sleep 12
  "$FB" devices 2>&1 | tail -2
  "$FB" flash boot "$IMG" 2>&1 | tail -2
  "$FB" reboot
fi

echo "== waiting for adb"
t0=$(date +%s)
up=""
for _ in $(seq 1 30); do
  if "$ADB" shell true 2>/dev/null; then up=$(( $(date +%s) - t0 )); echo "   adb up after ${up}s"; break; fi
  sleep 3
done
[ -n "$up" ] || { echo "!! adb never came up"; exit 1; }

echo "== getenforce timeline"
for i in $(seq 1 10); do
  g=$("$ADB" shell getenforce 2>/dev/null | tr -d '\r')
  printf '   +%3ds after adb-up: %s\n' $((i * 10)) "$g"
  [ "$g" = "Permissive" ] && break
  sleep 10
done

echo "== details"
"$ADB" shell 'uname -r; getenforce' 2>/dev/null | tr -d '\r'
"$ADB" shell 'su -c id' 2>/dev/null | tr -d '\r' | head -1 || echo "   (no su)"
"$ADB" shell 'su -c "dmesg | grep DBY_FORCE_PERMISSIVE | tail -2"' 2>/dev/null | tr -d '\r'
