# M2 (container/docker) 验收报告

日期: 2026-11-16
内核: 4.19.157-perf #1 SMP PREEMPT Mon Nov 16 06:47:37 CST 2026
镜像: artifacts/boot_m2.img
sha256: 2f89624bc90a416bd54044b205555b020f6631ad25a87ac36564fb25d1aaaa16
KSU: backslashxx/KernelSU v3.3.0-55 (KSU_VERSION 32656, UAPI 4)

## 已验证

- 开机正常, `sys.boot_completed=1`, Wi-Fi 连接（设备局域网 IP）
- root: `/system/bin/su` -> `uid=0(root)` context `u:r:ksu:s0`
- KSU 模块运行: zygisk-ptrace64, zygiskd64, lspd, zygisk_lsposed, zygisk-sui, droidspaces daemon
- cgroup 控制器: devices / pids / net_prio 已出现 (hierarchy 0 = 已启用未挂载)
- DroidSpaces v7.2.0 `check`: 全部 [MUST HAVE] 通过; 仅 "New mount API" (5.2+) 缺失, 非必需
- Debian 13 (trixie) 容器: PID 1 = systemd, eth0 172.28.178.197, ping 1.1.1.1 通
- Docker 26.1.5 (rootfs 自带): `systemctl start docker` -> active
- `docker run hello-world` 成功
- `docker run busybox ping 1.1.1.1` 成功 (bridge + NAT)
- `docker run busybox nslookup example.com` 成功 (embedded DNS)
- 镜像加速: `docker.m.daocloud.io` 可用; Docker Hub 直连超时

## 备注

- 设备锁屏后 CE 存储不可读: /sdcard、Termux 数据不可访问, sshd 无法启动
- sshd 由用户手动在 Termux 启动; 已装 KSU 模块 `/data/adb/modules/sshd_autostart`
  在解锁后用 `setsid nohup sshd -p 8022 -o ListenAddress=0.0.0.0 -D` 拉起
- 华为 rproc 会把 `/data/adb/ksud` 标记为 abnormal; 不影响按需 su (内核 hook 直接 exec ksud)
