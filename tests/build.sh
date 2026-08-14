#!/bin/bash
# Build this registry's ports in an ubuntu:22.04 container, on either
# architecture, from a macOS host running colima.
#
#   ./tests/build.sh arm64            # build tests/vcpkg.json through the registry
#   ./tests/build.sh arm64 resolve    # resolution only, no compiling
#   ./tests/build.sh arm64 overlay    # dev loop: working tree via --overlay-ports
#   ./tests/build.sh arm64 verify     # re-check an existing install without rebuilding
#   ./tests/build.sh x64              # x64 belongs in CI, see tests/README.md
#
# The colima VM must have vmType: vz and rosetta: true for the x64 run
# (check with: colima status; grep -E '^(vmType|rosetta)' ~/.colima/default/colima.yaml).
#
# Only /Users is visible inside the colima VM, so the registry is bind-mounted
# from there and everything else lives in named volumes on the VM's own ext4 —
# which is also what keeps buildtrees off the case-insensitive macOS filesystem.
#
# Source tarballs are shared between the two architectures; the tools vcpkg
# downloads for itself are not. vcpkg names its tool directories by version and
# platform but not by architecture (cmake-4.4.0-linux holds either the aarch64 or
# the x86_64 tree), so one shared downloads volume lets whichever arch ran first
# satisfy the other's cmake and hand it a binary it cannot execute. Hence the
# per-arch mount over /downloads/tools.
set -euo pipefail

ARCH="${1:?usage: build.sh <arm64|x64> [consumer|resolve|overlay|verify]}"
MODE="${2:-consumer}"

case "$ARCH" in
  arm64) PLATFORM=linux/arm64; TRIPLET=arm64-linux ;;
  x64)   PLATFORM=linux/amd64; TRIPLET=x64-linux ;;
  *)     echo "arch must be arm64 or x64" >&2; exit 2 ;;
esac

REGISTRY="$(cd "$(dirname "$0")/.." && pwd)"

# The upstream commit the ports were vendored from, and the baseline the
# consuming project pins. Ports outside this registry come from here.
BASELINE=3c5d90a305ff00ca841f085a74a7ce74ee777dee

# registry and consumer modes resolve against the committed tree, so a dirty tree
# there means you are testing something other than what you are looking at.
REGISTRY_HEAD="$(git -C "$REGISTRY" rev-parse HEAD)"
case "$MODE" in
  consumer|resolve)
    if ! git -C "$REGISTRY" diff-index --quiet HEAD --; then
      echo "warning: working tree is dirty; $MODE mode tests $REGISTRY_HEAD, not your edits" >&2
    fi
    ;;
esac

# resolve only resolves, so it gets its own work volume: vcpkg takes an exclusive
# lock on the install root, and otherwise a resolve check could not run alongside a
# build. verify must share the build's volume, since the install tree is what it
# inspects.
case "$MODE" in
  resolve) WORK="test-resolve-$ARCH" ;;
  *)       WORK="test-work-$ARCH" ;;
esac

for v in "$WORK" "test-downloads" "test-tools-$ARCH" "test-cache"; do
  docker volume create "$v" >/dev/null
done

IMAGE="test-vcpkg-build:$ARCH"
docker build --quiet --platform "$PLATFORM" -t "$IMAGE" -f "$REGISTRY/tests/Dockerfile" "$REGISTRY/tests" >/dev/null

exec docker run --rm --platform "$PLATFORM" \
  -e REGISTRY=/registry \
  -e WORK=/work \
  -e VCPKG_DOWNLOADS=/downloads \
  -e VCPKG_DEFAULT_BINARY_CACHE=/cache \
  -e VCPKG_BASELINE="$BASELINE" \
  -e REGISTRY_HEAD="$REGISTRY_HEAD" \
  -e VCPKG_MAX_CONCURRENCY="${VCPKG_MAX_CONCURRENCY:-6}" \
  -v "$REGISTRY:/registry:ro" \
  -v "$WORK:/work" \
  -v test-downloads:/downloads \
  -v "test-tools-$ARCH:/downloads/tools" \
  -v test-cache:/cache \
  "$IMAGE" bash /registry/tests/run.sh "$TRIPLET" "$MODE"
