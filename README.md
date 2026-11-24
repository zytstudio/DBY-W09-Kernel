# DBY-W09 内核构建（MatePad 11 2021 / HarmonyOS 4）

**简体中文** | [English](README.en.md)

华为 MatePad 11（2021，DBY-W09，骁龙 865 / kona）的 Linux 4.19.157 内核构建工程，
基于华为官方开源包，产出 **10 个 boot 镜像**：

- 5 种功能组合：无 root / KernelSU / KernelSU+SUSFS / KernelSU+Docker(DroidSpaces) /
  KernelSU+Docker+SUSFS；
- 每种组合再分 **enforcing** 和 **permissive** 两种 SELinux 模式。

KernelSU 用 [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) 的
`legacy` 分支（非 GKI，钉在 `e5f5ec9`，v3.4.0-legacy，manager 用
`KernelSU_Next_v3.4.1_33333-release.apk`），SUSFS 1.5.5，Docker/DroidSpaces 需要的
cgroup/netfilter/macvlan 选项全开。

## 仓库里有什么

| 目录 | 内容 |
|---|---|
| `scripts/` | 取源码/工具链、打补丁、配置、编译、打包、校验、刷机 |
| `docker/` | Dockerfile 与封装脚本：在容器里完成解包、编译、打包 |
| `patches/` | SUSFS 内核补丁、KernelSU 侧补丁、permissive 补丁（可复现的快照） |
| `configs/running.config` | 设备原厂 `/proc/config.gz`，所有变体的配置基线 |
| `Makefile` | `make images` 等入口 |
| `docs/` | 构建指南（`BUILD.md`，另有英文版 `BUILD.en.md`） |
| `output/` | 镜像的 sha256 清单 + 刷机速查（镜像本体走 Releases） |
| `SOURCE-MANIFEST.md` | 所有组件的版本、commit、sha256 |

**不在仓库里**（体积原因）：内核源码（官方 tar，554 MB）、交叉工具链（200 MB+）、
10 个 boot 镜像（每个 96 MiB）。前两者用脚本获取，镜像从 Releases 下载或用脚本构建。

## 快速开始

```sh
git clone https://github.com/zytstudio/DBY-W09-Kernel && cd DBY-W09-Kernel

# 1) 交叉工具链：Ubuntu clang 11.1.0-6 + binutils 2.38，解包到 toolchain/root
#    （用 Docker 构建可以跳过这一步，工具链在镜像里）
scripts/fetch_toolchain.sh

# 2) 内核源码：从华为开源页面下载 DBY-W09_HarmonyOS4.0.0_opensource.tar.gz
#    放到仓库根目录（或 DBY_TARBALL=/path/to/tar.gz），然后：
DBY_TARBALL=./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz scripts/fetch_sources.sh

# 3) boot 模板：从一台仍是原厂 boot 分区的设备 dump 96 MiB
scripts/dump_boot_template.sh

#    已经有手动备份的 boot.img 时，直接装进模板（脚本会先校验）
scripts/dump_boot_template.sh /path/to/boot_stock_device.img

# 4) 构建全部 10 个镜像（16 线程，约 40 分钟；Docker 用 make docker）
make images
```

产物在 `output/`：`boot_<variant>_<mode>.img` + `SHA256SUMS`（中间产物在 `artifacts/`）。

`fetch_sources.sh` 会在 `src/kernel` 留标记并做内容校验，所以重复执行是空操作；
如果源码树被打坏（残留 `.rej`、补丁被重复应用），直接重新解包重打：

```sh
scripts/fetch_sources.sh --force     # 删掉 src/kernel 从 tar 重新解包并走完全部步骤
```

只构建一组：

```sh
make ksu-susfs     # 该变体的 enforcing + permissive
make check         # 校验镜像结构（只有 kernel 与模板不同）
make list          # 打印变体矩阵
```

环境要求：Linux x86_64、16 线程（8 GB 内存起）、约 5 GB/变体构建空间、
`python3`、`patch`、`dpkg-deb`、`git`、`curl`。不想在主机装这些就用 Docker（见下）。

## Docker 构建

不想在主机装 clang/binutils：解包源码、clone KernelSU、打补丁、编译、打包都在容器里，
主机只负责下载 tar 包和备份 boot 分区。

```sh
docker/run.sh           # 首次自动构建镜像（约 1 GB），然后 make images
make docker             # 等价写法
docker/run.sh --shell   # 进容器排查，环境变量已就绪
```

镜像基于 Ubuntu 22.04，钉死的 clang 11.1.0-6 + binutils 2.38 装在 `/opt/dby-toolchain`
（不使用主机的 `toolchain/`），构建过程不需要联网（首次 clone KernelSU 除外）；容器以你的
uid 运行，产物直接写回 `out/ artifacts/ output/`。tar 包不在仓库里就用
`docker/run.sh -t /path/to/xxx.tar.gz`。详见 [`docs/BUILD.md`](docs/BUILD.md) §3.2。

## 变体

| # | 变体 | root | SUSFS | Docker/DroidSpaces | permissive 行为 |
|---|------|------|-------|--------------------|-----------------|
| 1 | `noroot` | – | – | – | 开机即 permissive |
| 2 | `ksu` | ✓ | – | – | 开机即 permissive |
| 3 | `ksu-susfs` | ✓ | 完整（含 `SUS_MOUNT`） | – | 开机即 permissive |
| 4 | `ksu-droidspaces` | ✓ | – | ✓ | 第 20 秒切 permissive |
| 5 | `ksu-droidspaces-susfs` | ✓ | 部分（无 `SUS_MOUNT`） | ✓ | 第 20 秒切 permissive |

permissive 为什么分两种：这台 HarmonyOS user build 的早期引导要求 SELinux
enforcing（`enforcing=0`/`androidboot.selinux=permissive` 都无效），0 秒 permissive
会让带容器选项的配置进 bootfail 循环；无容器配置可以开机即 permissive。
延迟用 `dby_perm_delay`（编译期，`PERM_DELAY=NN`）调整，详见 `docs/BUILD.md` §5。

## 刷入

```sh
adb push output/boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb reboot
# 进不了系统时：fastboot flash boot output/boot_<variant>_<mode>.img
scripts/test_image.sh output/boot_ksu_permissive.img   # 自动刷入并采样 getenforce
```

只写 `boot` 分区（slotless，96 MiB），不碰 `ramdisk`/`dtbo`/`vbmeta`/`userdata`。
刷机有风险，先备份原厂 boot。

## 文档

- [`docs/BUILD.md`](docs/BUILD.md) — 从解包、打补丁、配置、编译、打包到刷入和排错的完整步骤
- [`docs/BUILD.en.md`](docs/BUILD.en.md) — the same guide in English

## 许可

脚本、补丁与文档：GPL-2.0（见 [`LICENSE`](LICENSE)）。内核源码、KernelSU、SUSFS
分别遵循其上游 GPL-2.0 许可；详见 [`NOTICE`](NOTICE) 与
[`SOURCE-MANIFEST.md`](SOURCE-MANIFEST.md)。

本项目与华为、KernelSU、SUSFS、Droidspaces 等无隶属关系。刷机风险自负。
