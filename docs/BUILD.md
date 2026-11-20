# 构建 boot 镜像的方法

**简体中文** | [English](BUILD.en.md)

面向 Huawei MatePad 11（DBY-W09，kona/SM8250，HarmonyOS 4.3 内核 4.19.157-perf）。
全部步骤都已脚本化，最终产物是 5 种功能组合 × enforcing/permissive = 10 个
`boot_<variant>_<mode>.img`。

---

## 1. 前提

| 依赖 | 说明 |
|---|---|
| 源码 | `DBY-W09_HarmonyOS4.0.0_opensource.tar.gz`（华为开源包，内核 4.19.157） |
| 工具链 | `toolchain/`：Ubuntu clang 11.1.0-6 + binutils 2.38（`dpkg-deb -x` 解包，见 `scripts/env.sh`） |
| 模板 | `artifacts/boot_stock_device.img`（设备 stock boot 分区 96 MiB 备份，提供 ramdisk/DTB/cmdline/AVB footer） |
| 主机 | Linux x86_64，16 线程约 7–9 分钟/变体；磁盘约 5 GB/变体构建树 |

工具链版本不是随便选的：要和现机内核一致（`Ubuntu clang version 11.1.0-6`，
`GNU ld (GNU Binutils for Ubuntu) 2.38`），否则华为老代码/RTIC 段容易出问题。

```sh
. scripts/env.sh          # PATH / LD_LIBRARY_PATH / ARCH / CROSS_COMPILE
```

---

## 2. 一次性准备源码（脚本幂等，可重复执行）

```sh
# 2.1 工具链：下载并解包 Ubuntu clang 11.1.0-6 + binutils 2.38 到 toolchain/root
scripts/fetch_toolchain.sh

# 2.2 内核源码 + KernelSU + 全部补丁
#     （解包官方 tar → clone 钉住的 KernelSU → 接线 → patch_source →
#      SUSFS 内核补丁 → KernelSU 侧补丁 → msm_gem_fault 修复）
DBY_TARBALL=./DBY-W09_HarmonyOS4.0.0_opensource.tar.gz scripts/fetch_sources.sh

# 2.3 boot 模板：从设备 dump 96 MiB 原厂 boot 分区
scripts/dump_boot_template.sh

#     或者用你手动备份出来的 boot.img（会先校验再装成模板）
scripts/dump_boot_template.sh /path/to/boot_stock_device.img
scripts/dump_boot_template.sh --from /path/to/boot_stock_device.img   # 同上
```

`dump_boot_template.sh` 装出来的模板就是 `artifacts/boot_stock_device.img`，打包时只替换
内核，ramdisk / DTB / cmdline / AVB footer 都取自它。手动备份的文件（`dd`、fastboot、
TWRP、整分区备份都行）在安装前会检查：`ANDROID!` 头、header v2、4096 字节页、gzip 内核、
非空 ramdisk/DTB、末尾 AVB footer 且 footer 记录的长度与分段一致；缺一样就报错退出，
不会写出一张刷不进去的镜像。文件大小不是 96 MiB 时只警告（镜像会跟着变成同样大小）。

`fetch_sources.sh` 是幂等的：打完补丁会在 `src/kernel/.dby_prepared` 留标记，并用
内容检查确认源码确实"只打了一遍"（`fs/susfs.c`/`fs/susfs_prctl.c`/`include/linux/susfs.h`
都在、`fs/namespace.c` 里只有一个 `DEFINE_IDA(susfs_mnt_id_ida)`、没有 `*.rej`），
满足就直接跳过，重复执行是空操作。

**源码树打坏了怎么恢复。** 如果中途 Ctrl-C、手工改过源码，或者旧版本脚本在已打补丁的
树上又打了一遍（症状：出现 `*.rej`、`DEFINE_IDA` 两次、`susfs_def.h` 内容整体重复），
脚本会停下并提示：

```sh
scripts/fetch_sources.sh --force
```

`--force` 会删掉 `src/kernel`、从 tar 重新解包（约 1.5 GB，几分钟）再走完下面全部步骤；
`out/`、`artifacts/`、`output/` 里的构建产物不受影响。解包临时目录放在 `.cache/`，
不会占 `/tmp`。

`fetch_sources.sh` 等价于手工执行下面这些步骤，用来对照/排错：

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

`scripts/patch_msm_fault.py`：
华为 `techpack/display/msm/msm_gem.c` 对导入的 dma-buf 不建页数组，
`msm_gem_fault()` 直接解引用 NULL → 容器里 Mesa/llvmpipe mmap Anland 的
dma-buf 时 oops → 重启。补丁在 fault 时用 sg 表补页数组，并在拿不到页时返回
`VM_FAULT_SIGBUS`，不会再崩内核。

`scripts/patch_source.py` 做的事（详见 README 表格）：`mkcompile_h` 取 `head -n1`、
qcacld 用 `$(srctree)`、放开 `KPROBES/KRETPROBES` 的 `HUAWEI_KERNEL_DEBUG` 依赖、
去掉 5 个 5.x 回移的 `-Werror=`、`.bss.rtic` 并入主 `.bss`、补 `lcd_kit_dpd.h` stub。

