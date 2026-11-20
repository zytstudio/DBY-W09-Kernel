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
| Containers (optional) | No toolchain or build dependencies on the host: use Docker, `docker/run.sh` (the toolchain is baked into the image, see 3.2) |

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
#     (a no-op when it is already unpacked; --force re-unpacks. Not needed with Docker)
scripts/fetch_toolchain.sh

# 2.2 kernel source + KernelSU + every patch
#     (extract the official tarball -> clone the pinned KernelSU -> wire it up ->
#      patch_source -> SUSFS kernel patch -> KernelSU-side patch -> msm_gem_fault fix)
DBY_TARBALL=./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz scripts/fetch_sources.sh

# 2.3 boot template: dump the 96 MiB stock boot partition from the device
scripts/dump_boot_template.sh

#     or install a boot.img you backed up yourself (it is validated first)
scripts/dump_boot_template.sh /path/to/boot_stock_device.img
scripts/dump_boot_template.sh --from /path/to/boot_stock_device.img   # same
```

`dump_boot_template.sh` writes the template to `artifacts/boot_stock_device.img`.
When packing, only the kernel is replaced; ramdisk, DTB, cmdline and the AVB
footer come from that file. A self-made backup (`dd`, fastboot, TWRP or any full
partition dump) is checked before it is installed: `ANDROID!` magic, header v2,
4096-byte pages, gzip kernel, non-empty ramdisk/DTB, and an AVB footer whose
recorded size matches the payload. Anything missing aborts without writing a
template that would produce an unbootable image. A size other than 96 MiB only
warns (the built images then have that same size).

`fetch_sources.sh` is idempotent: once patched it drops a marker at
`src/kernel/.dby_prepared` and then verifies by content that the tree really was
patched exactly once (`fs/susfs.c`, `fs/susfs_prctl.c` and
`include/linux/susfs.h` exist, `fs/namespace.c` has a single
`DEFINE_IDA(susfs_mnt_id_ida)`, no `*.rej` files). If that holds it skips the
work, so re-running is a no-op.

**Recovering a broken source tree.** If the script was interrupted, the sources
were edited by hand, or an older version of the script patched an already
patched tree (symptoms: `*.rej` files, `DEFINE_IDA` twice, `susfs_def.h`
duplicated), it stops and tells you to run:

```sh
scripts/fetch_sources.sh --force
```

`--force` deletes `src/kernel`, re-extracts the tarball (~1.5 GB, a few
minutes) and runs every step again. Build output in `out/`, `artifacts/` and
`output/` is left alone, and the extraction scratch directory lives in
`.cache/`, not `/tmp`.

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

## 3. Building

### 3.1 On the host

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

### 3.2 With Docker (the host does not have to be Ubuntu 22.04)

The host only does the two things that involve the device or a big file; the
extraction, patching, compiling and packing all happen in the container:

| Step | Where | Notes |
|---|---|---|
| Download the Huawei tarball (554 MB) | host | repo root, or any path via `-t` |
| Dump / provide the boot template | host | `adb` (`dump_boot_template.sh`) or a `boot.img` you backed up |
| Extract the sources, clone KernelSU, apply every patch | container | `scripts/fetch_sources.sh` |
| Configure the 5 variants, compile, pack, verify | container | `make images` |
| Output | host | written straight into `out/ artifacts/ output/`, owned by you |

First time:

```sh
scripts/dump_boot_template.sh                 # or: dump_boot_template.sh /path/to/boot.img

docker/run.sh     # builds the image first (apt packages + pinned toolchain, ~1 GB)
                  # then `make images`; `make bootstrap` first when src/kernel is missing
```

The image is `ubuntu:22.04` with the pinned clang 11.1.0-6 + binutils 2.38 in
`/opt/dby-toolchain`. **The host's `toolchain/` is not used**, so any host with
docker works (no clang/binutils to install) and the build needs no network
(except the KernelSU clone on the first run).

Everyday commands:

```sh
docker/run.sh make ksu-susfs        # one variant (both modes)
docker/run.sh make check            # verify existing images
docker/run.sh -j 24                 # parallel jobs (default: host nproc)
docker/run.sh -t ~/Downloads/DBY-W09_HarmonyOS4.0.0_opensource.tar.gz
docker/run.sh --shell               # shell inside the container: . scripts/env.sh, then make
docker/run.sh --build               # rebuild the image after changing the Dockerfile
docker/run.sh --build-only          # only build the image
make docker                         # same as docker/run.sh
```

Details:

- The container runs as your uid/gid (`--user`), so `out/` and `artifacts/` do
  not end up owned by root;
- the repo is mounted at `/work`, so paths inside the container match the host
  and the scripts need no changes;
- extra `docker run` arguments go through `DBY_DOCKER_ARGS`, e.g.
  `DBY_DOCKER_ARGS='--network host'`, or `--security-opt label=disable` on
  Fedora/SELinux hosts;
- slow apt/deb downloads: `DBY_APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
  DBY_UBUNTU_ARCHIVE=https://mirrors.tuna.tsinghua.edu.cn/ubuntu docker/run.sh --build`;
