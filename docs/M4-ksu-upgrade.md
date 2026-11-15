# M4: KSU 升级到 v3.3.1 (UAPI 5) + 官方管理器

## 背景
- 设备原管理器 v3.3.0-39 (32640) 是第三方**重签**版, 证书 `0x0363 / 4359…`
- backslashxx v3.3.0-55 内核写死信任 `0x033b / c371…` (KernelSU 官方发布签名)
  -> 原管理器其实未被内核认可, 只是能查询状态
- 官方 v3.3.1 APK 证书 = `0x033b / c371…`, 与内核预期一致
- v3.3.1 (backslashxx) = UAPI 5, KSU_VERSION 32676, 布局与 v3.3.0-55 相同

## 升级顺序 (关键: 先换内核/ksud, 再换管理器)
1. 编译 M4 (KSU v3.3.1 + SUSFS + 容器)
2. 设备仍在 M3 (UAPI 4) 且 root 可用时:
   - 推送 boot_m4.img 和 v3.3.1 的 ksud (APK 内 `lib/arm64-v8a/libksud.so`)
   - 同一个 root shell 内: dd 写 boot -> 备份 /data/adb/ksud -> 替换为 v3.3.1 ksud -> sync -> reboot
   (替换 ksud 后旧内核的 su 会失效, 所以放在同一条命令的最后)
3. 重启进入 M4 (UAPI 5), /data/adb/ksud 已是 UAPI 5 -> su 立即可用
4. 卸载重签版管理器, 安装官方 v3.3.1 APK:
   `adb uninstall me.weishu.kernelsu && adb install KernelSU_v3.3.1_32680-release.apk`
5. 打开管理器: 应显示内核版本 32676, 不再提示"需要更新管理器"

## 回滚
- M3 镜像 + M3 时期的 ksud (备份在 /data/local/tmp/ksud.bak)
- 或直接刷回 artifacts/boot_m3.img, 并把 /data/adb/ksud 恢复为备份

## 验证
- 管理器显示 "工作中", 内核版本 32676
- su -c id -> uid=0
- ksu_susfs show version -> v1.5.5
- DroidSpaces check / Docker hello-world
