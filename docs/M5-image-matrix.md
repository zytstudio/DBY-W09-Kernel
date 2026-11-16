# M5 — 10 个 boot 镜像（5 种功能组合 × enforcing/permissive）

## 结论

- 一条命令构建全部 10 个镜像：`make images`（也可以 `make ksu-susfs` 只构建一组）。
- 每个镜像都从设备自己的 `configs/running.config` 出发，只用 `scripts/config`
  追加差异项；每个变体的最终 `.config` 会保存到 `out/images/<variant>.config`。
- **SELinux permissive 采用「延迟翻转」**：内核按 enforcing 正常启动，默认在
  开机 60 秒后由内核自己切到 permissive。原因见下一节——在这台 HarmonyOS
  user build 上，任何「开机即 permissive」的内核都会在 adb/ssh 起来之前循环重启。
- 延迟翻转默认值可用内核参数 `dby_perm_delay=<秒>` 覆盖（重打包时
  `--append-cmdline "dby_perm_delay=20"` 即可，无需重编）。

## 为什么不是「开机即 permissive」

以下都是在真机（DBY-W09，HarmonyOS 4.3.0.196）上实测的：

| # | 方案 | 结果 |
|---|------|------|
| A | boot cmdline 加 `enforcing=0` | 无效：`CONFIG_SECURITY_SELINUX_BOOTPARAM=n`，参数根本没注册（内核里 `#define selinux_enforcing_boot 1`） |
| B | boot cmdline 加 `androidboot.selinux=permissive` | 无效：user build 的 init 启动后仍然 `setenforce(1)` |
| C | 源码强制：`enforcing_enabled()` 恒 false | **循环重启**（Huawei logo 阶段，最后落进 fastboot） |
| D | 源码强制：`avc_denied()` 永不拒绝（对外仍报告 enforcing） | **仍然循环重启** |
| E | 运行中的系统 `setenforce 0` | **完全正常**，不重启，功能不受影响 |
| F | 延迟翻转（本方案） | **正常启动**，60 秒后变 Permissive |

C/D 说明问题不在「厂商检测 SELinux 状态」（D 对外仍报 enforcing 照样重启），
而是 HarmonyOS 的早期引导流程里有某一步依赖 enforcing 才能走通；E 说明
permissive 本身被系统接受。因此 F 是唯一既满足「可用的 permissive」又不破坏
早期引导的做法。

`dby_perm_delay` 是 `module_param`，`cat /sys/module/selinux/parameters/dby_perm_delay`
可读；也可以在启动后 `setenforce 1` 再切回强制模式。

## 镜像矩阵

| # | 变体名 | root | SUSFS | Docker/DroidSpaces | 说明 |
|---|--------|------|-------|--------------------|------|
| 1 | `noroot` | – | – | – | 纯自编内核：无 KernelSU、无 KPROBES、无容器选项 |
| 2 | `ksu` | ✓ | – | – | KernelSU v3.3.1 (uapi 5)，其余同 1 |
| 3 | `ksu-susfs` | ✓ | 完整 | – | 打开 `SUS_MOUNT` + `AUTO_ADD_SUS_*`（挂载隐藏），无容器选项 |
| 4 | `ksu-droidspaces` | ✓ | – | ✓ | SYSVIPC/cgroup devices+pids/devtmpfs/netfilter/macvlan… |
| 5 | `ksu-droidspaces-susfs` | ✓ | 部分 | ✓ | 容器选项 + SUSFS（`SUS_MOUNT` 关闭，与 DroidSpaces 的 bind mount 冲突） |

每个变体两种 SELinux 模式 → 10 个文件：

```
artifacts/boot_<variant>_enforcing.img
artifacts/boot_<variant>_permissive.img
```

变体 3 与 5 的差异（除了容器选项）：

