#!/usr/bin/env python3
"""Apply the KernelSU-side SUSFS patch (patches/ksu-susfs.diff).

That patch carries everything the kernel side needs from KernelSU:
  - kernel/ksu.c: include <linux/susfs.h>, call susfs_init()
  - kernel/Kconfig: the "KernelSU - SUSFS" menu
  - kernel/selinux/selinux.c: susfs_is_current_{ksu,zygote}_domain()

It is generated against backslashxx/KernelSU vendored version
b1365d093208a4ab37a6045f0ab0d89977fad637 (v3.3.1), so pin the checkout there
(scripts/fetch_sources.sh does).

Works both for a git checkout and for an offline archive without .git.

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


def looks_applied():
    kconfig = os.path.join(KSU, "kernel/Kconfig")
    ksu_c = os.path.join(KSU, "kernel/ksu.c")
    try:
        return ("KSU_SUSFS" in open(kconfig).read()
                and "susfs_init" in open(ksu_c).read())
    except OSError:
        return False


def main():
    if not os.path.isdir(os.path.join(KSU, "kernel")):
        sys.exit(f"error: {KSU} does not look like a KernelSU checkout")

    if not os.path.isdir(os.path.join(KSU, ".git")):
        # Offline archive: `git apply` would walk up into a surrounding repo, so
        # detect the applied state from the files and use plain patch(1).
        if looks_applied():
            print("KernelSU SUSFS patch already applied")
            return 0
        r = subprocess.run(["patch", "-p1", "-d", KSU, "-i", PATCH],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("error: patch failed:\n" + r.stdout + r.stderr)
        if not looks_applied():
            sys.exit("error: patch ran but the expected changes are missing")
        print("KernelSU SUSFS patch applied")
        return 0

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
