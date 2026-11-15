#!/usr/bin/env python3
"""Idempotently wire SUSFS into a backslashxx/KernelSU v3.3.x checkout.

Usage: python3 scripts/apply_ksu_susfs.py [KERNELSU_DIR]
"""
import os, sys

KSU = sys.argv[1] if len(sys.argv) > 1 else 'src/kernel/KernelSU'
PATCH = '/tmp/10_susfs.patch'

def sub(path, old, new, label):
    p = os.path.join(KSU, path)
    s = open(p).read()
    if new in s:
        print('  [skip]', label); return
    if old not in s:
        print('  [MISS]', label); return
    open(p, 'w').write(s.replace(old, new, 1))
    print('  [ok]  ', label)

# 1) include susfs.h
sub('kernel/ksu.c', '#include "kernel_includes.h"\n',
    '#include "kernel_includes.h"\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif\n',
    'ksu.c: include susfs.h')
# 2) call susfs_init() at KSU init
sub('kernel/ksu.c', '\tksu_print_build_info();\n',
    '\tksu_print_build_info();\n#ifdef CONFIG_KSU_SUSFS\n\tsusfs_init();\n#endif\n',
    'ksu.c: susfs_init()')
# 3) append Kconfig menu (extracted from simonpunk's 10_ patch)
p = os.path.join(KSU, 'kernel/Kconfig')
s = open(p).read()
if 'KSU_SUSFS' in s:
    print('  [skip] Kconfig menu')
else:
    patch = open(PATCH, errors='replace').read()
    i = patch.find('diff --git a/kernel/Kconfig')
    j = patch.find('\ndiff --git ', i + 5)
    added = [l[1:] for l in patch[i:j].splitlines() if l.startswith('+')]
    # drop the '++ b/kernel/Kconfig' header artifact
    added = [l for l in added if l.strip() not in ('++ b/kernel/Kconfig', '+++ b/kernel/Kconfig')]
    menu = '\n'.join(added).strip()
    open(p, 'w').write(s.rstrip() + '\n\n' + menu + '\n')
    print('  [ok]   Kconfig menu')
