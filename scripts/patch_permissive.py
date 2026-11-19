#!/usr/bin/env python3
"""Toggle a source-level "SELinux permissive" build.

Facts established on the hardware (Huawei DBY-W09, HarmonyOS 4.3, user build):

  * CONFIG_SECURITY_SELINUX_BOOTPARAM=n, so `enforcing=0` in the cmdline does
    nothing (tested).
  * `androidboot.selinux=permissive` is overridden by init's setenforce(1).
  * A kernel that is permissive *from early boot* reboot-loops before adb/ssh
    come up (tested with three different patches), and the bootloader ends up
    in fastboot.  Something in the early vendor boot flow requires enforcement.
  * `setenforce 0` on the *running* system is fine: no reboot, everything keeps
    working.  So permissive itself is supported, just not during early boot.

Therefore the default mode is `delay`: the kernel boots exactly like the stock
one (enforcing, state field 1, /sys/fs/selinux/enforce 1) and a delayed work
flips it to permissive once boot has settled.  The delay is a kernel parameter:

    dby_perm_delay=<seconds>     (default 60, negative disables the flip)

so it can be tuned from the boot cmdline without recompiling (pack_boot.py
--append-cmdline "dby_perm_delay=20").

Other modes kept for experiments / history:

  --mode stealth   patch avc_denied(): never deny, but keep reporting enforcing.
                   Still reboot-loops early, kept for reference.
  --mode compat    patch enforcing_enabled() to return false (real permissive,
                   /sys/fs/selinux/enforce reads 0).  Reboot-loops early.
  --mode force     compat + neuter enforcing_set().  Textbook, reboot-loops.

All modes are idempotent and reversible (--disable) and touch only a couple of
selinux files, so toggling recompiles a handful of objects and relinks.
"""
import argparse
import os
import re
import sys

MARK = "DBY_FORCE_PERMISSIVE"

# --- compat / force: security/selinux/include/security.h ---------------------
ENF_ON = """static inline bool enforcing_enabled(struct selinux_state *state)
{
\treturn state->enforcing;
}"""
ENF_OFF = """static inline bool enforcing_enabled(struct selinux_state *state)
{
\t/* DBY_FORCE_PERMISSIVE: never report enforcing (permissive build) */
\t(void)state;
\treturn false;
}"""

SET_ON = """static inline void enforcing_set(struct selinux_state *state, bool value)
{
\tstate->enforcing = value;
}"""
SET_OFF = """static inline void enforcing_set(struct selinux_state *state, bool value)
{
\t/* DBY_FORCE_PERMISSIVE: ignore setenforce(1) from init/userspace */
\t(void)state;
\t(void)value;
}"""

# --- stealth: security/selinux/avc.c ----------------------------------------
AVC_ON = """\tif (enforcing_enabled(state) &&
\t    !(avd->flags & AVD_FLAGS_PERMISSIVE))
\t\treturn -EACCES;
"""
AVC_OFF = """\t/* DBY_FORCE_PERMISSIVE: never deny a permission check; the enforcing
\t * state, /sys/fs/selinux/enforce and ro.boot.selinux stay untouched so
\t * vendor userspace still sees an "enforcing" system. */
"""

# --- delay: security/selinux/hooks.c ----------------------------------------
INC_ON = "#include <linux/init.h>\n"
INC_OFF = ("#include <linux/init.h>\n"
           "#include <linux/workqueue.h>\n"
           "#include <linux/moduleparam.h>\n")

INIT_ON = "static __init int selinux_init(void)\n"
INIT_OFF_TMPL = """/* DBY_FORCE_PERMISSIVE: flip to permissive once boot has settled */
static int dby_perm_delay __read_mostly = %d;
module_param_named(dby_perm_delay, dby_perm_delay, int, 0644);

static void dby_perm_work(struct work_struct *work)
{
\tenforcing_set(&selinux_state, false);
\tselinux_status_update_setenforce(&selinux_state, 0);
\tpr_info("SELinux: DBY_FORCE_PERMISSIVE flip -> permissive\\n");
}
static DECLARE_DELAYED_WORK(dby_perm_dw, dby_perm_work);

static __init int selinux_init(void)
"""

