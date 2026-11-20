# How to build the boot images

**English** | [简体中文](BUILD.md)

Target: Huawei MatePad 11 (DBY-W09, kona/SM8250, HarmonyOS 4.3, kernel
4.19.157-perf). Every step is scripted. The result is 5 feature sets x
enforcing/permissive = 10 `boot_<variant>_<mode>.img` files.

---

## 1. Prerequisites

| Dependency | Notes |
|---|---|
| Source | `DBY-W09_HarmonyOS4.0.0_opensource.tar.gz` (Huawei open-source release, kernel 4.19.157) |
| Toolchain | `toolchain/`: Ubuntu clang 11.1.0-6 + binutils 2.38 (unpacked with `dpkg-deb -x`, see `scripts/env.sh`) |
| Template | `artifacts/boot_stock_device.img` (96 MiB dump of the stock boot partition: provides ramdisk/DTB/cmdline/AVB footer) |
| Host | Linux x86_64, 16 threads: about 7-9 minutes per variant; about 5 GB of build tree per variant |

The toolchain versions are not arbitrary: they must match the running kernel
(`Ubuntu clang version 11.1.0-6`, `GNU ld (GNU Binutils for Ubuntu) 2.38`),
otherwise Huawei's old code and the RTIC section tend to break.

```sh
. scripts/env.sh          # PATH / LD_LIBRARY_PATH / ARCH / CROSS_COMPILE
```

---

## 2. One-time source preparation (idempotent, safe to re-run)

```sh
# 2.1 toolchain: download and unpack Ubuntu clang 11.1.0-6 + binutils 2.38 into toolchain/root
scripts/fetch_toolchain.sh

# 2.2 kernel source + KernelSU + every patch
#     (extract the official tarball -> clone the pinned KernelSU -> wire it up ->
#      patch_source -> SUSFS kernel patch -> KernelSU-side patch -> msm_gem_fault fix)
DBY_TARBALL=./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz scripts/fetch_sources.sh

# 2.3 boot template: dump the 96 MiB stock boot partition from the device
scripts/dump_boot_template.sh
```

`fetch_sources.sh` is equivalent to running the following by hand, which is
useful when comparing or debugging:

```sh
tar xzf DBY-W09_HarmonyOS4.0.0_opensource.tar.gz -C src Code_Opensource/kernel
mv src/Code_Opensource/kernel src/kernel
git clone https://github.com/backslashxx/KernelSU src/kernel/KernelSU
git -C src/kernel/KernelSU checkout b1365d093208a4ab37a6045f0ab0d89977fad637
scripts/wire_kernelsu.sh
python3 scripts/patch_source.py src/kernel
patch -p1 -d src/kernel < patches/susfs-kernel.diff
patch -p1 -d src/kernel < patches/susfs-kernel-fixes.diff
python3 scripts/apply_ksu_susfs.py src/kernel/KernelSU
python3 scripts/patch_msm_fault.py src/kernel
```

`scripts/patch_msm_fault.py`: Huawei's `techpack/display/msm/msm_gem.c` never
builds a page array for imported dma-bufs, and `msm_gem_fault()` dereferences
that NULL directly. When Mesa/llvmpipe inside a container mmaps Anland's
dma-buf, the kernel oopses and the device reboots. The patch fills the page
array from the sg table on fault, and returns `VM_FAULT_SIGBUS` when no pages
are available, so the kernel can no longer crash.

What `scripts/patch_source.py` does (also summarised in the README):
`mkcompile_h` takes `head -n1`, qcacld uses `$(srctree)`, the
`HUAWEI_KERNEL_DEBUG` dependency is removed from `KPROBES/KRETPROBES`, five
backported 5.x `-Werror=` flags are dropped, `.bss.rtic` is folded into the
main `.bss`, and an `lcd_kit_dpd.h` stub is generated.

---

## 3. Build all 10 images with one command

```sh
make images      # 5 variants x 2 modes, serially; regenerates output/ and the manifests
```

A single set (both modes) is also possible:

```sh
make ksu-susfs
make ksu
```