| 选项 | 3 `ksu-susfs` | 5 `ksu-droidspaces-susfs` |
|------|---------------|---------------------------|
| `KSU_SUSFS_SUS_MOUNT` | ✓ | – |
| `KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT` | ✓ | – |
| `KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT` | ✓ | – |
| `KSU_SUSFS_TRY_UMOUNT` | – (见下) | – |
| `KSU_SUSFS_SUS_PATH` / `SUS_KSTAT` / `SPOOF_UNAME` / `ENABLE_LOG` / `HIDE_KSU_SUSFS_SYMBOLS` / `SPOOF_CMDLINE_OR_BOOTCONFIG` / `OPEN_REDIRECT` | ✓ | ✓ |

`TRY_UMOUNT` 需要 KernelSU 内部的 `try_umount()`（本 fork 没导出，
`susfs_try_umount_all()` 会变成空操作），因此两个变体都关闭；这也是变体 3
相对「理论全功能」唯一的缺口。

## 构建

```sh
make images            # 5 变体 × 2 模式，串行，产出 10 个镜像
make ksu-susfs         # 单个变体（两种模式）
make check             # 逐个校验镜像结构（ramdisk/DTB/cmdline 不变，仅 kernel 不同）
make list              # 打印矩阵说明
make distclean         # 删除 out/<variant> 构建目录（保留镜像）
```

耗时：单个变体首次全量编译约 10–20 分钟（16 线程），permissive 只是同一
`.config` 上加源码补丁，增量重编 + 链接约 1 分钟。

### 目录/文件约定

| 路径 | 内容 |
|---|---|
| `out/<variant>/` | 内核构建树（`O=`） |
| `out/images/<variant>-<mode>.Image.gz` | 裸内核（调试用） |
| `out/images/<variant>.config` | 该变体最终 `.config` |
| `artifacts/boot_<variant>_<mode>.img` | 可刷入镜像（96MiB，header v2） |
| `artifacts/IMAGES.sha256` | 10 个镜像的 sha256 |

## 复现性

- 工具链钉死：`toolchain/`（Ubuntu clang 11.1.0-6 + binutils 2.38），
  `scripts/env.sh` 设置 PATH/LD_LIBRARY_PATH。
- 起点配置钉死：`configs/running.config`（设备 `/proc/config.gz`）。
- 所有源码改动都由幂等脚本施加：`scripts/patch_source.py`（华为源码可编译化）、
  `scripts/apply_ksu_susfs.py`（KSU 侧接线）、`scripts/patch_permissive.py`
  （permissive 模式，可在 delay/compat/force/stealth 间切换）。
- 对应的补丁快照：`patches/susfs-kernel.diff`（kernel-4.19 SUSFS 1.5.5）、
  `patches/susfs-kernel-fixes.diff`（SUS_MOUNT 需要的 `namespace.c`/`susfs.h`
  声明）、`patches/ksu-susfs.diff`（KSU 侧接线 + `susfs_is_current_*_domain()`）、
  `patches/selinux-permissive.diff`（delay 模式本身）。
- `make images` 从零到镜像完全可重放；`.config` 与镜像哈希都在 `out/images`
  和 `artifacts/IMAGES.sha256` 里。
- 注意：内核版本字符串里带编译时间（`KBUILD_BUILD_TIMESTAMP` 未固定），
  所以**同一源码重复构建的镜像不会逐字节相同**；功能等价。

## 镜像清单（sha256）

```
35a57fa2…d0caed6  boot_noroot_enforcing.img
cb1aeb3d…ebf91cac boot_noroot_permissive.img
602d60c9…eea5e49b boot_ksu_enforcing.img
7d8af630…3f50515b boot_ksu_permissive.img
1a6e42db…60916843 boot_ksu-susfs_enforcing.img
571aac69…f1d3646d boot_ksu-susfs_permissive.img
50c75495…d9fb57   boot_ksu-droidspaces_enforcing.img
31b605b3…ad66a4   boot_ksu-droidspaces_permissive.img
31fc516e…a7a4d3   boot_ksu-droidspaces-susfs_enforcing.img
aa770bca…b3bb39   boot_ksu-droidspaces-susfs_permissive.img
```

完整值见 `artifacts/IMAGES.sha256`（`make manifest` 生成）。

