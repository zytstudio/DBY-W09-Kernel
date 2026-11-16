# M5 — 10 个 boot 镜像（5 种功能组合 × enforcing/permissive）

## 结论

- 一条命令构建全部 10 个镜像：`make images`（也可以 `make ksu-susfs` 只构建一组）。
- 每个镜像都从设备自己的 `configs/running.config` 出发，只用 `scripts/config`
  追加差异项；每个变体的最终 `.config` 会保存到 `out/images/<variant>.config`。
- **permissive 的机制按变体区分**（真机验证过的唯一稳定组合）：
  - 变体 1/2/3（无容器选项）：**开机即 permissive**，`getenforce` 从第一个
    用户态进程起就是 `Permissive`；
  - 变体 4/5（带 Docker/DroidSpaces 容器选项）：内核按 enforcing 启动，**第 20 秒**
    自己切到 permissive（`dby_perm_delay` 默认 20）。原因是这批容器选项里有某个
    早期引导路径依赖 enforcing，0 秒 permissive 会让 HarmonyOS 进入
    bootfail 循环并落到 fastboot；20 秒（`init` 第一阶段结束后）完全正常。
- 两种机制都写在同一份 `scripts/patch_permissive.py` 里（`force` / `delay`）。

## permissive 机制与闭源镜像对比

真机实测（DBY-W09，HarmonyOS 4.3.0.196，2026-11-16）：

| # | 方案 | 结果 |
|---|------|------|
| A | boot cmdline 加 `enforcing=0` | 无效：`CONFIG_SECURITY_SELINUX_BOOTPARAM=n`，参数根本没注册 |
| B | boot cmdline 加 `androidboot.selinux=permissive` | 无效：user build 的 init 仍然 `setenforce(1)`（该值只影响 init 自己的判断） |
| C | 源码强制 permissive，0 秒生效，无容器 | **正常**，adb 起来时已是 Permissive |
| D | 源码强制 permissive，0 秒生效，带容器选项 | **失败**：init 卡住 → 华为 bootfail → fastboot |
| E | 源码 permissive，延迟 20 秒（容器） | **正常**，21.47 s 打印 `flip -> permissive`，adb 起来时已 Permissive |
| F | 运行中的系统 `setenforce 0` | 正常，不重启 |

闭源包（`KSU/GKI/`）里的三个镜像，实测和哈希对比：

| 镜像 | sha256 前 16 位 | 行为 |
|---|---|---|
| `boot_susfs_v1.5.5_ksu_v339_permissive.img` | `8ce0842bb35ab364` | **与 `artifacts/boot_stock_device.img` 逐字节相同**（原厂 boot，没有 KernelSU、没有 permissive 代码）——发布包里这个文件是原厂镜像 |
| `boot_susfs_v1.5.5_ksu_v339_Enforcing.img` | `131d03a412bc8869` | 自编内核（21,889,501 B），进系统后 `Enforcing` |
| `boot_ksu_permissive_v0.9.5.img` | `eb752d72f971786e` | 自编内核（21,844,559 B，KSU v0.9.5），**开机即 Permissive**（uptime 27 s 时已是 Permissive，`ro.boot.selinux` 仍是 `enforce`） |

`boot_ksu_permissive_v0.9.5.img` 内嵌 config 是 7131 行，`CONFIG_SECURITY_SELINUX_BOOTPARAM`
同样是 `not set`、`DEVELOP=y`，cmdline 里也没有 `enforcing=0`，所以它也是**源码级**
permissive；差异在配置：它没有我们为 Docker/DroidSpaces 加的 17 个选项
（SYSVIPC、cgroup device/pids、netfilter/macvlan、BINFMT_MISC、关
`ANDROID_PARANOID_NETWORK` 等）。把同样的早期 permissive 放进带容器选项的配置，
就复现了 D 的 bootfail。因此最终产物：无容器变体早期 permissive，容器变体 20 秒翻转。

## 镜像矩阵

