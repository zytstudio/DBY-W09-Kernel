# M3: SUSFS 1.5.5 移植计划

## 现状
- 内核树: 官方 4.19.157 + KernelSU v3.3.0-55 (UAPI 4, KSU_VERSION 32656)
- KSU 是 ioctl-only, 没有 prctl 钩子; SUSFS 用户态 `ksu_susfs` 用 prctl(0x55550)
- 旧闭源内核在同一 backslashxx 架构上跑 SUSFS 1.5.5, 说明可行

## 补丁 dry-run 结果 (50_add_susfs_in_kernel-4.19.patch)
大部分 hunk 带 offset 成功, 3 处需要手工处理:
1. `fs/namespace.c` hunk#1: 华为树 include 区不同 -> 手工在 `#include "internal.h"` 后插入
   susfs_def.h include + SUS_MOUNT/AUTO_ADD 全局变量块
2. `fs/readdir.c` hunk#4: `compat_fillonedir()` 在华为树中不存在 -> 跳过该 hunk
   (32-bit compat 可选; 其它 filldir/filldir64/compat_filldir 已成功)
3. `include/linux/sched.h`: 华为 task_struct 的 ANDROID_KABI 布局不同 ->
   在 task_struct 尾部、randomized_struct_fields_end 之前加
   `u64 susfs_task_state; u64 susfs_last_fake_mnt_id;`
   (不使用 ANDROID_KABI_USE, 直接加字段最稳)

## 集成步骤
1. `patch -p1` 应用 50_, 保留 .rej, 手工修 3 处
2. 从 simonpunk/susfs4ksu kernel-4.19 复制:
   `fs/susfs.c`, `fs/sus_su.c`, `include/linux/susfs.h`, `susfs_def.h`, `sus_su.h`
3. Kconfig: 在 `drivers/kernelsu/Kconfig` 加 SUSFS 菜单 (照 10_ 补丁)
4. **prctl 分发**: 在 `kernel/sys.c` 的 `SYSCALL_DEFINE5(prctl)` 入口加
   ```c
   #ifdef CONFIG_KSU_SUSFS
   if (option == 0x55550) { ret = susfs_handle_prctl(option, arg2, arg3, arg4, arg5); if (ret != -EINVAL) return ret; }
   #endif
   ```
   handler 移植自 10_ 补丁的 ksu_handle_prctl SUSFS 分支:
   ADD_SUS_PATH / ADD_SUS_MOUNT / ADD_SUS_KSTAT(_STATICALLY) / UPDATE_SUS_KSTAT /
   ADD_TRY_UMOUNT / RUN_UMOUNT_FOR_CURRENT_MNT_NS / SET_UNAME / ENABLE_LOG /
   SET_CMDLINE_OR_BOOTCONFIG / ADD_OPEN_REDIRECT / SHOW_VERSION /
   SHOW_ENABLED_FEATURES (+ SUS_MAP 可选)
5. `susfs_init()` 挂到 KSU 初始化 (`kernel/core/init.c` 或 module_init)
6. 配置: SUS_PATH/SUS_KSTAT/SPOOF_UNAME/ENABLE_LOG/HIDE_SYMBOLS/
   SPOOF_CMDLINE/OPEN_REDIRECT/TRY_UMOUNT = y
   **SUS_MOUNT=n, AUTO_ADD_*=n, SUS_OVERLAYFS=n** (DroidSpaces 兼容)
7. 构建 -> 打包 -> 刷入 -> 用 /data/adb/ksu/bin/ksu_susfs 验证
   (show version/enabled_features; add_sus_path; set_uname)

## 验收
- `ksu_susfs show version` = v1.5.5
- `show enabled_features` 与 Kconfig 一致
- susfs4ksu 模块 WebUI 状态正常
- DroidSpaces 容器仍可启动 + Docker 仍可用

## 回滚
- M2 镜像: artifacts/boot_m2.img (sha256 2f89624b...)
