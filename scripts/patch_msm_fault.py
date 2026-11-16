#!/usr/bin/env python3
"""Fix the Huawei display techpack MSM driver so mmap() of an *imported*
dma-buf cannot crash the kernel.

Background (found on hardware 2026-11-16): running a Wayland compositor inside a
Droidspaces container with GPU passthrough makes Mesa/llvmpipe mmap the
consumer's Android dma-buf through /dev/dri/renderD128.  In this vendor tree
`msm_gem_import()` deliberately leaves `msm_obj->pages = NULL` for imported
buffers (they are normally only mapped through the IOMMU), and `get_pages()`
returns that NULL for `obj->import_attach`.  `msm_gem_fault()` then does
`page_to_pfn(pages[pgoff])` -> NULL pointer dereference -> Huawei bbox/panic ->
device reboot.

The fix:
  * build the page array from the object's sg table on first fault, so a CPU
    mapping of a cached imported dma-buf actually works (this is what the
    mainline drivers/gpu/drm/msm/msm_gem.c does at import time), and
  * if the sg table was not attached yet, return VM_FAULT_SIGBUS instead of
    dereferencing NULL, so the worst case is a SIGBUS in the caller rather
    than a kernel panic/reboot.

Idempotent: re-running does nothing.  Usage: patch_msm_fault.py [--check]
"""
import argparse
import sys

MARK = "DBY_MSM_GEM_FAULT_FIX"

INC_OLD = "#include <linux/ion.h>\n"
INC_NEW = "#include <linux/ion.h>\n#include <drm/drm_prime.h>\n"

GET_OLD = """	if (obj->import_attach)
		return msm_obj->pages;
"""

GET_NEW = """	if (obj->import_attach) {
		/* DBY_MSM_GEM_FAULT_FIX: imported dma-bufs have no page array in
		 * this tree; build it from the sg table so CPU mmap works. */
		if (!msm_obj->pages && msm_obj->sgt) {
			int npages = obj->size >> PAGE_SHIFT;
			struct page **p = kvmalloc_array(npages, sizeof(*p),
							 GFP_KERNEL);
			if (p) {
				if (drm_prime_sg_to_page_addr_arrays(msm_obj->sgt,
								     p, NULL, npages))
					kvfree(p);
				else
					msm_obj->pages = p;
			}
		}
		return msm_obj->pages;
	}
"""

FAULT_OLD = """	if (IS_ERR(pages)) {
		ret = vmf_error(PTR_ERR(pages));
		goto out_unlock;
	}
"""
FAULT_NEW = """	if (IS_ERR(pages)) {
		ret = vmf_error(PTR_ERR(pages));
		goto out_unlock;
	}

	if (!pages) {
		/* DBY_MSM_GEM_FAULT_FIX: never dereference a NULL page array */
		ret = VM_FAULT_SIGBUS;
		goto out_unlock;
	}
"""


def main():
    ws = "/home/zyt/dby-w09-kernel"
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--srcdir", default=ws + "/src/kernel")
    args = ap.parse_args()
    p = args.srcdir + "/techpack/display/msm/msm_gem.c"
    s = open(p).read()
    applied = MARK in s
    if args.check:
        print("msm fault fix:", "APPLIED" if applied else "not applied")
        return 0 if applied else 1
    if applied:
        print("already applied")
        return 0
    for old, new in ((GET_OLD, GET_NEW), (FAULT_OLD, FAULT_NEW)):
        if s.count(old) != 1:
            sys.exit("error: anchor not found exactly once in msm_gem.c")
        s = s.replace(old, new, 1)
    if INC_NEW not in s:
        if INC_OLD not in s:
            sys.exit("error: include anchor missing")
        s = s.replace(INC_OLD, INC_NEW, 1)
    open(p, "w").write(s)
    print("msm fault fix applied")
    return 0


if __name__ == "__main__":
    sys.exit(main())