---

## 3. 一条命令构建全部 10 个镜像

```sh
make images      # 5 变体 × 2 模式，串行；结束后自动生成 output/ 和清单
```

也可以只构建一组（两种模式）：

```sh
make ksu-susfs
make ksu
```

`make images` 内部对每个变体调用 `scripts/build_variant.sh <variant>`，它做四件事：

1. `scripts/configure.sh out/<variant> <variant>`：以 `configs/running.config`
   （设备 `/proc/config.gz`）为起点，用 `scripts/config` 打开/关闭该变体的选项，
   再 `olddefconfig`；
2. 编 enforcing 版：`scripts/build.sh out/<variant> Image.gz`；
3. `scripts/patch_permissive.py` 打上 permissive 补丁，增量重编 + 链接；
4. `scripts/pack_boot.py` 用 stock 镜像做模板换内核，`scripts/verify_boot.py` 校验，
   产物写 `artifacts/boot_<variant>_<mode>.img`。

耗时：单变体首次全量 7–9 分钟（16 线程），permissive 增量 1–2 分钟。

---

## 4. 变体与开关

| 变体 | root | SUSFS | 容器 | permissive 方式 |
|---|---|---|---|---|
| `noroot` | – | – | – | 开机即 permissive |
| `ksu` | ✓ | – | – | 开机即 permissive |
| `ksu-susfs` | ✓ | 完整（含 `SUS_MOUNT`/自动隐藏） | – | 开机即 permissive |
| `ksu-droidspaces` | ✓ | – | ✓ | 第 20 秒翻转 |
| `ksu-droidspaces-susfs` | ✓ | 部分（不含 `SUS_MOUNT`） | ✓ | 第 20 秒翻转 |

容器变体额外打开的选项（`scripts/configure.sh` 里的列表）：
`SYSVIPC`、`DEVTMPFS`、`CGROUP_DEVICE`、`CGROUP_PIDS`、`CFS_BANDWIDTH`、
`CGROUP_NET_PRIO`、`NETFILTER_XT_MATCH_ADDRTYPE`、`BRIDGE_NETFILTER`、`MACVLAN`、
`IP6_NF_NAT(+MASQUERADE)`、`BINFMT_MISC`、`NETFILTER_XT_TARGET_TCPMSS`、
`NF_CONNTRACK_NETLINK`、`NF_NAT_REDIRECT`、`IP_ADVANCED_ROUTER`、
`IP_MULTIPLE_TABLES`，并关闭 `ANDROID_PARANOID_NETWORK`。

所有变体统一关闭 `RELOCATABLE` / `RANDOMIZE_BASE`（华为 RTIC 段不可重定位，
必须按链接地址运行），并打开 `KPROBES/KRETPROBES`（KSU 需要）。

---

## 5. permissive 是怎么做的（重要）

cmdline 的 `enforcing=0`、`androidboot.selinux=permissive` 在这台机器上都没用
（`CONFIG_SECURITY_SELINUX_BOOTPARAM=n`；user build 的 init 一定 `setenforce(1)`），
所以 permissive 只能编进内核。`scripts/patch_permissive.py` 有两个模式：

| 模式 | 做法 | 用在哪 |
|---|---|---|
| `force` | `security.h` 里 `enforcing_enabled()` 恒返回 false（`setenforce 0` 立即生效、`getenforce` 立即 Permissive） | 变体 1/2/3 |
| `delay` | `selinux_init()` 里安排一个 delayed work，`dby_perm_delay` 秒后 `enforcing_set(false)`；同时打印 `SELinux: DBY_FORCE_PERMISSIVE flip -> permissive` | 变体 4/5（默认 20 秒）|

为什么容器变体不能 0 秒：早期 permissive 与那批容器选项组合会让 init 卡住，
华为 bootfail 在约 2 分钟后把设备送进 fastboot；20 秒（init 第一阶段结束后）
就完全正常。这就是变体 4/5 默认 20 秒的原因。

改延迟/机制（编译期，改 cmdline 无效）：

```sh
PERM_DELAY=30 make ksu-droidspaces        # 容器变体 30 秒翻转
PERM_MODE=force make ksu-droidspaces      # 强行 0 秒（会 bootfail，仅调试）
PERM_MODE=delay PERM_DELAY=60 make ksu    # 非容器变体也改成延迟
```

---

## 6. 产物、校验与输出目录

```
artifacts/boot_<variant>_<mode>.img      # 构建产物（96 MiB，header v2）
artifacts/IMAGES.sha256                  # 10 个镜像的 sha256（生成物，不入库）
output/                                  # 整理好的交付目录
output/boot_<variant>_<mode>.img         # 10 个镜像的副本
output/SHA256SUMS                        # 交付目录自己的校验清单
output/README.md                         # 刷机速查
```

