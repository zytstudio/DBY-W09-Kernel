#!/bin/bash
# Wire a KernelSU checkout into the vendor kernel tree (idempotent).
#
#   scripts/wire_kernelsu.sh [KERNEL_TREE]
#
# Does exactly what KernelSU/kernel/setup.sh does, but without cloning or
# pulling, so the checkout stays pinned:
#   drivers/kernelsu            -> ../KernelSU/kernel
#   drivers/Makefile            += obj-$(CONFIG_KSU) += kernelsu/
#   drivers/Kconfig             += source "drivers/kernelsu/Kconfig"
set -euo pipefail
WS=$(cd "$(dirname "$0")/.." && pwd)
K=${1:-$WS/src/kernel}

[ -d "$K/KernelSU/kernel" ] || { echo "error: $K/KernelSU is missing" >&2; exit 1; }

ln -sfn ../KernelSU/kernel "$K/drivers/kernelsu"

grep -q 'obj-$(CONFIG_KSU) += kernelsu/' "$K/drivers/Makefile" 2>/dev/null ||
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$K/drivers/Makefile"

python3 - "$K/drivers/Kconfig" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
line = 'source "drivers/kernelsu/Kconfig"'
if line in s:
    print("  [skip] drivers/Kconfig")
else:
    i = s.rstrip().rfind('endmenu')
    if i < 0:
        sys.exit('error: drivers/Kconfig has no endmenu')
    s = s[:i] + line + '\n' + s[i:]
    open(p, 'w').write(s)
    print("  [ok]   drivers/Kconfig")
PY

echo "KernelSU wired into $K"
