#!/bin/bash
# Flash ONE boot image and sample the SELinux state while it boots.
#
#   scripts/test_image.sh artifacts/boot_ksu-susfs_permissive.img
#
# Writes /dev/block/by-name/boot only (needs the user's go-ahead for the flash).
# Uses adb when the running system still has root (KernelSU `su`), otherwise
# falls back to `adb reboot bootloader` + fastboot.
#
# Prints: flashed sha256, adb-up time, getenforce timeline (to catch the
# dby_perm_delay flip), root status, and the DBY dmesg lines.
set -u
WIN=/mnt/c/Users/18210/Desktop/UFI001C
ADB="$WIN/adb.exe"
FB="$WIN/fastboot.exe"

IMG=${1:?usage: test_image.sh IMAGE}
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }
NAME=$(basename "$IMG")
SUM=$(sha256sum "$IMG" | awk '{print $1}')
echo "== image: $NAME"
echo "== sha256: $SUM"

# stage the file where Windows adb/fastboot can see it
cp "$IMG" "/tmp/$NAME"
cmd.exe /c "copy /Y \\\\wsl.localhost\\Ubuntu-24.04\\tmp\\$NAME C:\\Users\\18210\\Desktop\\UFI001C\\$NAME" >/dev/null 2>&1
[ -f "$WIN/$NAME" ] || { echo "!! failed to stage $WIN/$NAME"; exit 1; }

has_root() { "$ADB" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; }

if has_root; then
  echo "== flashing via adb (su dd)"
  ( cd "$WIN" && "$ADB" push "$NAME" /data/local/tmp/boot.img >/dev/null 2>&1 )
  "$ADB" shell 'su -c "sha256sum /data/local/tmp/boot.img"' 2>/dev/null | tr -d '\r'
  "$ADB" shell 'su -c "dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync"' >/dev/null 2>&1
  "$ADB" shell 'su -c "sha256sum /dev/block/by-name/boot"' 2>/dev/null | tr -d '\r'
  "$ADB" reboot
else
  echo "== no root, flashing via fastboot"
  "$ADB" reboot bootloader
  sleep 12
  ( cd "$WIN" && "$FB" devices 2>&1 | tail -2 )
  ( cd "$WIN" && "$FB" flash boot "$NAME" 2>&1 | tail -2 )
  ( cd "$WIN" && "$FB" reboot )
fi

echo "== waiting for adb"
t0=$(date +%s)
up=""
for i in $(seq 1 30); do
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