SCHED_ON = "\tenforcing_set(&selinux_state, selinux_enforcing_boot);\n"
SCHED_OFF = ("\tenforcing_set(&selinux_state, selinux_enforcing_boot);\n"
             "\tif (dby_perm_delay >= 0)\n"
             "\t\tschedule_delayed_work(&dby_perm_dw, dby_perm_delay * HZ);\n")

SCHED_ON_PRINT = ("\tenforcing_set(&selinux_state, selinux_enforcing_boot);\n"
                  "\tpr_info(\"SELinux: DBY permissive build, flip in %d s\\n\", dby_perm_delay);\n"
                  "\tif (dby_perm_delay >= 0)\n"
                  "\t\tschedule_delayed_work(&dby_perm_dw, dby_perm_delay * HZ);\n")


def read(p):
    with open(p) as f:
        return f.read()


def write(p, s):
    with open(p, "w") as f:
        f.write(s)


def main():
    ws = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["delay", "stealth", "compat", "force"], default="delay")
    ap.add_argument("--delay-sec", type=int, default=20,
                    help="delay-mode default for dby_perm_delay (compile-time, seconds)")
    ap.add_argument("--disable", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--srcdir", default=ws + "/src/kernel")
    args = ap.parse_args()

    hdr = args.srcdir + "/security/selinux/include/security.h"
    hooks = args.srcdir + "/security/selinux/hooks.c"
    avc = args.srcdir + "/security/selinux/avc.c"

    def state():
        h = read(hdr)
        a = read(avc)
        c = read(hooks)
        if MARK in a:
            return "stealth"
        if MARK in h:
            return "force" if SET_OFF in h else "compat"
        if "dby_perm_dw" in c:
            return "delay"
        return None

    cur = state()
    if args.check:
        print("permissive patch:", f"APPLIED ({cur})" if cur else "not applied")
        return 0 if cur else 1

    def revert():
        h = read(hdr)
        if MARK in h:
            write(hdr, h.replace(ENF_OFF, ENF_ON, 1).replace(SET_OFF, SET_ON, 1))
        a = read(avc)
        if MARK in a:
            write(avc, a.replace(AVC_OFF, AVC_ON, 1))
        c = read(hooks)
        if "dby_perm_dw" in c:
            c = re.sub(r"/\* DBY_FORCE_PERMISSIVE: flip to permissive.*?"
                       r"static __init int selinux_init\(void\)\n",
                       INIT_ON, c, count=1, flags=re.S)
            c = c.replace(SCHED_ON_PRINT, SCHED_ON, 1).replace(SCHED_OFF, SCHED_ON, 1)
            c = c.replace(INC_OFF, INC_ON, 1)
            write(hooks, c)

    if args.disable:
        if not cur:
            print("already disabled")
            return 0
        revert()
        print("permissive patch reverted")
        return 0

    if cur == args.mode:
        print(f"already applied ({cur})")
        return 0
    if cur:
        revert()

    if args.mode == "stealth":
        a = read(avc)
        if AVC_ON not in a:
            sys.exit("error: avc_denied() does not match the expected 4.19 layout")
        write(avc, a.replace(AVC_ON, AVC_OFF, 1))
    elif args.mode in ("compat", "force"):
        h = read(hdr)
        if ENF_ON not in h:
            sys.exit("error: security.h does not match the expected 4.19 layout")
        h = h.replace(ENF_ON, ENF_OFF, 1)
        if args.mode == "force":
            if SET_ON not in h:
                sys.exit("error: enforcing_set() not found in security.h")
            h = h.replace(SET_ON, SET_OFF, 1)
        write(hdr, h)
    else:  # delay
        c = read(hooks)
        if "dby_perm_dw" in c:
            sys.exit("error: delay block already present")
        if INC_ON not in c:
            sys.exit("error: hooks.c include anchor missing")
        c = c.replace(INC_ON, INC_OFF, 1)
        if INIT_ON not in c:
            sys.exit("error: selinux_init() anchor missing")
        c = c.replace(INIT_ON, INIT_OFF_TMPL % args.delay_sec, 1)
        if SCHED_ON not in c:
            sys.exit("error: enforcing_set() call site missing")
        c = c.replace(SCHED_ON, SCHED_ON_PRINT, 1)
        write(hooks, c)

    print(f"permissive patch applied ({args.mode} mode)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
