#!/bin/bash
# Reproducible M1 config: start from the device's /proc/config.gz, integrate KSU.
set -e
WS=/home/zyt/dby-w09-kernel
OUT="${1:?usage: configure.sh OUTDIR}"
. "$WS/scripts/env.sh"
mkdir -p "$OUT"
cp "$WS/configs/running.config" "$OUT/.config"
cd "$WS/src/kernel"
make O="$OUT" ARCH=arm64 CC=clang HOSTCC=gcc olddefconfig
./scripts/config --file "$OUT/.config" \
  -e KPROBES -e KRETPROBES -e KPROBE_EVENTS -d KPROBES_SANITY_TEST \
  -e KSU -e KSU_HACK_ARM64_BRANCH_LINK -e KSU_LSM_SECURITY_HOOKS \
  -e KSU_FEATURE_ADBROOT -e KSU_HEURISTIC_IN_TREE_BUILD \
  -d KSU_DEBUG -d KSU_TAMPER_SYSCALL_TABLE -d KSU_HOSTSREDIRECT \
  -d KSU_ENABLE_FULL_UID_CHECKS -d KSU_THRONE_TRACKER_ALWAYS_THREADED \
  -d KSU_NOPRINTK -d KSU_SHELL_HAS_SU_ALWAYS \
  -d RELOCATABLE -d RANDOMIZE_BASE
make O="$OUT" ARCH=arm64 CC=clang HOSTCC=gcc olddefconfig
grep -E '^CONFIG_(KSU|KPROBES|KRETPROBES|RELOCATABLE)=' "$OUT/.config" || true
echo "configured $OUT"
