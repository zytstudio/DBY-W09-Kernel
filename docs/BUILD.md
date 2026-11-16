# 构建 boot 镜像的方法

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

## 2. 一次性准备源码（已做过，脚本幂等，可重复执行）

```sh
# 2.1 解包
tar xzf DBY-W09_HarmonyOS4.0.0_opensource.tar.gz -C src Code_Opensource/kernel
mv src/Code_Opensource/kernel src/kernel

# 2.2 让华为源码能用 clang 11 编过（-Werror 回移、KPROBES 依赖、RTIC 段、lcd_kit stub…）
python3 scripts/patch_source.py

# 2.3 集成 KernelSU（backslashxx fork，钉在 c16b935d / v3.3.1+，UAPI 5）
cd src/kernel
bash KernelSU/kernel/setup.sh c16b935d07e13941774b6eeae1b1a0f8387f0960
cd -

# 2.4 把 SUSFS 1.5.5 接到内核 + KernelSU（幂等）
python3 scripts/apply_ksu_susfs.py

# 2.5 修华为 MSM 显示驱动对导入 dma-buf 的 mmap 空指针（容器 GPU 直通会踩到）
python3 scripts/patch_msm_fault.py
```

`scripts/patch_msm_fault.py`（见 [`M6-anland-crash.md`](M6-anland-crash.md)）：
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
就完全正常。详细证据见 `docs/M5-image-matrix.md`。

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
artifacts/IMAGES.sha256                  # 10 个镜像的 sha256
output/                                  # 整理好的交付目录
output/boot_<variant>_<mode>.img         # 10 个镜像的副本
output/SHA256SUMS                        # 交付目录自己的校验清单
output/README.md                         # 刷机速查
```

```sh
make check       # 逐个对比模板：只有 kernel 不同，ramdisk/DTB/cmdline/os_version 不变
make manifest    # 重新生成 artifacts/IMAGES.sha256
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

回滚镜像：`artifacts/boot_m4.img`（M4：KSU v3.3.1 + 容器 + SUSFS，enforcing）
或 `artifacts/boot_stock_device.img`（原厂）。本工程从不写
`ramdisk`/`dtbo`/`vbmeta`/`userdata`。

---

## 8. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 刷完循环重启、最后进 fastboot | 镜像内核在这台机器上没走通早期引导（如 0 秒 permissive + 容器选项）。用 `fastboot flash boot artifacts/boot_m4.img` 回滚，再按 §5 换机制 |
| `getenforce` 一直是 Enforcing | 变体 4/5 是第 20 秒才翻转；确认 `dmesg \| grep DBY_FORCE_PERMISSIVE` 有没有 `flip -> permissive` |
| 改了 `dby_perm_delay=NN` 没生效 | 该 module param 在这台机上 cmdline 不生效（已知问题），请用 `PERM_DELAY=NN` 重编 |
| `SUS_MOUNT` 与 DroidSpaces 冲突 | 用变体 5（容器 + SUSFS，`SUS_MOUNT` 关闭）而不是变体 3 |
| `ksu_susfs` 报 Requires susfs v1.5.3+ | 用户态要用 `prctl(0xDEADBEEF, ...)` 的版本；本内核是 SUSFS 1.5.5 + 该 prctl 分发器 |
| 构建报 `lcd_kit_dpd.h` 找不到 | 没跑 `scripts/patch_source.py`（会生成 stub） |
| 链接报 RTIC 重定位溢出 | 没跑 `scripts/patch_source.py` 的 `.bss.rtic` 合并，或没关 `RELOCATABLE` |
| 容器里 Anland 桌面一连上就重启 | 华为 msm 驱动 `msm_gem_fault` 空指针（见 `M6-anland-crash.md`），确认跑过 `scripts/patch_msm_fault.py` |
| Anland 连上后 deniald 报 `EGL_ANDROID_native_fence_sync` 缺失 | 容器里 Mesa 用了 llvmpipe（没走 Adreno/kgsl 或 virgl），是用户态 GPU 配置问题，不是内核 |

---

## 9. 复现性说明

- 工具链、起点 config、源码补丁、变体开关全部钉死并可重放；
  每个变体的最终 `.config` 存在 `out/images/<variant>.config`。
- `KBUILD_BUILD_TIMESTAMP` 未固定，所以同一源码重复构建的镜像不会逐字节相同
  （内核版本串里带编译时间）；功能等价。
- 关键补丁快照：`patches/susfs-kernel.diff`、`patches/susfs-kernel-fixes.diff`、
  `patches/ksu-susfs.diff`、`patches/selinux-permissive-force.diff`、
  `patches/selinux-permissive-delay.diff`。
