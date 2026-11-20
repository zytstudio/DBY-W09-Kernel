# DBY-W09 kernel build (MatePad 11 2021 / HarmonyOS 4)

**English** | [简体中文](README.md)

A build tree for the Linux 4.19.157 kernel of the Huawei MatePad 11 (2021,
DBY-W09, Snapdragon 865 / kona), based on Huawei's official open-source
release. It produces **10 boot images**:

- 5 feature sets: no root / KernelSU / KernelSU+SUSFS /
  KernelSU+Docker (DroidSpaces) / KernelSU+Docker+SUSFS;
- each set comes in **enforcing** and **permissive** SELinux flavours.

KernelSU is [backslashxx/KernelSU](https://github.com/backslashxx/KernelSU)
pinned at `b1365d09` (v3.3.1 / UAPI 5), SUSFS is 1.5.5, and all the
cgroup/netfilter/macvlan options Docker and DroidSpaces need are enabled.

## What is in the repository

| Path | Contents |
|---|---|
| `scripts/` | fetch sources/toolchain, patch, configure, build, pack, verify, flash |
| `patches/` | SUSFS kernel patch, KernelSU-side patch, reproducible snapshots |
| `configs/running.config` | the device's stock `/proc/config.gz`, the base for every variant |
| `Makefile` | `make images` and friends |
| `docs/` | build guide (`BUILD.md`, English version in `BUILD.en.md`) |
| `output/` | sha256 list and flashing cheat-sheet (the images themselves live in Releases) |
| `SOURCE-MANIFEST.md` | pinned versions, commits and sha256 for every component |

**Not in the repository** (because of size): the kernel source (official
tarball, 554 MB), the cross toolchain (200 MB+), and the 10 boot images
(96 MiB each). The first two are fetched by scripts; the images come from
Releases or from your own build.

## Quick start

```sh
git clone <this repo> && cd dby-w09-kernel

# 1) cross toolchain: Ubuntu clang 11.1.0-6 + binutils 2.38, unpacked into toolchain/root
scripts/fetch_toolchain.sh

# 2) kernel source: download DBY-W09_HarmonyOS4.0.0_opensource.tar.gz from
#    Huawei's open-source page into the repo root (or use DBY_TARBALL=/path/to/tar.gz)
DBY_TARBALL=./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz scripts/fetch_sources.sh

# 3) boot template: dump the 96 MiB stock boot partition from a device that still
#    has it
scripts/dump_boot_template.sh

#    already have your own boot.img backup? install it as the template (validated)
scripts/dump_boot_template.sh /path/to/boot_stock_device.img

# 4) build all 10 images (16 threads, about 40 minutes)
make images
```

The results land in `output/`: `boot_<variant>_<mode>.img` plus `SHA256SUMS`
(intermediate files stay in `artifacts/`).

`fetch_sources.sh` leaves a marker in `src/kernel` and verifies the tree by
content, so re-running it is a no-op. If the tree gets corrupted (leftover
`*.rej`, patches applied twice), re-extract and re-patch it in one go:

```sh
scripts/fetch_sources.sh --force     # delete src/kernel, re-extract the tarball, run every step
```

Build a single set:

```sh
make ksu-susfs     # enforcing + permissive for that variant
make check         # verify image structure (only the kernel differs from the template)
make list          # print the variant matrix
```

Requirements: Linux x86_64, 16 threads (8 GB RAM or more), about 5 GB of build
space per variant, `python3`, `patch`, `dpkg-deb`, `git`, `curl`.

## Variants

| # | Variant | root | SUSFS | Docker/DroidSpaces | permissive behaviour |
|---|---------|------|-------|--------------------|----------------------|
| 1 | `noroot` | – | – | – | permissive from boot |
| 2 | `ksu` | ✓ | – | – | permissive from boot |
| 3 | `ksu-susfs` | ✓ | full (incl. `SUS_MOUNT`) | – | permissive from boot |
| 4 | `ksu-droidspaces` | ✓ | – | ✓ | flips to permissive at 20 s |
| 5 | `ksu-droidspaces-susfs` | ✓ | partial (no `SUS_MOUNT`) | ✓ | flips to permissive at 20 s |

Why two kinds of permissive: this HarmonyOS user build requires SELinux to be
enforcing during early boot (`enforcing=0` and `androidboot.selinux=permissive`
are both ineffective), and permissive from second 0 makes the container-enabled
configurations enter Huawei's bootfail loop. Configurations without container
options can be permissive from boot. The delay is set at compile time with
`dby_perm_delay` (`PERM_DELAY=NN`); see `docs/BUILD.md` section 5.

## Flashing

```sh
adb push output/boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb reboot
# if the device cannot boot: fastboot flash boot output/boot_<variant>_<mode>.img
scripts/test_image.sh output/boot_ksu_permissive.img   # flashes and samples getenforce
```

Only the `boot` partition is written (slotless, 96 MiB); `ramdisk`, `dtbo`,
`vbmeta` and `userdata` are never touched. Flashing is risky - back up the
stock boot image first.

## Documentation

- [`docs/BUILD.en.md`](docs/BUILD.en.md) - the complete flow: extract, patch,
  configure, build, pack, flash and troubleshoot

## License

Scripts, patches and documentation: GPL-2.0 (see [`LICENSE`](LICENSE)). The
kernel source, KernelSU and SUSFS keep their upstream GPL-2.0 licenses; see
[`NOTICE`](NOTICE) and [`SOURCE-MANIFEST.md`](SOURCE-MANIFEST.md).

This project is not affiliated with Huawei, KernelSU, SUSFS or Droidspaces.
Flash at your own risk.