```sh
make check       # 逐个对比模板：只有 kernel 不同，ramdisk/DTB/cmdline/os_version 不变
make manifest    # 重新生成 artifacts/IMAGES.sha256（生成物，不入库）
make dist        # 把 artifacts 里的 10 个镜像整理到 output/ 并生成 SHA256SUMS
make list        # 打印变体矩阵
```

`make check` 的判据来自 `scripts/verify_boot.py`：解析 boot header v2，
逐段比较 kernel/ramdisk/dtb/cmdline/os_version，并检查 AVB footer 还在。

---

## 7. 刷入与回滚

```sh
# 设备能进系统且已 root（KSU）：adb + dd，只写 boot 分区
adb push output/boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# 设备进不了系统：fastboot（音量下 + 插 USB 进 fastboot）
fastboot flash boot output/boot_<variant>_<mode>.img
fastboot reboot
```

自动化辅助（会自己选 adb/fastboot 通道并采样 `getenforce` 时间线）：

```sh
scripts/test_image.sh output/boot_ksu-droidspaces_permissive.img
```

回滚：刷回你自己备份的 boot 镜像（原厂或任一已知可用版本）。模板文件
`artifacts/boot_stock_device.img` 就是原厂 boot，也可以直接刷回。本工程从不写
`ramdisk`/`dtbo`/`vbmeta`/`userdata`。

---

## 8. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 刷完循环重启、最后进 fastboot | 镜像内核在这台机器上没走通早期引导（如 0 秒 permissive + 容器选项）。刷回你备份的 boot 镜像，再按 §5 换机制 |
| `getenforce` 一直是 Enforcing | 变体 4/5 是第 20 秒才翻转；确认 `dmesg \| grep DBY_FORCE_PERMISSIVE` 有没有 `flip -> permissive` |
| 改了 `dby_perm_delay=NN` 没生效 | 该 module param 在这台机上 cmdline 不生效（已知问题），请用 `PERM_DELAY=NN` 重编 |
| `SUS_MOUNT` 与 DroidSpaces 冲突 | 用变体 5（容器 + SUSFS，`SUS_MOUNT` 关闭）而不是变体 3 |
| `ksu_susfs` 报 Requires susfs v1.5.3+ | 用户态要用 `prctl(0xDEADBEEF, ...)` 的版本；本内核是 SUSFS 1.5.5 + 该 prctl 分发器 |
| `fetch_sources.sh` 在 clone KernelSU 时失败 | 网络受限；可 `KSU_URL=<镜像> scripts/fetch_sources.sh`，或 `KSU_TARBALL=<tar.gz>` / `KSU_DIR=<本地 KernelSU 目录>` |
| 提示 `src/kernel looks partially patched but has no valid marker` | 源码树是半打补丁状态（旧版脚本重复打补丁会这样）；`scripts/fetch_sources.sh --force` 重新解包重打 |
| 打补丁时出现 `*.rej` / `Hunk #N FAILED` | 源码树不干净；同样用 `--force` 重建，脚本会先 `--dry-run` 再真正打，失败时不会留下半成品 |
| `fetch_toolchain.sh` 最后报 `libclang-cpp.so.11: cannot open shared object file` | 解包出来的 clang 把运行库放在 `toolchain/root/usr/lib/x86_64-linux-gnu`，不设 `LD_LIBRARY_PATH` 起不来；脚本现在会自己设，手动调用 clang 时先 `. scripts/env.sh` |
| `. scripts/env.sh` 之后还是 `clang: command not found` | 老版本 `env.sh` 用 `$0` 推仓库根目录，被 source 时会算到仓库的上一级；已改用 `BASH_SOURCE`，更新仓库即可 |
| 构建报 `lcd_kit_dpd.h` 找不到 | 没跑 `scripts/patch_source.py`（会生成 stub） |
| 链接报 RTIC 重定位溢出 | 没跑 `scripts/patch_source.py` 的 `.bss.rtic` 合并，或没关 `RELOCATABLE` |
| 容器里 Anland 桌面一连上就重启 | 华为 msm 驱动 `msm_gem_fault` 对导入 dma-buf 的空指针；确认跑过 `scripts/patch_msm_fault.py` |
| Anland 连上后 deniald 报 `EGL_ANDROID_native_fence_sync` 缺失 | 容器里 Mesa 用了 llvmpipe（没走 Adreno/kgsl 或 virgl），是用户态 GPU 配置问题，不是内核 |

---

## 9. 复现性说明

- 工具链、起点 config、源码补丁、变体开关全部钉死并可重放；
  每个变体的最终 `.config` 存在 `out/images/<variant>.config`。
- `KBUILD_BUILD_TIMESTAMP` 未固定，所以同一源码重复构建的镜像不会逐字节相同
  （内核版本串里带编译时间）；功能等价。
- 关键补丁快照：`patches/susfs-kernel.diff`、`patches/susfs-kernel-fixes.diff`、
  `patches/ksu-susfs.diff`；permissive 的两种改法由 `scripts/patch_permissive.py`
  在构建时施加（`force` / `delay`，见 §5）。
