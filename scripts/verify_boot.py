#!/usr/bin/env python3
"""Compare a repacked boot image against the template: only the kernel may differ."""
import sys, struct, hashlib

def parse(d):
    h = {}
    (h['kernel_size'], h['ramdisk_size']) = (struct.unpack('<I', d[8:12])[0], struct.unpack('<I', d[16:20])[0])
    h['page'] = struct.unpack('<I', d[36:40])[0]
    h['hv'] = struct.unpack('<I', d[40:44])[0]
    h['dtb_size'] = struct.unpack('<I', d[1648:1652])[0]
    h['dtb_addr'] = struct.unpack('<Q', d[1652:1660])[0]
    return h

a = open(sys.argv[1], 'rb').read()
b = open(sys.argv[2], 'rb').read()
ha, hb = parse(a), parse(b)
ps = ha['page']
def sec(d, h):
    ko = ps; ro = ko + (h['kernel_size'] + ps - 1)//ps*ps
    do = ro + (h['ramdisk_size'] + ps - 1)//ps*ps
    return (d[ko:ko+h['kernel_size']], d[ro:ro+h['ramdisk_size']], d[do:do+h['dtb_size']])
ka, ra, da = sec(a, ha)
kb, rb, db = sec(b, hb)
print(f"template kernel {len(ka):,}  new kernel {len(kb):,}")
print(f"ramdisk identical: {ra == rb} ({len(ra):,} B)")
print(f"dtb identical:     {da == db} ({len(da):,} B)")
print(f"cmdline identical: {a[64:576] == b[64:576]}")
print(f"os_version identical: {a[44:48] == b[44:48]}")
print(f"header_version: {ha['hv']} -> {hb['hv']}  page {ps}  dtb_addr same: {ha['dtb_addr']==hb['dtb_addr']}")
print(f"footer magic: {b[-64:-60]}")
print(f"sha256: {hashlib.sha256(b).hexdigest()}")
ok = ra == rb and da == db and a[64:576] == b[64:576] and a[44:48] == b[44:48]
print("RESULT:", "OK (only kernel differs)" if ok else "MISMATCH")
sys.exit(0 if ok else 1)
