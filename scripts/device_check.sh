#!/bin/bash
# Read-only device status check (adb first, ssh as fallback).
#
#   scripts/device_check.sh            # one-shot report
#   scripts/device_check.sh --watch    # sample getenforce for 90 s (to see the
#                                      # 20 s delayed permissive flip)
#
# Environment:
#   ADB=adb                  adb binary
#   SSH_HOST=user@host       use ssh when adb is not available
#   SSH_PORT=22              ssh port
set -u
ADB=${ADB:-adb}
SSH_HOST=${SSH_HOST:-}
SSH_PORT=${SSH_PORT:-22}

have_adb() { command -v "$ADB" >/dev/null 2>&1 && "$ADB" devices 2>/dev/null | grep -q "device$"; }

sh_() {
  if have_adb; then
    "$ADB" shell "$1" 2>/dev/null | tr -d '\r'
  elif [ -n "$SSH_HOST" ]; then
    ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new "$SSH_HOST" "$1" 2>/dev/null
  else
    echo "error: no adb device and SSH_HOST is not set" >&2
    return 1
  fi
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
