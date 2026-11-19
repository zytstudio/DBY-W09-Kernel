#!/usr/bin/env python3
"""Apply the KernelSU-side SUSFS patch (patches/ksu-susfs.diff).

That patch carries everything the kernel side needs from KernelSU:
  - kernel/ksu.c: include <linux/susfs.h>, call susfs_init()
  - kernel/Kconfig: the "KernelSU - SUSFS" menu
  - kernel/selinux/selinux.c: susfs_is_current_{ksu,zygote}_domain()

It is generated against backslashxx/KernelSU vendored version
b1365d093208a4ab37a6045f0ab0d89977fad637 (v3.3.1), so pin the checkout there
(scripts/fetch_sources.sh does).

Usage: python3 scripts/apply_ksu_susfs.py [KERNELSU_DIR]
Idempotent: does nothing when the patch is already applied.
"""
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KSU = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "src/kernel/KernelSU")
PATCH = os.path.join(REPO, "patches/ksu-susfs.diff")


def git(*args):
    return subprocess.run(["git", "-C", KSU, *args], capture_output=True, text=True)


def main():
    if not os.path.isdir(os.path.join(KSU, "kernel")):
        sys.exit(f"error: {KSU} does not look like a KernelSU checkout")

    r = git("apply", "--reverse", "--check", PATCH)
    if r.returncode == 0:
        print("KernelSU SUSFS patch already applied")
        return 0

    r = git("apply", "--check", PATCH)
    if r.returncode != 0:
        sys.exit("error: patch does not apply cleanly:\n" + r.stderr)

    r = git("apply", PATCH)
    if r.returncode != 0:
        sys.exit("error: git apply failed:\n" + r.stderr)
    print("KernelSU SUSFS patch applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
