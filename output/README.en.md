# DBY-W09 (MatePad 11 2021) custom kernel boot images

**English** | [简体中文](README.md)

10 images = 5 feature sets x 2 SELinux modes. Only the kernel is replaced;
ramdisk / DTB / cmdline / os_version are identical to the stock image
(`make check` verifies this).

## Files

| File | root | SUSFS | Docker/DroidSpaces | SELinux |
|---|---|---|---|---|
| `boot_noroot_enforcing.img` | – | – | – | Enforcing |
| `boot_noroot_permissive.img` | – | – | – | Permissive from boot |
| `boot_ksu_enforcing.img` | ✓ | – | – | Enforcing |
| `boot_ksu_permissive.img` | ✓ | – | – | Permissive from boot |
| `boot_ksu-susfs_enforcing.img` | ✓ | full | – | Enforcing |
| `boot_ksu-susfs_permissive.img` | ✓ | full | – | Permissive from boot |
| `boot_ksu-droidspaces_enforcing.img` | ✓ | – | ✓ | Enforcing |
| `boot_ksu-droidspaces_permissive.img` | ✓ | – | ✓ | Permissive at 20 s |
| `boot_ksu-droidspaces-susfs_enforcing.img` | ✓ | partial | ✓ | Enforcing |
| `boot_ksu-droidspaces-susfs_permissive.img` | ✓ | partial | ✓ | Permissive at 20 s |

- root / SUSFS come from KernelSU v3.3.1 (UAPI 5); the manager app is the
  official `KernelSU_v3.3.1_32680-release.apk`.
- Variant 3's SUSFS includes `SUS_MOUNT` plus automatic hiding; variant 5
  disables `SUS_MOUNT` (it conflicts with DroidSpaces bind mounts). Neither
  includes `TRY_UMOUNT` (the KernelSU fork does not export the internal
  function).
- The kernel also carries a fix for the NULL dereference in Huawei's msm
  display driver (`msm_gem_fault`): inside a container, Anland/llvmpipe mmaps
  imported dma-bufs, which used to reboot the device
  (`scripts/patch_msm_fault.py`).
- "20 s" is the kernel flipping itself, independent of userspace;
  `dmesg | grep DBY_FORCE_PERMISSIVE` shows `flip -> permissive`. Permissive
  from boot combined with the container options triggers HarmonyOS's bootfail
  loop, so the container variants have to delay.

## Verify

```sh
sha256sum -c SHA256SUMS
```

## Flashing

```sh
# device boots and has root (boot partition only)
adb push boot_ksu-droidspaces-susfs_permissive.img /data/local/tmp/boot.img
adb shell su -c 'dd if=/data/local/tmp/boot.img of=/dev/block/by-name/boot bs=4096 conv=fsync'
adb shell su -c 'sha256sum /dev/block/by-name/boot'
adb reboot

# device does not boot: hold Volume Down while plugging in USB for fastboot
fastboot flash boot boot_<variant>_<mode>.img
fastboot reboot
```

Check after flashing:

```sh
adb shell 'getenforce; uname -r'          # expect 4.19.157-perf
adb shell 'su -c id'                      # expect uid=0(root) u:r:ksu:s0
```

## Rollback

Flash the boot image you backed up before flashing (stock or any known-good
build):

```sh
fastboot flash boot <backup>.img
```

## Building

See `../docs/BUILD.en.md`. In one line:

```sh
make images     # rebuilds the 10 images in artifacts/ and copies them to output/
```
