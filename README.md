# DBY-W09 (MatePad 11 2021) Android 4.19 内核构建

官方 `DBY-W09_HarmonyOS4.0.0_opensource.tar.gz` 源码 + Ubuntu clang 11.1.0-6 +
GNU binutils 2.38 的从源码构建工程。目标：KernelSU root + SUSFS + Docker/DroidSpaces。

## 环境

```sh
. scripts/env.sh          # PATH/LD_LIBRARY_PATH/交叉编译器
```

工具链（`toolchain/debs`，`dpkg-deb -x` 解包，无需 root）：
- clang-11_11.1.0-6 / libclang-cpp11 / libllvm11 / libclang-common-11-dev
- binutils-aarch64-linux-gnu_2.38-4ubuntu2.12

源码：`src/kernel`（tar 内 `Code_Opensource/kernel`），KernelSU 在 `src/kernel/KernelSU`。

## 流程

```sh
# 1. 解包 + 补丁（幂等）
tar xzf DBY-W09_HarmonyOS4.0.0_opensource.tar.gz -C src Code_Opensource/kernel
mv src/Code_Opensource/kernel src/kernel
python3 scripts/patch_source.py

# 2. 集成 backslashxx/KernelSU（钉在 c16b935d，v3.3.1+）
cd src/kernel
bash KernelSU/kernel/setup.sh c16b935d07e13941774b6eeae1b1a0f8387f0960

# 3. 生成配置（以设备 /proc/config.gz 为基准）
./scripts/configure.sh "$PWD/out/m1"

# 4. 编译（只编 Image.gz，不编 dtbs）
./scripts/build.sh "$PWD/out/m1" Image.gz

# 5. 用现机已知可用镜像做模板重新打包
python3 scripts/pack_boot.py \
  --kernel out/m1/arch/arm64/boot/Image.gz \
  --template KSU/GKI/boot_susfs_v1.5.5_ksu_v339_permissive.img \
  --out artifacts/boot_m1.img
python3 scripts/verify_boot.py KSU/GKI/boot_susfs_v1.5.5_ksu_v339_permissive.img artifacts/boot_m1.img

# 6. 刷入（需人工确认；只写 boot 分区）
scripts/flash_boot.sh artifacts/boot_m1.img --yes
```

## 对源码的必要修改（`scripts/patch_source.py`）

| 修改 | 原因 |
|---|---|
| `scripts/mkcompile_h` 取 `head -n1` | clang -v 多行输出会破坏版本字符串 |
| `drivers/qcacld/Kbuild` 用 `$(srctree)` | `O=` 外编时 WLAN 路径错误 |
| 放开 `KPROBES/KRETPROBES` 的 `HUAWEI_KERNEL_DEBUG` 依赖 | 现机内核 KPROBES=y 而 HUAWEI_KERNEL_DEBUG=n |
| 取消 5 个 5.x 回移的 `-Werror=` | 华为老代码（mm/vmalloc.c 等）不满足 |
| `.bss.rtic` 并入主 `.bss` | STABS_DEBUG 的 `.comment 0` 会把位置计数器归零，导致 RTIC 段落在 0x1000，非可重定位链接报 `R_AARCH64_ADR_PREL_PG_HI21` 溢出 |
| `lcd_kit_dpd.h` stub | 该头由华为私有 XML 工具生成，开源包不含；DPD 默认关闭 |

## boot 镜像格式（96MiB，header v2）

```
0x0000  header (4096, v2, page 4096, os_version 0x1600014b)
0x1000  Image.gz
        ramdisk (gzip cpio, 519235B, 内含 fstab.qcom + e2fsck)
        dtb (1,664,243B: 3 x kona FDT + RTIC FDT)
0x16f8000 (24,084,480) vbmeta + 0 padding + AVBf footer (最后 64B)
```
`scripts/pack_boot.py` 只替换 kernel 并更新 `kernel_size`，ramdisk/DTB/cmdline/id
原样保留；若新内核超出模板 payload 预算，会把 vbmeta 后移并重写 footer
（本机 AVB 不强制：现机运行的自编内核与 stock footer 摘要本就对不上）。

## 回滚

- 已知可用内核：`KSU/GKI/boot_susfs_v1.5.5_ksu_v339_permissive.img`
  （sha256 `8ce0842b…b57f7`，与刷机前设备 boot 分区逐字节一致）。
- 设备 boot 备份：`artifacts/boot_stock_device.img`；ramdisk：`artifacts/ramdisk_stock.img`。
- fastboot：Windows `C:\Users\18210\Desktop\UFI001C\fastboot.exe`（已在 WSL 验证 adb 可见设备）。

## 已知差异 / 注意

- 本构建与现机 config 的差异：KSU 版本（v3.3.1+ / 32730 vs 管理器 32640）、
  `KPROBES` 来自放开依赖、无 SUSFS（M1 阶段）。
- 只写 `boot` 分区，绝不碰 `ramdisk`/`dtbo`/`vbmeta`/`userdata`。