| # | 变体名 | root | SUSFS | 容器 | permissive 方式 |
|---|--------|------|-------|------|-----------------|
| 1 | `noroot` | – | – | – | 开机即 permissive |
| 2 | `ksu` | ✓ | – | – | 开机即 permissive |
| 3 | `ksu-susfs` | ✓ | 完整 | – | 开机即 permissive |
| 4 | `ksu-droidspaces` | ✓ | – | ✓ | 20 s 后切 permissive |
| 5 | `ksu-droidspaces-susfs` | ✓ | 部分 | ✓ | 20 s 后切 permissive |

变体 3 与 5 的 SUSFS 差异：

| 选项 | 3 `ksu-susfs` | 5 `ksu-droidspaces-susfs` |
|------|---------------|---------------------------|
| `KSU_SUSFS_SUS_MOUNT` | ✓ | – |
| `KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT` | ✓ | – |
| `KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT` | ✓ | – |
| `KSU_SUSFS_TRY_UMOUNT` | – | – |
| `SUS_PATH`/`SUS_KSTAT`/`SPOOF_UNAME`/`ENABLE_LOG`/`HIDE_SYMBOLS`/`SPOOF_CMDLINE`/`OPEN_REDIRECT` | ✓ | ✓ |

`TRY_UMOUNT` 需要 KernelSU 内部的 `try_umount()`（本 fork 没导出），两个变体都关闭。
`SUS_MOUNT` 与 DroidSpaces 的 bind mount 冲突，所以变体 5 关闭。

## 构建

```sh
make images            # 5 变体 × 2 模式，串行
make ksu-susfs         # 单个变体（两种模式）
make check             # 逐个校验镜像结构（ramdisk/DTB/cmdline 不变，仅 kernel 不同）
make list              # 打印矩阵
make distclean         # 删除 out/<variant> 构建目录（保留镜像）
```

首次全量编译单变体约 7–9 分钟（16 线程）；permissive 只改几个 selinux 文件，
增量重编 + 链接约 1–2 分钟。`PERM_MODE` / `PERM_DELAY` 环境变量可临时覆盖选择
（例如 `PERM_MODE=delay PERM_DELAY=30 make ksu-susfs`）。

## 目录/文件约定

| 路径 | 内容 |
|---|---|
| `out/<variant>/` | 内核构建树（`O=`） |
| `out/images/<variant>-<mode>.Image.gz` | 裸内核（调试用） |
| `out/images/<variant>.config` | 该变体最终 `.config` |
| `artifacts/boot_<variant>_<mode>.img` | 可刷入镜像（96 MiB，header v2） |
| `artifacts/IMAGES.sha256` | 10 个镜像的 sha256（`make manifest`） |

## 复现性

- 工具链钉死：`toolchain/`（Ubuntu clang 11.1.0-6 + binutils 2.38），
  `scripts/env.sh` 设置 PATH/LD_LIBRARY_PATH。
- 起点配置钉死：`configs/running.config`（设备 `/proc/config.gz`）。
- 所有源码改动都由幂等脚本施加：`scripts/patch_source.py`、`scripts/apply_ksu_susfs.py`、
  `scripts/patch_permissive.py`（mode: force / delay / compat / stealth）。
- 补丁快照：`patches/susfs-kernel.diff`、`patches/susfs-kernel-fixes.diff`、
  `patches/ksu-susfs.diff`、`patches/selinux-permissive-force.diff`（变体 1/2/3 用）、
  `patches/selinux-permissive-delay.diff`（变体 4/5 的 20 秒翻转）。
- 注意：内核版本字符串里带编译时间（`KBUILD_BUILD_TIMESTAMP` 未固定），
  同一源码重复构建的镜像不会逐字节相同；功能等价。

## 镜像清单（sha256）