- arm64 host (Apple silicon): `DBY_PLATFORM=linux/amd64` (qemu emulation, very
  slow, only useful to validate the flow);
- offline / restricted network: `KSU_DIR=./KSU` (KernelSU tree inside the repo)
  or `KSU_TARBALL=./KernelSU-<commit>.tar.gz`; only paths inside the repo are
  visible in the container;
- disk: the image is about 1 GB, the build trees still live in the host's
  `out/` (about 5 GB per variant).

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
| `src/kernel looks partially patched but has no valid marker` | The tree is half patched (happens when an older version of the script patched it twice); recover with `scripts/fetch_sources.sh --force` |
| Patching prints `*.rej` / `Hunk #N FAILED` | The tree is not pristine; rebuild with `--force`. The script dry-runs each patch first, so a failure no longer leaves a half-patched tree |
| `fetch_toolchain.sh` ends with `libclang-cpp.so.11: cannot open shared object file` | The unpacked clang keeps its runtime libraries in `toolchain/root/usr/lib/x86_64-linux-gnu`, so it needs `LD_LIBRARY_PATH`; the script now sets it, and you need `. scripts/env.sh` when calling clang by hand |
| `. scripts/env.sh` still leaves `clang: command not found` | Older `env.sh` derived the repo root from `$0`, which is the calling shell when sourced; it now uses `BASH_SOURCE`. Update the checkout |
| Build fails on `lcd_kit_dpd.h` | `scripts/patch_source.py` was not run (it generates the stub) |
| Link fails with an RTIC relocation overflow | The `.bss.rtic` fold from `scripts/patch_source.py` is missing, or `RELOCATABLE` was not disabled |
| The device reboots as soon as the Anland desktop connects | NULL dereference in Huawei's `msm_gem_fault` on imported dma-bufs; make sure `scripts/patch_msm_fault.py` was applied |
| After Anland connects, deniald reports missing `EGL_ANDROID_native_fence_sync` | Mesa in the container selected llvmpipe (no Adreno/kgsl or virgl); this is a userspace GPU configuration issue, not the kernel |
| `permission denied while trying to connect to the Docker daemon socket` | Your user is not in the `docker` group: `sudo usermod -aG docker $USER`, then log in again |
| `out/` and `artifacts/` are owned by root after a container build | A plain `sudo docker run` was used; `sudo chown -R $USER:$USER out artifacts output`. `docker/run.sh` passes `--user $(id -u):$(id -g)` for you |
| `docker build` stalls in `apt-get` or while downloading the debs | Use a mirror: `DBY_APT_MIRROR=mirrors.tuna.tsinghua.edu.cn DBY_UBUNTU_ARCHIVE=https://mirrors.tuna.tsinghua.edu.cn/ubuntu docker/run.sh --build` |
| Cloning KernelSU fails inside the container | Put a KernelSU tree in the repo and use `KSU_DIR=./KSU docker/run.sh` (or `KSU_TARBALL=./xxx.tar.gz`) |
| The container reports `no toolchain at /opt/dby-toolchain` | The image was not built from this project's `docker/Dockerfile` (check `DBY_DOCKER_IMAGE`) |
| On Fedora/SELinux the container cannot read `/work` | `DBY_DOCKER_ARGS='--security-opt label=disable' docker/run.sh ...` |

---

## 9. Reproducibility notes

- Toolchain, base config, source patches and variant switches are all pinned
  and replayable; each variant's final `.config` is saved to
  `out/images/<variant>.config`.
- Docker builds use the same pinned clang/binutils, and the `Image` is produced
  by those only (the host gcc compiles host tools), so a container build and a
  host build differ only in the UTS version string (build time), just like two
  host builds do.
- `KBUILD_BUILD_TIMESTAMP` is not fixed, so rebuilding the same source does not
  produce byte-identical images (the build time is embedded in the kernel
  version string). Functionally they are equivalent.
- Key patch snapshots: `patches/susfs-kernel.diff`,
  `patches/susfs-kernel-fixes.diff`, `patches/ksu-susfs.diff`. The two
  permissive flavours are applied at build time by
  `scripts/patch_permissive.py` (`force` / `delay`, see section 5).
