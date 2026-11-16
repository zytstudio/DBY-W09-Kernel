#!/bin/bash
# Read-only device status check over adb (preferred) or ssh.
#
#   scripts/device_check.sh            # one-shot report
#   scripts/device_check.sh --watch    # sample getenforce for 90 s (for the
#                                      # permissive images, which flip at
#                                      # dby_perm_delay seconds after boot)
set -u
ADB=${ADB:-/mnt/c/Users/18210/Desktop/UFI001C/adb.exe}
SSH_HELPER=${SSH_HELPER:-/tmp/dsh.sh}

have_adb() { [ -x "$ADB" ] && "$ADB" devices 2>/dev/null | grep -q "device$"; }

sh_() {
  if have_adb; then "$ADB" shell "$1" 2>/dev/null | tr -d '\r'
  else "$SSH_HELPER" "$1" 2>/dev/null; fi
}

report() {
  echo "== $(date +%H:%M:%S) =="
  sh_ 'uname -r; getenforce; cat /sys/fs/selinux/enforce 2>/dev/null; getprop ro.boot.selinux'
  echo "-- root:"
  sh_ 'su -c id 2>&1 | head -1'
  echo "-- DBY marker:"
  sh_ 'su -c "dmesg | grep DBY_FORCE_PERMISSIVE | tail -2"'
}

if [ "${1:-}" = "--watch" ]; then
  for i in $(seq 1 18); do
    g=$(sh_ 'getenforce')
    printf '%3ds getenforce=%s\n' $((i * 5)) "$g"
    sleep 5
  done
else
  report
fi