```
790f61d2e870d27d0ee589a7bd385336e81fd3f20cf970d8302f9d58c31a5a6b  boot_noroot_enforcing.img
f010dd68e5ffad6a1eaf0abf355b36e4f90873c35cfd6241032d7317d0a79358  boot_noroot_permissive.img
dcae20bb63f713f50110edabee8cf7269ed009ef6e3a9e15b017ec9ff62c3a55  boot_ksu_enforcing.img
44b1afab661378721f76e503eb69f8fbb0f5a6187a7d41354004a46c259c9889  boot_ksu_permissive.img
17d6a5e8711b7a4caceffa9248076d1115b0b4e2dc1ec46847b9424c12a125d9  boot_ksu-susfs_enforcing.img
c4e3082f92c3df445b664863e5738d76a8976f5ba678bcf406523b57930d65e9  boot_ksu-susfs_permissive.img
ea980169ae71d0dbac49020194175ce11bde6659c30812d84141719156a79027  boot_ksu-droidspaces_enforcing.img
e2f84e54627a6e266f5f96e258d7b9d04ade1184c506ddb03455e26554b0846c  boot_ksu-droidspaces_permissive.img
f9e48d61d7febe2dd2ea73cc93542b7d12a69580dd50f1d7c4989ead361be12e  boot_ksu-droidspaces-susfs_enforcing.img
63b2a81aad6ebf6f5818ffda49bd8b929a4403f84394f492f9a207e05c9558eb  boot_ksu-droidspaces-susfs_permissive.img
```

## 上机验收（2026-11-16）

| 镜像 | 结果 |
|---|---|
| `boot_noroot_permissive.img` | 启动正常，adb 37 s 可用，**首次采样即 Permissive**；`which su` 无、无 KSU 目录 |
| `boot_ksu_permissive.img` | 启动正常，首个采样 Permissive，`su -c id` = `uid=0`（`u:r:ksu:s0`） |
| `boot_ksu-susfs_permissive.img` | 同上；`ksu_susfs show enabled_features` 列出 10 项（含 `SUS_MOUNT`） |
| `boot_ksu-droidspaces_permissive.img` | 启动正常，21.47 s 打印 `flip -> permissive`，adb 起来时 Permissive，root 正常 |
| `boot_ksu-droidspaces-susfs_permissive.img` | 启动正常，同上；`ksu_susfs show version` = `v1.5.5`，root 正常 |
| `boot_noroot_enforcing.img` | 启动正常，Enforcing，无 root |
| `boot_ksu-droidspaces-susfs_enforcing.img` | 启动正常，Enforcing，root + susfs 正常 |
| 闭源 `boot_ksu_permissive_v0.9.5.img` | 启动正常，uptime 27 s 即 Permissive（对照实验，已回刷） |

回滚：`artifacts/boot_m4.img`（M4）或 `artifacts/boot_stock_device.img`（原厂）。

## 刷入 / 回滚

```sh
# adb（设备已 root、能进系统时）
adb push artifacts/boot_<variant>_<mode>.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# fastboot（进不了系统时）
fastboot flash boot artifacts/boot_<variant>_<mode>.img
fastboot reboot
```

`scripts/test_image.sh <img>` 会自动选择 adb/fastboot 通道，刷完采样
`getenforce` 时间线，并打印 root 状态和 `DBY_FORCE_PERMISSIVE` 内核日志。

## 已知限制

- 容器变体（4/5）的 permissive 从第 20 秒开始；早期 permissive + 容器配置会触发
  HarmonyOS 的 bootfail 循环（闭源包里的 permissive 镜像是原厂镜像，无法对照出
  更早的做法）。
- `dby_perm_delay` 参数在真机上**改 cmdline 不生效**（`dby_perm_delay=20` 出现在
  `/proc/cmdline` 但 `/sys/module/selinux/parameters/dby_perm_delay` 仍是默认值），
  要改延迟目前得重编（`PERM_DELAY=NN`）。
- 变体 3/5 关闭 `TRY_UMOUNT`（KSU fork 未导出 `try_umount`）。
- 只构建 `Image.gz`，不构建 dtb；DTB 沿用 stock 模板（华为 `dtbs` 目标依赖私有
  `lcd_kit_parser.pl`）。
- 每次写 `boot` 分区前都需要人工确认；本工程从不写 `ramdisk`/`dtbo`/`vbmeta`/
  `userdata`。
