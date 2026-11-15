# M3 (SUSFS 1.5.5) 验收报告

日期: 2026-11-16
内核: 4.19.157-perf #2 SMP PREEMPT Mon Nov 16 07:20:54 CST 2026
镜像: artifacts/boot_m3.img
sha256: 2761b50491ddfb9270512bb4c1aee041144806e5967054c97dabd88526669239
KSU: backslashxx/KernelSU v3.3.0-55 (UAPI 4, KSU_VERSION 32656)

## 集成方式

- 内核侧: 应用 simonpunk/susfs4ksu `kernel-4.19` 的
  `50_add_susfs_in_kernel-4.19.patch`，手工处理 3 处华为树差异:
  - `fs/namespace.c` include 区 (susfs_def.h)
  - `fs/readdir.c` 的 `compat_fillonedir()` (华为变体无 verify_dirent_name)
  - `include/linux/sched.h` 的 task_struct KABI 布局 (直接加 u64 字段)
- KSU 侧: 本 fork 是 ioctl-only, 没有 prctl 钩子。做法:
  - 新增 `fs/susfs_prctl.c`: 从 10_ 补丁提取 ~280 行命令分发,
    `ksu_access_ok` -> `access_ok(VERIFY_READ,...)`, `current_uid_val` -> `current_uid().val`
  - `kernel/sys.c` 的 `SYSCALL_DEFINE5(prctl)` 入口拦截 **0xDEADBEEF**
    (注意: 不是 0x55550, 0x55550 是第一个 SUSFS 命令号)
  - `KernelSU/kernel/ksu.c` 初始化时调用 `susfs_init()`
  - KSU Kconfig 追加 SUSFS 菜单
  - `ksu_try_umount()` 提供空实现 (ioctl-only fork 没有该函数; TRY_UMOUNT 关闭)

## 配置

开启: `SUS_PATH` `SUS_KSTAT` `SPOOF_UNAME` `ENABLE_LOG`
`HIDE_KSU_SUSFS_SYMBOLS` `SPOOF_CMDLINE_OR_BOOTCONFIG` `OPEN_REDIRECT`

关闭(为 DroidSpaces 兼容): `SUS_MOUNT` `AUTO_ADD_SUS_KSU_DEFAULT_MOUNT`
`AUTO_ADD_SUS_BIND_MOUNT` `TRY_UMOUNT` `AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT`
`SUS_OVERLAYFS` `HAS_MAGIC_MOUNT` `SUS_SU`

## 已验证

- `ksu_susfs show version` -> `v1.5.5`
- `ksu_susfs show enabled_features` -> 与上面 7 项一致
- `set_uname 4.19.157-susfstest SMP-PREEMPT` -> shell `uname -r` 变为假值,
  `set_uname default default` 可还原
- `add_sus_path /data/local/susfs_test` -> shell 访问 Permission denied,
  root 仍可见 (挂载点非 tmpfs 才生效, tmpfs 按设计不支持)
- root: `su -c id` -> uid=0, context u:r:ksu:s0
- DroidSpaces `check`: 全部必需项通过
- Debian 13 容器启动正常, Docker active, `hello-world` 再次通过

## 与现机的差异

- 现机预编译内核: KSU 版本/管理器 32640, SUSFS 1.5.5 + SUS_MOUNT 开启
- 本构建: KSU 32656 (UAPI 4), SUSFS 1.5.5 + SUS_MOUNT 关闭 (容器兼容)
