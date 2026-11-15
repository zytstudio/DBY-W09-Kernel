#!/usr/bin/env python3
"""Repack a Huawei DBY-W09 boot image (header v2) with a new Image.gz.

Keeps the stock ramdisk + DTB + cmdline + os_version + id, only swaps the
kernel payload. Payload layout: header | kernel | ramdisk | dtb, page 4096.
If the new payload exceeds the stock payload end, the AVB vbmeta blob is
moved right after the payload and the footer is rewritten (big-endian);
AVB is not enforced on this device (verified: the running custom kernel
does not match the stock footer digest yet boots).
"""
import argparse, struct, sys

def align(x, p): return (x + p - 1) // p * p

def parse(d):
    assert d[:8] == b'ANDROID!', 'bad magic'
    h = {}
    (h['kernel_size'], h['kernel_addr'], h['ramdisk_size'], h['ramdisk_addr'],
     h['second_size'], h['second_addr'], h['tags_addr'], h['page_size']) = struct.unpack('<8I', d[8:40])
    h['header_version'], h['os_version'] = struct.unpack('<2I', d[40:48])
    h['dtb_size'] = struct.unpack('<I', d[1648:1652])[0]
    h['dtb_addr'] = struct.unpack('<Q', d[1652:1660])[0]
    h['header_size'] = struct.unpack('<I', d[1644:1648])[0]
    return h

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--template', required=True)
    ap.add_argument('--out', required=True)
    args = ap.parse_args()

    t = open(args.template, 'rb').read()
    h = parse(t)
    ps = h['page_size']
    assert ps == 4096 and h['header_version'] == 2, h

    ko = ps
    ro = ko + align(h['kernel_size'], ps)
    do = ro + align(h['ramdisk_size'], ps)
    orig_end = do + align(h['dtb_size'], ps)
    footer = t[-64:]
    assert footer[:4] == b'AVBf', 'no AVB footer'
    orig_sz, vm_off, vm_sz = struct.unpack('>QQQ', footer[12:36])
    assert orig_sz == orig_end, (orig_sz, orig_end)
    vbmeta = t[vm_off:vm_off + vm_sz]

    ramdisk = t[ro:ro + h['ramdisk_size']]
    dtb = t[do:do + h['dtb_size']]

    k = open(args.kernel, 'rb').read()
    if k[:2] != b'\x1f\x8b':
        sys.exit('kernel is not gzip')

    nro = ko + align(len(k), ps)
    ndo = nro + align(len(ramdisk), ps)
    nend = ndo + align(len(dtb), ps)

    hdr = bytearray(t[:ps])
    struct.pack_into('<I', hdr, 8, len(k))

    if nend <= orig_end:
        new_vm_off, new_vm_sz, new_orig = vm_off, vm_sz, orig_sz
        out = bytearray(t[:orig_end])
    else:
        new_vm_off, new_vm_sz, new_orig = nend, vm_sz, nend
        out = bytearray(nend)

    out[0:ps] = hdr
    out[ko:ko + len(k)] = k
    out[nro:nro + len(ramdisk)] = ramdisk
    out[ndo:ndo + len(dtb)] = dtb
    for a, b in ((ko + len(k), nro), (nro + len(ramdisk), ndo), (ndo + len(dtb), nend)):
        if b > a:
            out[a:b] = b'\x00' * (b - a)

    out[new_vm_off:new_vm_off + new_vm_sz] = vbmeta

    total = len(t)
    if len(out) > total - 64:
        sys.exit('payload too large for partition')
    out += b'\x00' * (total - 64 - len(out))
    ft = bytearray(footer)
    struct.pack_into('>QQQ', ft, 12, new_orig, new_vm_off, new_vm_sz)
    out += ft

    open(args.out, 'wb').write(out)
    print(f"kernel {len(k):,} B  payload_end {new_orig:,}  image {len(out):,} B  "
          f"{'in-place footer' if new_vm_off == vm_off else 'footer relocated'}")

if __name__ == '__main__':
    main()