每个内核里的 SELinux 标记（可离线校验，也可在设备上 `dmesg | grep DBY`）：

| 模式 | `flip -> permissive` 字符串 | 启动后行为 |
|---|---|---|
| enforcing | 不存在 | 始终 Enforcing |
| permissive | 存在 1 处 | 60 s 时打印 `flip -> permissive` 并转 Permissive |

## 上机验收（2026-11-16）

复测用的构建与最终产物只差两行已删除的调试 `pr_info`（见下「维护记录」），
逻辑相同。真机结果：

1. `boot_ksu-susfs_permissive.img`（旧构建 sha256 `a9b02e23…2ab254`）：
   - 启动正常（未落入 fastboot），adb 约 49 秒可用；
   - 49 s 时 `getenforce` = `Enforcing`，60.38 s 内核打印
     `SELinux: DBY_FORCE_PERMISSIVE flip -> permissive`，之后
     `getenforce` = `Permissive`、`/sys/fs/selinux/enforce` = `0`；
   - `su -c id` → `uid=0(root) context=u:r:ksu:s0`；
   - `ksu_susfs show version` → `susfs v1.5.5 (ABI: prctl)`；
   - `ksu_susfs show enabled_features` 列出
     `SUS_PATH / SUS_MOUNT / AUTO_ADD_SUS_KSU_DEFAULT_MOUNT /
     AUTO_ADD_SUS_BIND_MOUNT / SUS_KSTAT / SPOOF_UNAME / ENABLE_LOG /
     HIDE_KSU_SUSFS_SYMBOLS / SPOOF_CMDLINE_OR_BOOTCONFIG / OPEN_REDIRECT`；
   - 审计日志出现 `avc: denied … permissive=1`（denial 只记录不拦截）。
2. `boot_noroot_enforcing.img`：
   - 启动正常（adb 约 48 秒），`uname -r` = `4.19.157-perf`；
   - `getenforce` = `Enforcing`；`which su` 无输出、`/data/adb/ksu` 不存在
     → 确认「无 root」；
   - 用 `adb reboot bootloader` + fastboot 回刷 root 镜像，未变砖。
3. `boot_ksu-droidspaces-susfs_enforcing.img`（恢复用）：
   - 启动正常，Enforcing，`su -c id` → root，`dmesg` 有 susfs 日志。

## 维护记录

- 早期 `patch_permissive.py` 的 compat/stealth 模式在 `selinux_init()` 里留下了
  两行调试 `pr_info`，所有 10 个镜像因此都多打印两行（功能无影响）。已清掉并把
  全部镜像重编一遍；`make check` + 离线字符串检查确认：enforcing 无
  `flip -> permissive`，permissive 恰有 1 处，且无残留调试字符串。

## 刷入 / 回滚

```sh
# 方式一：adb（Windows 侧 adb.exe，本机已验证）
adb push artifacts/boot_<variant>_<mode>.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# 方式二：fastboot（设备循环重启/进不了系统时）
fastboot flash boot artifacts/boot_<variant>_<mode>.img
fastboot reboot
```

回滚到已知可用镜像：`artifacts/boot_m4.img`（M4，enforcing，KSU v3.3.1 +
容器 + SUSFS），或原厂 `artifacts/boot_stock_device.img`。

## 已知限制

- permissive 从开机 60 秒起生效（早期引导必须 enforcing）；可用
  `dby_perm_delay` 调整，但设得太小会重新触发循环重启。
- 变体 3/5 关闭 `TRY_UMOUNT`（KSU fork 未导出 `try_umount`）。
- `SUS_MOUNT`/`AUTO_ADD_*` 与 DroidSpaces 的 bind mount 冲突，故变体 5 关闭。
- 只构建 `Image.gz`，不构建 dtb；DTB 沿用 stock 模板（华为 `dtbs` 目标依赖私有
  `lcd_kit_parser.pl`）。
- 每次写 `boot` 分区前都需要人工确认；本工程从不写 `ramdisk`/`dtbo`/`vbmeta`/
  `userdata`。
