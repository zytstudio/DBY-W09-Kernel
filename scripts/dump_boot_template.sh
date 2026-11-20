#!/bin/bash
# Install the boot template that scripts/pack_boot.py splices the new kernel
# into (stock ramdisk / DTB / cmdline / AVB footer are kept from it).
#
#   scripts/dump_boot_template.sh               dump the boot partition from the
#                                               attached device (adb + root)
#   scripts/dump_boot_template.sh PATH          install a manually backed-up
#                                               boot.img
#   scripts/dump_boot_template.sh --from PATH   same as above
#
# Both write artifacts/boot_stock_device.img (96 MiB for this device).
#
# A manual backup is validated before it is installed: ANDROID! header v2 with
# 4096-byte pages, gzip kernel, non-empty ramdisk/DTB, and the AVB footer that
# pack_boot.py rewrites. Any complete dump of the boot partition works, e.g.
#
#   adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot.img bs=4096'
#   adb pull /sdcard/boot.img boot_stock_device.img
#   scripts/dump_boot_template.sh boot_stock_device.img
#
# or the same file pulled with fastboot/TWRP/a full-partition backup.
#
# Expected sha256 of the stock HarmonyOS 4.3.0.196 boot image:
#   8ce0842bb35ab36431f68f6ea17693b894c5af5bc6d895dcfeb6a9ea736b57f7
# A different firmware hashes differently; that is only a warning.
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
ADB=${ADB:-adb}
OUT=$WS/artifacts/boot_stock_device.img
TMP=/data/local/tmp/boot_stock_device.img
EXPECT=8ce0842bb35ab36431f68f6ea17693b894c5af5bc6d895dcfeb6a9ea736b57f7
PART=100663296   # 96 MiB boot partition

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

SRC=
if [ $# -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --from)
      [ $# -eq 2 ] || { usage >&2; exit 2; }
      SRC=$2
      ;;
    -*)
      echo "error: unknown option '$1' (try --help)" >&2
      exit 2
      ;;
    *)
      [ $# -eq 1 ] || { usage >&2; exit 2; }
      SRC=$1
      ;;
  esac
fi

# Print a summary of the image and fail if pack_boot.py could not use it.
validate() {
  python3 - "$1" <<'PY'
import struct, sys

p = sys.argv[1]
d = open(p, 'rb').read()

def fail(msg):
    sys.exit('error: %s: %s' % (p, msg))

if len(d) < 4096 or d[:8] != b'ANDROID!':
    fail('not an Android boot image (missing ANDROID! magic)')
ks, _ka, rs, _ra, _ss, _sa, _ta, ps = struct.unpack('<8I', d[8:40])
hv, _osv = struct.unpack('<2I', d[40:48])
hsz = struct.unpack('<I', d[1644:1648])[0]
dtb = struct.unpack('<I', d[1648:1652])[0]
if ps != 4096:
    fail('page size is %d, expected 4096' % ps)
if hv != 2:
    fail('boot header version is %d, expected 2' % hv)
if ks == 0:
    fail('kernel section is empty')
if d[ps:ps + 2] != b'\x1f\x8b':
    fail('kernel section is not gzip-compressed')

def align(x):
    return (x + ps - 1) // ps * ps

payload_end = ps + align(ks) + align(rs) + align(dtb)
if rs == 0:
    fail('ramdisk section is empty')
if dtb == 0:
    fail('DTB section is empty')
if len(d) < payload_end:
    fail('file is %d bytes but the payload ends at %d; dump the whole partition'
         % (len(d), payload_end))
if d[-64:-60] != b'AVBf':
    fail('no AVB footer at the end of the file; is this a complete partition dump?')
orig_sz, vm_off, vm_sz = struct.unpack('>QQQ', d[-52:-28])
if orig_sz != payload_end:
    fail('AVB footer says the image is %d bytes, payload ends at %d'
         % (orig_sz, payload_end))

print('  size:     %d bytes' % len(d))
print('  header:   v%d, page %d, header size %d' % (hv, ps, hsz))
print('  kernel:   %d bytes (gzip)' % ks)
print('  ramdisk:  %d bytes' % rs)
print('  dtb:      %d bytes' % dtb)
print('  vbmeta:   %d bytes @ %d' % (vm_sz, vm_off))
PY
}

mkdir -p "$WS/artifacts"

if [ -n "$SRC" ]; then
  [ -e "$SRC" ] || { echo "error: $SRC does not exist" >&2; exit 1; }
  [ -f "$SRC" ] || { echo "error: $SRC is not a regular file" >&2; exit 1; }
  echo "== validating backup $SRC"
  validate "$SRC" || exit 1
  if [ -f "$OUT" ] && ! cmp -s "$SRC" "$OUT"; then
    echo "== replacing existing $OUT"
  fi
  cp -f "$SRC" "$OUT"
else
  need_root() { "$ADB" shell 'su -c id' 2>/dev/null | tr -d '\r' | grep -q 'uid=0'; }
  need_root || {
    echo "error: adb device with KernelSU/root is required." >&2
    echo "       For a manual backup pass it as an argument: $0 PATH" >&2
    exit 1
  }
  echo "== dumping /dev/block/by-name/boot on the device"
  "$ADB" shell "su -c 'dd if=/dev/block/by-name/boot of=$TMP bs=4096'"
  echo "== pulling"
  "$ADB" pull "$TMP" "$OUT"
  echo "== validating dump"
  validate "$OUT" || {
    echo "error: the dump cannot be used as a boot template." >&2
    exit 1
  }
fi

chmod 644 "$OUT"
echo "== sha256"
sha256sum "$OUT"
sum=$(sha256sum "$OUT" | awk '{print $1}')
size=$(stat -c %s "$OUT")
if [ "$sum" = "$EXPECT" ]; then
  echo "OK: stock boot image matches the known sha256"
else
  echo "WARN: sha256 differs from the known stock image."
  echo "      That is fine for a different firmware, but boot images built"
  echo "      against it are not byte-comparable with the released ones."
fi
if [ "$size" != "$PART" ]; then
  echo "WARN: template is $size bytes, expected $PART (96 MiB);"
  echo "      the images built from it will have the same size."
fi
