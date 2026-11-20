#!/usr/bin/env bash
# Build the DBY-W09 boot images inside a container.
#
#   docker/run.sh [options] [--] [command ...]
#
# The repository is bind-mounted at /work and the image carries the pinned
# toolchain, so nothing is installed on the host. The build writes its output
# straight into your checkout (out/, artifacts/, output/) as your own uid.
#
# Options:
#   -b, --build        rebuild the image before running
#       --build-only   build the image and exit (no container started)
#       --no-build     never build the image, fail if it is missing
#   -s, --shell        interactive shell instead of the default command
#   -j, --jobs N       parallel jobs for make (default: nproc on the host)
#   -t, --tarball PATH kernel tarball to use; also works when it lives outside
#                      the repo (it is mounted read-only and DBY_TARBALL is set
#                      for you, the default name is looked up in the repo root)
#   -h, --help         this text
#
# Environment:
#   DBY_DOCKER_IMAGE   image tag (default dby-w09-kernel-builder:latest)
#   DOCKER             container CLI to use (default docker)
#   DBY_DOCKER_ARGS    extra `docker run` arguments, e.g. '--network host' or
#                      '--security-opt label=disable' (SELinux hosts)
#   DBY_APT_MIRROR     apt mirror for the image build, e.g. mirrors.tuna.tsinghua.edu.cn
#   DBY_UBUNTU_ARCHIVE mirror for the toolchain debs
#   DBY_PLATFORM       --platform for `docker build`, e.g. linux/amd64 on arm64
#   KSU_URL, KSU_COMMIT, KSU_DIR, KSU_TARBALL, DBY_SKIP_SHA, PERM_MODE, PERM_DELAY
#                      forwarded to the scripts inside the container when set
#
# Default command: `make images`, or `make bootstrap images` when src/kernel has
# not been prepared yet (the extraction and patching then happen in the
# container; only downloading the Huawei tarball and dumping the boot image stay
# on the host).
set -euo pipefail

WS=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOCKER=${DOCKER:-docker}
IMAGE=${DBY_DOCKER_IMAGE:-dby-w09-kernel-builder:latest}
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 8)}

usage() { awk 'NR>1 && /^set -euo/{exit} NR>1{print}' "$0"; }

BUILD=auto          # auto | force | never
NO_BUILD=0
IMAGE_ONLY=0
SHELL_MODE=0
TARBALL=""

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--build) BUILD=force ;;
    --build-only) BUILD=force; IMAGE_ONLY=1 ;;
    --no-build) BUILD=never; NO_BUILD=1 ;;
    -s|--shell) SHELL_MODE=1 ;;
    -j|--jobs)
      shift
      [ $# -gt 0 ] || { echo "error: --jobs needs a number" >&2; exit 2; }
      JOBS=$1
      ;;
    -j*) JOBS=${1#-j} ;;
    -t|--tarball)
      shift
      [ $# -gt 0 ] || { echo "error: --tarball needs a path" >&2; exit 2; }
      TARBALL=$1
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "error: unknown option '$1' (try --help)" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
CMD=("$@")

case "$JOBS" in
  ''|*[!0-9]*) echo "error: jobs must be a number, got '$JOBS'" >&2; exit 2 ;;
esac

if [ "$IMAGE_ONLY" = "1" ] && [ "$NO_BUILD" = "1" ]; then
  echo "error: --build-only and --no-build contradict each other" >&2
  exit 2
fi
if [ "$SHELL_MODE" = "1" ] && [ ${#CMD[@]} -gt 0 ]; then
  echo "error: --shell does not take a command (got '${CMD[*]}')" >&2
  exit 2
fi

if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || { echo "error: $TARBALL is not a file" >&2; exit 2; }
  TARBALL=$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")
fi

command -v "$DOCKER" >/dev/null 2>&1 || {
  echo "error: '$DOCKER' not found." >&2
  echo "       install docker (or podman: DOCKER=podman docker/run.sh ...)" >&2
  exit 1
}

image_exists() { "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1; }

build_image() {
  local -a a=()
  if [ -n "${DBY_PLATFORM:-}" ]; then a+=(--platform "$DBY_PLATFORM"); fi
  if [ -n "${DBY_APT_MIRROR:-}" ]; then a+=(--build-arg "APT_MIRROR=$DBY_APT_MIRROR"); fi
  if [ -n "${DBY_UBUNTU_ARCHIVE:-}" ]; then a+=(--build-arg "UBUNTU_ARCHIVE=$DBY_UBUNTU_ARCHIVE"); fi
  echo "== building image $IMAGE (first build: apt packages + pinned toolchain)"
  "$DOCKER" build ${a[@]+"${a[@]}"} -f "$WS/docker/Dockerfile" -t "$IMAGE" "$WS"
}

case "$BUILD" in
  force) build_image ;;
  never) image_exists || {
           echo "error: image $IMAGE not found and --no-build was given" >&2
           echo "       build it with: docker/run.sh --build-only" >&2
           exit 1
         } ;;
  auto) image_exists || build_image ;;
esac
if [ "$IMAGE_ONLY" = "1" ]; then
  echo "== image ready: $IMAGE"
  exit 0
fi

run_args=(--rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e "JOBS=$JOBS")
if [ -t 0 ] && [ -t 1 ]; then run_args+=(-it); fi

# Pass the knobs of scripts/fetch_sources.sh and build_variant.sh through when
# they are set on the host; paths inside the repo are visible at /work.
for v in KSU_URL KSU_COMMIT KSU_DIR KSU_TARBALL DBY_SKIP_SHA PERM_MODE PERM_DELAY; do
  eval "val=\${$v:-}"
  if [ -n "$val" ]; then run_args+=(-e "$v=$val"); fi
done

if [ -n "$TARBALL" ]; then
  base=$(basename "$TARBALL")
  run_args+=(-v "$TARBALL:/mnt/dby/$base:ro" -e "DBY_TARBALL=/mnt/dby/$base")
fi

if [ -n "${DBY_DOCKER_ARGS:-}" ]; then
  read -r -a extra <<<"$DBY_DOCKER_ARGS"
  run_args+=("${extra[@]}")
fi

if [ "$SHELL_MODE" = "1" ]; then
  CMD=(bash -l)
elif [ ${#CMD[@]} -eq 0 ]; then
  if [ -f "$WS/src/kernel/.dby_prepared" ]; then
    CMD=(make images)
  else
    echo "== sources not prepared yet: extracting and patching them in the container"
    CMD=(make bootstrap images)
  fi
fi

echo "== ${DOCKER} run ${IMAGE} ${CMD[*]}"
exec "$DOCKER" run "${run_args[@]}" -v "$WS:/work" -w /work "$IMAGE" "${CMD[@]}"
