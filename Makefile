# Reproducible boot-image matrix for the Huawei MatePad 11 (DBY-W09, kona).
#
#   make images      build all 5 variants x {enforcing, permissive} = 10 images
#   make ksu-susfs   build a single variant (both flavours)
#   make check       verify every produced image against the stock template
#   make list        show the matrix and what each variant contains
#   make distclean   drop per-variant build trees (keeps images/artifacts)
#
# Requirements: toolchain/ (clang 11.1.0-6 + binutils 2.38, see scripts/env.sh),
# src/kernel/ patched by scripts/patch_source.py + scripts/apply_ksu_susfs.py,
# configs/running.config, artifacts/boot_stock_device.img.
#
# Enforcing/permissive is a *source* toggle (scripts/patch_permissive.py), not a
# .config toggle, so the second flavour only recompiles a few selinux objects.
# The device is a HarmonyOS user build: cmdline tricks (enforcing=0,
# androidboot.selinux=permissive) do not survive init's setenforce(1), which is
# why permissive has to be compiled in.

SHELL   := /bin/bash
JOBS    ?= 16
export JOBS

VARIANTS := noroot ksu ksu-susfs ksu-droidspaces ksu-droidspaces-susfs
DIST     := output
MODES    := enforcing permissive
IMAGES   := $(foreach v,$(VARIANTS),$(foreach m,$(MODES),artifacts/boot_$(v)_$(m).img))

.PHONY: all images check list distclean manifest dist $(VARIANTS)

all: images

images: $(VARIANTS)
	@sha256sum $(IMAGES) > artifacts/IMAGES.sha256
	@echo
	@echo "=== boot image matrix ==="
	@sed 's/^/  /' artifacts/IMAGES.sha256
	@$(MAKE) --no-print-directory dist

manifest:
	@sha256sum $(IMAGES) > artifacts/IMAGES.sha256
	@cat artifacts/IMAGES.sha256

# Curated deliverable folder: the 10 images + their own checksum list.
dist:
	@mkdir -p $(DIST)
	@set -e; for v in $(VARIANTS); do for m in $(MODES); do \
	  cp -f artifacts/boot_$${v}_$${m}.img $(DIST)/; \
	done; done
	@cd $(DIST) && sha256sum *.img > SHA256SUMS
	@echo "=== $(DIST)/ ==="
	@ls -l $(DIST)/*.img | awk '{print $$5, $$9}'
	@echo "checksums: $(DIST)/SHA256SUMS"

$(VARIANTS):
	scripts/build_variant.sh $@

check:
	@set -e; for v in $(VARIANTS); do \
	  for m in $(MODES); do \
	    f=artifacts/boot_$${v}_$${m}.img; \
	    test -f $$f || { echo "missing $$f"; exit 1; }; \
	    python3 scripts/verify_boot.py artifacts/boot_stock_device.img $$f | tail -1 \
	      | sed "s|^|$$v/$$m: |"; \
	  done; \
	done

list:
	@echo "variant              root  susfs  docker  notes"
	@echo "noroot               -     -      -       stock feature set, no KernelSU"
	@echo "ksu                  yes   -      -       KernelSU v3.3.1 (uapi 5)"
	@echo "ksu-susfs            yes   full   -       + SUS_MOUNT, auto-add (TRY_UMOUNT n/a)"
	@echo "ksu-droidspaces      yes   -      yes     cgroups/sysvipc/netfilter/macvlan"
	@echo "ksu-droidspaces-susfs yes  part.  yes     SUSFS without SUS_MOUNT/try_umount"
	@echo
	@echo "each variant has an enforcing and a permissive build -> 10 images"
	@echo "permissive = variants 1-3 are permissive from boot; variants 4-5 boot"
	@echo "             enforcing and flip at dby_perm_delay seconds (20), because"
	@echo "             early permissive + the container options trips Huawei's"
	@echo "             bootfail loop.  PERM_DELAY=NN overrides at build time."

distclean:
	rm -rf $(foreach v,$(VARIANTS),out/$(v)) out/images
