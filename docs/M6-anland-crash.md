# M6 — anland/denial 触发设备重启的排查与修复

## 现象

Droidspaces 容器 `debian` 里启动 Denial（Wayland 合成器，anland 的 producer），
再从 Android 端 Anland（consumer）连接桌面时，设备 1–2 秒后重启（华为 logo 后
直接重启）。只启动 denial、没有 consumer 连接时不会重启；consumer 连上、
buffer 交付之后必现。

## 证据（真机抓取）

用 `adb exec-out su -c "dmesg -w"` 实时把内核日志回传到主机，重启瞬间抓到：

```
[582.244968] llvmpipe-0: Unable to handle kernel NULL pointer dereference at virtual address 0000000000000000
[582.245327] Internal error: Oops: 96000005 [#1] PREEMPT SMP
[582.245475] pc : msm_gem_fault+0x88/0xfc
[582.245748] Call trace:
[582.245765]  msm_gem_fault+0x88/0xfc
[582.245782]  __do_fault+0x7c/0x140
[582.245797]  handle_pte_fault+0x704/0xe18
[582.245811]  handle_mm_fault+0x1d8/0x2bc
[582.245830]  do_page_fault+0x360/0x57c
[582.245895]  el0_da+0x1c/0x20
[582.245911] ---[ end trace d2f3d594959f4c2d ]---
[582.284608] bbox: info: force_flush_kmsg_buffer begin      <- 华为 bbox 落盘，随后重启
```

紧挨着 oops 前还有一行审计日志，说明这个 mapping 是 **permissive 才放行的**：

```
avc: denied { map } for comm="llvmpipe-0" path="/dev/dri/renderD128"
  scontext=u:r:droidspacesd:s0 tcontext=u:object_r:tmpfs:s0 tclass=chr_file permissive=1
```

反汇编 `msm_gem_fault+0x88` 对应 `ldr x8, [x0, x8]`（即 `pages[pgoff]`），
崩溃时 `x0 = 0`，也就是 `get_pages()` 返回了 NULL。

## 根因

`techpack/display/msm/msm_gem.c`（华为实际编译的显示驱动，不是
`drivers/gpu/drm/msm/` 那份）：

```c
/* msm_gem_import(): 导入的 dma-buf 根本不建页数组 */
msm_obj->pages = NULL;

/* get_pages(): 导入对象直接返回这个 NULL */
if (obj->import_attach)
	return msm_obj->pages;

/* msm_gem_fault(): 没有任何 NULL 检查 */
pages = get_pages(obj);
if (IS_ERR(pages)) { ... }      /* NULL 不是 ERR，检查不到 */
pfn = page_to_pfn(pages[pgoff]); /* <- 空指针 */
```

即：华为 MSM 显示驱动**不支持对导入的 dma-buf 做 CPU mmap**，fault 时直接空指针。
Android 正常使用不会走这条路（GPU 走 kgsl，导入的 buffer 只经 IOMMU 映射，不
mmap），所以这是厂商代码里的潜伏 bug。

容器里 Mesa/llvmpipe 通过 `/dev/dri/renderD128` 把 consumer（Android 端
Anland app）分配的 dma-buf `PRIME_FD_TO_HANDLE` + `mmap` 做 CPU 渲染，正好踩中。
SELinux permissive 是必要条件：enforcing 时这次 `map` 会被拒绝（见上面的
`permissive=1` 审计行）。注意 droidspaces 容器配置里 `selinux_permissive=1`
自己就会把主机切到 permissive，所以**任何内核**（哪怕 enforcing 内核）都可能踩到，
不能只靠“别开 permissive”规避。

## 修复

`scripts/patch_msm_fault.py`（幂等，改动 `techpack/display/msm/msm_gem.c`）：

1. `get_pages()`：对导入对象，若 `msm_obj->pages` 为空、`sgt` 已附加，用
   `drm_prime_sg_to_page_addr_arrays()` 把 sg 表展开成页数组并缓存
   （与 mainline `drivers/gpu/drm/msm/msm_gem.c` 导入时的做法一致），这样
   llvmpipe 的 CPU mmap 能真正工作；
2. `msm_gem_fault()`：在 `IS_ERR(pages)` 之后补 `if (!pages) return VM_FAULT_SIGBUS;`，
   即使 sgt 还没附加，最坏也只是调用进程收到 SIGBUS，不会内核 oops/重启。

## 验证

复现路径（无需人工猜按钮）：容器运行 → 容器内 `./startup.sh` 起 deniald →
`am start` 打开 Droidspaces → 点容器 → 「Anland → 启动」让 consumer 连接。

| | 结果 |
|---|---|
| 修复前 | `msm_gem_fault+0x88` oops → bbox flush → 设备重启 |
| 修复后 | 同样操作，dmesg 无 oops，设备 uptime 持续增长，consumer/producer 正常交付 5 个 fd |

## 仍未解决的部分（不是内核）

修复后 deniald 不再把设备搞重启，但它自己会退出：

```
ERROR deniald::flutter_runtime::renderer::texture::handler::open_gl:
  required Flutter native fence export failed: None of the following EGL extensions
  is supported ... ["EGL_ANDROID_native_fence_sync"]
deniald: fatal error: could not export the required Flutter native fence
```

容器里的 Mesa 选的是 **llvmpipe**（`GL Renderer: "llvmpipe (LLVM 19.1.7)"`），
`/dev/dri/renderD128` 是显示 DRM，Adreno 在 `/dev/kgsl-3d0`，Mesa 没走
freedreno/kgsl，所以没有 `EGL_ANDROID_native_fence_sync`。这属于容器里的
GPU/Mesa 配置问题（anland 指南要求 Adreno + 对应 Mesa 驱动，或走 droidspaces 的
virgl 选项），需要用户态解决；内核侧该给的节点
（`/dev/dri/renderD128`、`/dev/kgsl-3d0`）都在，驱动也没问题。

## 结论

- **重启是内核问题**：华为 techpack MSM 驱动对导入 dma-buf 的 mmap 空指针；
  已用 `scripts/patch_msm_fault.py` 修掉，设备不再重启（真机验证）。
- **和我们的 permissive 改动关系**：permissive 只是让容器能 mmap `/dev/dri` 的
  必要条件之一；droidspaces 自己也会 `setenforce 0`，所以修复必须落在驱动里。
- **denial 还起不来**是用户态 EGL 能力不足（llvmpipe 没有 native fence），
  与内核无关。
