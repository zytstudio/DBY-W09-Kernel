# M4: KSU v3.3.1 + 官方管理器 升级报告

日期: 2026-11-16
内核: 4.19.157-perf #1 SMP PREEMPT Mon Nov 16 07:29:57 CST 2026
镜像: artifacts/boot_m4.img
sha256: c3ea75c25dfec7ad80c68f7ae1d52cc7c9e8a055f2c610a7fa2c06246597244d

## 版本

- KSU 内核侧: backslashxx/KernelSU **v3.3.1** (KSU_VERSION **32676**, UAPI **5**)
- 管理器: 官方 **KernelSU v3.3.1 (32680-5)**
  - 签名证书: `0x033b / c371061b…` — 与内核 `KSU_EXPECTED_HASH` 一致
- 旧管理器 v3.3.0-39 (32640) 是第三方重签版 (`0x0363 / 4359…`), 内核其实不认可

## 升级过程

1. 切 KSU 源码到 `v3.3.1` tag, 用 `scripts/apply_ksu_susfs.py` 重新接线 SUSFS
   (Kconfig 菜单 + ksu.c 的 susfs_init; 内核侧 fs/susfs*.c 与 prctl 分发不变)
2. 编译 M4, dd 刷入 boot, 重启
3. 卸载重签版管理器, 安装官方 v3.3.1 APK
4. 重启一次: ksud 在开机阶段安装 `/system/bin/su` 并接管 root
   (首次安装管理器后若不重启, su 不会出现)

## 已验证

- 管理器: 显示 "工作中", 内核版本 **32676-5**, 管理器 **v3.3.1 (32680-5)**,
  **无 "需要更新管理器" 横幅**
- root: `su -c id` -> uid=0, context u:r:ksu:s0
- SUSFS: `ksu_susfs show version` -> v1.5.5; enabled_features 7 项与配置一致
- DroidSpaces `check`: 全部必需项通过
- Debian 13 容器启动正常, Docker active, `hello-world` 通过

## 回滚

- M3 镜像: artifacts/boot_m3.img (KSU v3.3.0-55, UAPI 4, 管理器需换回旧 APK)
- 注意: 回滚 M3 时需要同时把 /data/adb/ksud 换回 UAPI 4 版本, 否则 su 不可用
