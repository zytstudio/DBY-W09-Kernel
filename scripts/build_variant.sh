#!/bin/bash
# Build both SELinux flavours (enforcing + permissive) of one kernel variant and
# pack them into boot images.
#
#   build_variant.sh VARIANT
#
# Produces
#   out/<variant>/arch/arm64/boot/Image.gz      (enforcing, last build)
#   out/images/<variant>-enforcing.Image.gz
#   out/images/<variant>-permissive.Image.gz
#   out/images/<variant>.config
#   artifacts/boot_<variant>_enforcing.img
#   artifacts/boot_<variant>_permissive.img
#
# The permissive flavour is the *same* .config with a source-level patch
# (scripts/patch_permissive.py, mode from $PERM_MODE, default "delay"), so only a
# handful of selinux objects rebuild.  "delay" boots enforcing and flips to
# permissive through a delayed work (dby_perm_delay=60 by default), because a
# kernel that is permissive from early boot makes this HarmonyOS build reboot
# before adb/ssh come up.
set -euo pipefail
WS=/home/zyt/dby-w09-kernel
cd "$WS"
V="${1:?usage: build_variant.sh VARIANT}"
OUT="$WS/out/$V"
IMG="$WS/out/images"
TEMPLATE="$WS/artifacts/boot_stock_device.img"
LOG="$WS/out/${V}_build.log"
mkdir -p "$OUT" "$IMG"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

pack() {  # pack MODE
  local mode="$1"
  python3 scripts/pack_boot.py \
    --kernel "$OUT/arch/arm64/boot/Image.gz" \
    --template "$TEMPLATE" \
    --out "artifacts/boot_${V}_${mode}.img" | tee -a "$LOG"
  python3 scripts/verify_boot.py "$TEMPLATE" "artifacts/boot_${V}_${mode}.img" \
    | tee -a "$LOG" | grep -q 'RESULT: OK'
  cp "$OUT/arch/arm64/boot/Image.gz" "$IMG/${V}-${mode}.Image.gz"
  sha256sum "artifacts/boot_${V}_${mode}.img" > "artifacts/boot_${V}_${mode}.img.sha256"
}

log "=== variant $V: ensure enforcing tree state ==="
python3 scripts/patch_permissive.py --disable | tee -a "$LOG"

log "=== variant $V: configure ==="
scripts/configure.sh "$OUT" "$V" 2>&1 | tee -a "$LOG"

log "=== variant $V: build enforcing ==="
scripts/build.sh "$OUT" Image.gz 2>&1 | tee -a "$LOG" | tail -5
pack enforcing
cp "$OUT/.config" "$IMG/${V}.config"

log "=== variant $V: build permissive ==="
# Container-enabled variants (4/5) cannot boot with SELinux permissive from the
# first instruction: init's early phase needs enforcement and the device ends up
# in Huawei's bootfail/fastboot loop.  For them flip at $PERM_DELAY seconds
# instead (verified: 20 s is enough).  The other variants are truly permissive
# from boot.
case "$V" in
  ksu-droidspaces|ksu-droidspaces-susfs) PMODE="${PERM_MODE:-delay}"; PSEC="${PERM_DELAY:-20}" ;;
  *) PMODE="${PERM_MODE:-force}"; PSEC="${PERM_DELAY:-20}" ;;
esac
python3 scripts/patch_permissive.py --mode "$PMODE" --delay-sec "$PSEC" | tee -a "$LOG"
scripts/build.sh "$OUT" Image.gz 2>&1 | tee -a "$LOG" | tail -5
pack permissive

log "=== variant $V: restore enforcing build in $OUT ==="
python3 scripts/patch_permissive.py --disable | tee -a "$LOG"
scripts/build.sh "$OUT" Image.gz 2>&1 | tee -a "$LOG" | tail -3

log "=== variant $V: done ==="
ls -l artifacts/boot_${V}_*.img | tee -a "$LOG"