`make images` calls `scripts/build_variant.sh <variant>` for each variant, which
does four things:

1. `scripts/configure.sh out/<variant> <variant>`: starts from
   `configs/running.config` (the device's `/proc/config.gz`), toggles that
   variant's options with `scripts/config`, then runs `olddefconfig`;
2. builds the enforcing flavour: `scripts/build.sh out/<variant> Image.gz`;
3. applies the permissive patch with `scripts/patch_permissive.py`, then
   rebuilds incrementally and links;
4. packs the kernel into the stock image with `scripts/pack_boot.py`, verifies
   it with `scripts/verify_boot.py`, and writes
   `artifacts/boot_<variant>_<mode>.img`.

Timing: the first full build of one variant takes 7-9 minutes with 16 threads;
the permissive rebuild takes 1-2 minutes.

---

## 4. Variants and switches

| Variant | root | SUSFS | Containers | permissive mode |
|---|---|---|---|---|
| `noroot` | – | – | – | permissive from boot |
| `ksu` | ✓ | – | – | permissive from boot |
| `ksu-susfs` | ✓ | full (incl. `SUS_MOUNT` / auto-hide) | – | permissive from boot |
| `ksu-droidspaces` | ✓ | – | ✓ | flips at 20 s |
| `ksu-droidspaces-susfs` | ✓ | partial (no `SUS_MOUNT`) | ✓ | flips at 20 s |

Extra options enabled by the container variants (the list lives in
`scripts/configure.sh`): `SYSVIPC`, `DEVTMPFS`, `CGROUP_DEVICE`, `CGROUP_PIDS`,
`CFS_BANDWIDTH`, `CGROUP_NET_PRIO`, `NETFILTER_XT_MATCH_ADDRTYPE`,
`BRIDGE_NETFILTER`, `MACVLAN`, `IP6_NF_NAT(+MASQUERADE)`, `BINFMT_MISC`,
`NETFILTER_XT_TARGET_TCPMSS`, `NF_CONNTRACK_NETLINK`, `NF_NAT_REDIRECT`,
`IP_ADVANCED_ROUTER`, `IP_MULTIPLE_TABLES`, and `ANDROID_PARANOID_NETWORK` is
disabled.

All variants disable `RELOCATABLE` / `RANDOMIZE_BASE` (Huawei's RTIC section
cannot be relocated, so the kernel must run at its link address) and enable
`KPROBES/KRETPROBES` (required by KernelSU).

---

## 5. How permissive is implemented (important)

Neither `enforcing=0` nor `androidboot.selinux=permissive` on the kernel
command line works on this device (`CONFIG_SECURITY_SELINUX_BOOTPARAM=n`, and
init on a user build always calls `setenforce(1)`), so permissive has to be
compiled in. `scripts/patch_permissive.py` has two modes:

| Mode | What it does | Used by |
|---|---|---|
| `force` | `enforcing_enabled()` in `security.h` always returns false (`setenforce 0` takes effect immediately, `getenforce` reports Permissive immediately) | variants 1/2/3 |
| `delay` | schedules a delayed work in `selinux_init()` that calls `enforcing_set(false)` after `dby_perm_delay` seconds and logs `SELinux: DBY_FORCE_PERMISSIVE flip -> permissive` | variants 4/5 (20 s default) |

Why the container variants cannot use 0 s: early permissive combined with those
container options makes init hang, and Huawei's bootfail sends the device to
fastboot after about two minutes. 20 s (after init's first stage) is completely
fine, which is why variants 4/5 default to 20 seconds.

Changing the delay or the mode (compile time; editing the cmdline does not
work):

```sh
PERM_DELAY=30 make ksu-droidspaces        # container variant flips at 30 s
PERM_MODE=force make ksu-droidspaces      # force 0 s (bootloops; debugging only)
PERM_MODE=delay PERM_DELAY=60 make ksu    # make a non-container variant delayed too
```

---

## 6. Outputs, verification and the output directory

```
artifacts/boot_<variant>_<mode>.img      # build output (96 MiB, header v2)
artifacts/IMAGES.sha256                  # sha256 of the 10 images (generated, not tracked)
output/                                  # curated delivery directory
output/boot_<variant>_<mode>.img         # copies of the 10 images
output/SHA256SUMS                        # checksums for the delivery directory
output/README.md                         # flashing cheat-sheet
```

```sh
make check       # compare every image with the template: only the kernel may differ
make manifest    # regenerate artifacts/IMAGES.sha256 (generated, not tracked)
make dist        # copy the 10 images from artifacts/ to output/ and write SHA256SUMS
make list        # print the variant matrix
```

`make check` relies on `scripts/verify_boot.py`: it parses the boot header v2,
compares kernel/ramdisk/dtb/cmdline/os_version section by section, and checks
that the AVB footer is still present.

---

## 7. Flashing and rollback

```sh
# device boots and has root (KernelSU): adb + dd, boot partition only
adb push output/boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# device does not boot: fastboot (hold Volume Down while plugging in USB)
fastboot flash boot output/boot_<variant>_<mode>.img
fastboot reboot
```

Automation helper (picks the adb/fastboot path itself and samples the
`getenforce` timeline):

```sh
scripts/test_image.sh output/boot_ksu-droidspaces_permissive.img
```

Rollback: flash the boot image you backed up (stock or any known-good build).
The template file `artifacts/boot_stock_device.img` is the stock boot image and
can be flashed directly. This project never writes `ramdisk`, `dtbo`, `vbmeta`
or `userdata`.

---

## 8. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Bootloop after flashing, ends up in fastboot | The kernel did not get through early boot on this device (e.g. 0 s permissive + container options). Flash your backup back and change the mechanism as described in section 5 |
| `getenforce` stays Enforcing | Variants 4/5 only flip at 20 s; check `dmesg \| grep DBY_FORCE_PERMISSIVE` for `flip -> permissive` |
| `dby_perm_delay=NN` on the cmdline has no effect | That module parameter does not work from the cmdline on this device (known issue); rebuild with `PERM_DELAY=NN` |
| `SUS_MOUNT` conflicts with DroidSpaces | Use variant 5 (containers + SUSFS, `SUS_MOUNT` disabled) instead of variant 3 |
| `ksu_susfs` says "Requires susfs v1.5.3+" | The userspace tool must use `prctl(0xDEADBEEF, ...)`; this kernel is SUSFS 1.5.5 with that prctl dispatcher |
| `fetch_sources.sh` fails while cloning KernelSU | Network restriction; use `KSU_URL=<mirror>`, or `KSU_TARBALL=<tar.gz>` / `KSU_DIR=<local KernelSU tree>` |
| Build fails on `lcd_kit_dpd.h` | `scripts/patch_source.py` was not run (it generates the stub) |
| Link fails with an RTIC relocation overflow | The `.bss.rtic` fold from `scripts/patch_source.py` is missing, or `RELOCATABLE` was not disabled |
| The device reboots as soon as the Anland desktop connects | NULL dereference in Huawei's `msm_gem_fault` on imported dma-bufs; make sure `scripts/patch_msm_fault.py` was applied |
| After Anland connects, deniald reports missing `EGL_ANDROID_native_fence_sync` | Mesa in the container selected llvmpipe (no Adreno/kgsl or virgl); this is a userspace GPU configuration issue, not the kernel |

---

## 9. Reproducibility notes

- Toolchain, base config, source patches and variant switches are all pinned
  and replayable; each variant's final `.config` is saved to
  `out/images/<variant>.config`.
- `KBUILD_BUILD_TIMESTAMP` is not fixed, so rebuilding the same source does not
  produce byte-identical images (the build time is embedded in the kernel
  version string). Functionally they are equivalent.
- Key patch snapshots: `patches/susfs-kernel.diff`,
  `patches/susfs-kernel-fixes.diff`, `patches/ksu-susfs.diff`. The two
  permissive flavours are applied at build time by
  `scripts/patch_permissive.py` (`force` / `delay`, see section 5).
