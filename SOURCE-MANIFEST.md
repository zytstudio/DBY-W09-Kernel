# Sources, versions and checksums

Everything the build pins, and where it comes from. Keep this file in sync when
bumping a component.

## Kernel source

| Item | Value |
|---|---|
| Archive | `DBY-W09_HarmonyOS4.0.0_opensource.tar.gz` |
| Size | 554 MB (580,000,000 bytes) |
| sha256 | `52c38060cf2990e44bbc556f39271f6e97af90777a300165443946aa97c72e5f` |
| Path inside | `Code_Opensource/kernel` → `src/kernel` |
| Version | Linux 4.19.157-perf (Huawei DBY-W09 / HarmonyOS 4.3.0.196) |
| License | GPL-2.0 (see `LICENSE`) |

Not redistributed here because of its size. Download it from Huawei's
open-source release page for the DBY-W09 (HarmonyOS 4.0.0 kernel source), then:

```sh
scripts/fetch_sources.sh          # or: DBY_TARBALL=/path/to/tarball scripts/fetch_sources.sh
```

## KernelSU

| Item | Value |
|---|---|
| Repository | https://github.com/backslashxx/KernelSU |
| Commit | `b1365d093208a4ab37a6045f0ab0d89977fad637` |
| Tag | `v3.3.1` (`KernelSU v3.3.1+`, UAPI 5) |
| License | GPL-2.0 |

Manager app used for testing: `KernelSU_v3.3.1_32680-release.apk` (official
signature). The kernel only accepts a manager whose UAPI matches the in-tree
KernelSU.

## SUSFS

| Item | Value |
|---|---|
| Upstream | https://github.com/simonpunk/susfs4ksu |
| Branch | `kernel-4.19` |
| Version | 1.5.5 |
| In-tree form | `patches/susfs-kernel.diff` (kernel side) + `patches/ksu-susfs.diff` (KernelSU side) |

`susfs-kernel.diff` is applied with `patch -p1`; `ksu-susfs.diff` is a git diff
against the pinned KernelSU commit and is applied with `git apply`.

Additional local fixups carried by the patches:

| Patch | Why |
|---|---|
| `patches/susfs-kernel-fixes.diff` | `fs/namespace.c`/`susfs.h` declarations missing from the vendor 4.19 patch (SUS_MOUNT build) |
| `scripts/patch_permissive.py` | permissive-from-boot (`force`, variants 1–3) or a 20 s delayed flip (`delay`, variants 4–5); applied at build time, no patch file |

## Toolchain

| Package | Version | sha256 |
|---|---|---|
| `clang-11` | 11.1.0-6 | `3984af43028a64d5bac1fa7577c6e221a949a7c1695ab94a0c27de9356cbd4b7` |
| `libclang-common-11-dev` | 11.1.0-6 | `6d7112c58cb5faf520e7381024ed26cb3ae5d0205880647178a543a2e86be85a` |
| `libclang-cpp11` | 11.1.0-6 | `0bc7f4a7a8a525fae998222cf39589a4a957006e4537e3d4b828788c31acd93a` |
| `libllvm11` | 11.1.0-6 | `706483d52db1d89826719b0f9095de1c375b2d5a02526587618c4452e2b859c4` |
| `binutils-aarch64-linux-gnu` | 2.38-4ubuntu2.12 | `8b27d0c3811c025f76ee8683eb0c13bc57ec335fdfedc86d256c30c52a8b3982` |

`scripts/fetch_toolchain.sh` downloads these from `archive.ubuntu.com` and
unpacks them with `dpkg-deb -x` into `toolchain/root` (no root, no apt install).

Verified strings: `Ubuntu clang version 11.1.0-6` and
`GNU ld (GNU Binutils for Ubuntu) 2.38`.

## Boot image template

`artifacts/boot_stock_device.img` (96 MiB) is the stock boot partition dump used
by `scripts/pack_boot.py`. Not in git; dump it once with
`scripts/dump_boot_template.sh`.

| Item | Value |
|---|---|
| sha256 | `8ce0842bb35ab36431f68f6ea17693b894c5af5bc6d895dcfeb6a9ea736b57f7` |
| Layout | header v2, page 4096; kernel.gz + ramdisk (519,235 B) + DTB (1,664,243 B); vbmeta + AVB footer |

## Released boot images (not in git)

Ten images, 96 MiB each, are published as GitHub Releases (or the `output/`
folder locally). Their hashes are in `output/SHA256SUMS`.

| Variant | enforcing | permissive |
|---|---|---|
| `noroot` | sha256 in `output/SHA256SUMS` | 同上 |
| `ksu` | 同上 | 同上 |
| `ksu-susfs` | 同上 | 同上 |
| `ksu-droidspaces` | 同上 | 同上 |
| `ksu-droidspaces-susfs` | 同上 | 同上 |

## Device under test

Huawei MatePad 11 (2021), model DBY-W09, Snapdragon 865 (kona/SM8250),
HarmonyOS 4.3.0.196 (Android 12), vendor kernel 4.19.157-perf, bootloader
unlocked, slotless 96 MiB boot partition, AVB not enforced.
