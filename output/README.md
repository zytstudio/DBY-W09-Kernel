# DBY-W09 (MatePad 11 2021) 自编内核 boot 镜像

**简体中文** | [English](README.en.md)

10 个镜像 = 5 种功能组合 × 2 种 SELinux 模式。全部只替换内核，
ramdisk / DTB / cmdline / os_version 与设备原厂镜像一致（`make check` 校验）。

## 文件

| 文件 | root | SUSFS | Docker/DroidSpaces | SELinux |
|---|---|---|---|---|
| `boot_noroot_enforcing.img` | – | – | – | Enforcing |
| `boot_noroot_permissive.img` | – | – | – | 开机即 Permissive |
| `boot_ksu_enforcing.img` | ✓ | – | – | Enforcing |
| `boot_ksu_permissive.img` | ✓ | – | – | 开机即 Permissive |
| `boot_ksu-susfs_enforcing.img` | ✓ | 完整 | – | Enforcing |
| `boot_ksu-susfs_permissive.img` | ✓ | 完整 | – | 开机即 Permissive |
| `boot_ksu-droidspaces_enforcing.img` | ✓ | – | ✓ | Enforcing |
| `boot_ksu-droidspaces_permissive.img` | ✓ | – | ✓ | 第 20 秒切 Permissive |
| `boot_ksu-droidspaces-susfs_enforcing.img` | ✓ | 部分 | ✓ | Enforcing |
| `boot_ksu-droidspaces-susfs_permissive.img` | ✓ | 部分 | ✓ | 第 20 秒切 Permissive |

- root / SUSFS 来自 KernelSU-Next `legacy` 分支（v3.4.0-legacy）；管理器用
  `KernelSU_Next_v3.4.1_33333-release.apk`（包名 `com.rifsxd.ksunext`）。
  旧包的 `KernelSU_v3.3.1_32680-release.apk` 是已删除的 backslashxx/KernelSU
  的 manager，与本内核不兼容。
- 变体 3 的 SUSFS 含 `SUS_MOUNT` + 自动隐藏；变体 5 关闭 `SUS_MOUNT`
  （与 DroidSpaces 的 bind mount 冲突）。两者都不含 `TRY_UMOUNT`
  （KernelSU fork 未导出对应内部函数）。
- 内核额外修了华为 msm 显示驱动的 `msm_gem_fault` 空指针：容器里 Anland/llvmpipe
  mmap 导入的 dma-buf 不再导致设备重启（`scripts/patch_msm_fault.py`）。
- 「第 20 秒」是内核自己翻转，与用户态无关；`dmesg | grep DBY_FORCE_PERMISSIVE`
  能看到 `flip -> permissive`。早期 permissive 与容器选项组合会触发
  HarmonyOS bootfail 循环，所以容器变体必须延迟。

## 校验

```sh
sha256sum -c SHA256SUMS
```

## 刷入

```sh
# 设备已 root、能进系统（只写 boot 分区）
adb push boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# 进不了系统：音量下 + 插 USB 进 fastboot
fastboot flash boot boot_<variant>_<mode>.img
fastboot reboot
```

刷完检查：

```sh
adb shell 'getenforce; uname -r'          # 期望 4.19.157-perf
adb shell 'su -c id'                      # 期望 uid=0(root) u:r:ksu:s0
```

## 回滚

刷回你刷机前备份的 boot 镜像（原厂或任一已知可用版本）：

```sh
fastboot flash boot <backup>.img
```

## 构建

见 `../docs/BUILD.md`。一句话：

```sh
make images     # 重新生成 10 个镜像到 artifacts/，并整理到 output/
```
