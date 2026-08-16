#!/bin/bash
# Installs tests/vcpkg.json against this registry and checks the result.
#
# One implementation, two environments. Paths come from the environment so the
# same script serves the local docker harness and the GitHub Actions runners:
#
#   REGISTRY  this registry checkout                     (default /registry)
#   WORK      vcpkg root, buildtrees, install tree       (default /work)
#   VCPKG_DOWNLOADS               shared source tarballs (default /downloads)
#   VCPKG_DEFAULT_BINARY_CACHE    binary cache           (default /cache)
#   VCPKG_BASELINE                upstream commit to bootstrap the vcpkg tool at
#   REGISTRY_HEAD                 commit the registry modes resolve against
#
# Optional, and only set in CI - a NuGet feed used as the binary cache. When it is
# configured it replaces the local files cache; without it, VCPKG_DEFAULT_BINARY_CACHE
# is used as normal, which is what local runs do:
#
#   VCPKG_NUGET_FEED   feed index URL; enables the block when set with a token
#   VCPKG_NUGET_TOKEN  password and API key for that feed
#   VCPKG_NUGET_USER   feed username                          (default vcpkg)
#   VCPKG_NUGET_MODE   read, write or readwrite               (default readwrite)
#
# Locally: driven by ./tests/build.sh, which supplies container mounts.
# In CI: called directly with runner paths, see .github/workflows/ports.yml.
#
# Every mode is vcpkg manifest mode - an install driven by tests/vcpkg.json. There
# is no classic-mode path here and none is wanted.
#
#   consumer   build tests/vcpkg.json through the registry, then verify. The test.
#   resolve    the same, resolution only - no compiling
#   overlay    the same, but --overlay-ports for the working tree. Dev loop only:
#              it bypasses versions/, so it proves nothing about the registry.
#   verify     re-check an existing install tree
#
# consumer and resolve read the *committed* tree, so commit before running them.
set -euo pipefail

TRIPLET="${1:?triplet required}"
MODE="${2:-consumer}"

# For a cross target the host triplet must be the machine doing the building -
# android and ios binaries cannot run here, and vcpkg needs host tools (moc, and
# the host qtbase behind it) it can actually execute. Defaults to the target, which
# is right for the four native triplets.
HOST_TRIPLET="${HOST_TRIPLET:-$TRIPLET}"

# Windows runs this under Git Bash, where the paths handed in by Actions are
# Windows-native (D:\a\_temp). cygpath -m converts them to the mixed form
# (D:/a/_temp) that both bash and vcpkg.exe accept.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; npath() { cygpath -m "$1"; } ;;
  *)                    IS_WINDOWS=0; npath() { printf '%s' "$1"; } ;;
esac
PY_BIN=python3; command -v python3 >/dev/null 2>&1 || PY_BIN=python

REGISTRY="$(npath "${REGISTRY:-/registry}")"
WORK="$(npath "${WORK:-/work}")"
export VCPKG_DOWNLOADS="$(npath "${VCPKG_DOWNLOADS:-/downloads}")"
export VCPKG_DEFAULT_BINARY_CACHE="$(npath "${VCPKG_DEFAULT_BINARY_CACHE:-/cache}")"
export VCPKG_ROOT="$WORK/vcpkg"

# Use vcpkg's own cmake/ninja, never the host's.
#
# The ubuntu-22.04-arm runner ships cmake 3.31.6 at /usr/local/bin and vcpkg picks
# it up rather than downloading its own 4.4.0. vcpkg at this baseline emits
# string(JSON ... STRING_ENCODE) from z_vcpkg_spdx.cmake, which needs cmake 4.2+,
# so any port reaching that path dies with "string sub-command JSON got an invalid
# mode 'STRING_ENCODE'" - openssl does, which is where CI failed. The x64 image
# happens to carry a newer cmake, which is why only the arm64 leg broke.
#
# The local container has no cmake at all, so vcpkg always downloads its own there
# and this could not be reproduced locally even with cmake 3.31.6 on PATH - which
# means something in the runner environment is what tips vcpkg toward system tools.
# Rather than rely on which of the two switches wins, clear one and set the other:
# after this, the tool choice does not depend on the host at all.
unset VCPKG_FORCE_SYSTEM_BINARIES
export VCPKG_FORCE_DOWNLOADED_BINARIES=1

# Prerequisites come from tests/apt-packages.txt on Linux (installed by
# tests/Dockerfile locally, or by the workflow), from brew on macOS, and from the
# preinstalled toolchain on Windows. cmake and ninja are deliberately absent
# everywhere - vcpkg fetches its own; see apt-packages.txt for why.
[ "$IS_WINDOWS" = 1 ] || cc --version | head -1

mkdir -p "$WORK" "$VCPKG_DOWNLOADS" "$VCPKG_DEFAULT_BINARY_CACHE"

# The checkout may be owned by another user (bind mount, or a CI cache restore),
# and the registry modes clone from it.
git config --global --add safe.directory "$REGISTRY" 2>/dev/null || true

# Every mode redirects the registry (see localize_registry), so this must always
# have a value - not only in the modes that resolve against it. Callers that care
# which commit is tested pass it in; anyone else gets HEAD of the checkout. Under
# `set -u` the fallback is the difference between working and an unbound variable.
REGISTRY_HEAD="${REGISTRY_HEAD:-$(git -C "$REGISTRY" rev-parse HEAD)}"

if [ "$MODE" = verify ]; then
  exec bash "$REGISTRY/tests/verify.sh" "$TRIPLET" "$WORK/installed"
fi

if [ "$IS_WINDOWS" = 1 ]; then VCPKG="$VCPKG_ROOT/vcpkg.exe"; else VCPKG="$VCPKG_ROOT/vcpkg"; fi
if [ ! -x "$VCPKG" ]; then
  echo "=== bootstrapping vcpkg @ ${VCPKG_BASELINE} ==="
  # Deliberately NOT a blobless clone. builtin-baseline makes vcpkg check out port
  # trees straight out of this repository, including historical ones - protobuf
  # 3.19.4 is from 2022 - and under --filter=blob:none every one of those checkouts
  # becomes an on-demand fetch from the promisor remote. That is slow everywhere and
  # it broke x64-windows outright: "could not fetch ... from promisor remote /
  # Could not resolve host: github.com", after vcpkg had already downloaded its own
  # PortableGit. The Linux legs made the same fetches and merely got away with it.
  # A complete clone costs more up front and needs no network afterwards.
  git clone --no-checkout https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
  git -C "$VCPKG_ROOT" checkout -q "${VCPKG_BASELINE}"
  if [ "$IS_WINDOWS" = 1 ]; then
    "$VCPKG_ROOT/bootstrap-vcpkg.bat" -disableMetrics
  else
    "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
  fi
fi

# NuGet binary cache. In CI this is the only binary cache: the list is prefixed
# with "clear", which drops the default files provider.
#
# That is deliberate rather than cosmetic. Nothing persists
# $VCPKG_DEFAULT_BINARY_CACHE between runs any more, so leaving the files provider
# on would write a zip of every restored package to runner disk for no one to read
# - real cost on the legs that already have to reclaim space before building.
#
# This lives here rather than in the workflow because the nuget.exe involved is
# vcpkg's own, and vcpkg does not exist until the bootstrap above has run. Both
# variables are absent on a local run, which skips the block entirely and leaves
# the local files cache in charge - tests/build.sh depends on that.
if [ -n "${VCPKG_NUGET_FEED:-}" ] && [ -n "${VCPKG_NUGET_TOKEN:-}" ]; then
  echo "=== configuring NuGet binary cache: $VCPKG_NUGET_FEED ==="
  NUGET="$("$VCPKG" fetch nuget | tail -n 1)"
  # nuget.exe is a .NET assembly. Windows runs it directly; everywhere else needs
  # mono - preinstalled on the ubuntu-22.04 images, brew-installed on macOS.
  if [ "$IS_WINDOWS" = 1 ]; then
    run_nuget() { "$NUGET" "$@"; }
  else
    if ! command -v mono >/dev/null 2>&1; then
      echo "error: mono is required to run nuget.exe on $(uname -s), and is not installed." >&2
      echo "       ubuntu-22.04 ships it; newer ubuntu images do not, and macOS needs brew." >&2
      echo "       Add mono-complete to tests/apt-packages.txt, or drop nuget from this" >&2
      echo "       leg's matrix entry in .github/workflows/ports.yml." >&2
      exit 1
    fi
    run_nuget() { mono "$NUGET" "$@"; }
  fi
  # Not silenced: if the cache cannot be configured, that is the thing being
  # tested, and a green leg that quietly stopped using the feed would be worse
  # than a red one.
  run_nuget sources add \
    -Source "$VCPKG_NUGET_FEED" \
    -StorePasswordInClearText \
    -Name GitHubPackages \
    -UserName "${VCPKG_NUGET_USER:-vcpkg}" \
    -Password "$VCPKG_NUGET_TOKEN"
  run_nuget setapikey "$VCPKG_NUGET_TOKEN" -Source "$VCPKG_NUGET_FEED"
  export VCPKG_BINARY_SOURCES="clear;nuget,${VCPKG_NUGET_FEED},${VCPKG_NUGET_MODE:-readwrite}"
  echo "VCPKG_BINARY_SOURCES=$VCPKG_BINARY_SOURCES"
fi

# The manifest's overlay-triplets is "../triplets", resolved relative to the
# manifest, so the manifest cannot simply be copied somewhere flat. Stage tests/
# and triplets/ together and keep their relative layout intact.
STAGE="$WORK/consumer"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -r "$REGISTRY/tests" "$STAGE/tests"
cp -r "$REGISTRY/triplets" "$STAGE/triplets"
MANIFEST="$STAGE/tests/vcpkg.json"

ARGS=(
  install
  --x-manifest-root="$STAGE/tests"
  --triplet="$TRIPLET"
  --host-triplet="$HOST_TRIPLET"
  --x-install-root="$WORK/installed"
  --x-buildtrees-root="$WORK/buildtrees"
  --x-packages-root="$WORK/packages"
  --clean-buildtrees-after-build
)

# The committed manifest names this registry by its public URL and a pinned
# baseline - that is the artifact a consumer copies. To test the commit in front
# of us rather than whatever was last pushed, point it at the local checkout and
# at REGISTRY_HEAD. Nothing else in the file is touched. Set USE_MANIFEST_AS_IS=1
# to run it exactly as committed, which only works once that baseline is pushed.
localize_registry() {
  if [ "${USE_MANIFEST_AS_IS:-0}" = 1 ]; then
    echo "=== manifest used as committed (public URL, pinned baseline) ==="
    return
  fi
  echo "=== registry redirected to local checkout @ ${REGISTRY_HEAD} ==="
  "$PY_BIN" - "$MANIFEST" "$REGISTRY" "$REGISTRY_HEAD" <<'PY'
import json, sys
path, repo, head = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(path))
regs = m['vcpkg-configuration']['registries']
roc = [r for r in regs if 'vcpkg-registry' in r.get('repository', '')]
assert len(roc) == 1, f"expected exactly one roc registry, found {len(roc)}"
roc[0]['repository'] = repo
roc[0]['baseline'] = head
json.dump(m, open(path, 'w'), indent=2)
PY
}

# Always redirected, in every mode. overlay mode supersedes the registry with
# --overlay-ports and would not consult it, but vcpkg still reads the
# configuration, and the committed baseline may not be pushed yet.
localize_registry

# The manifest is meant to have two flavours: headless by default, and headless
# PLUS Qt GUI when the gui feature is on. vcpkg unions feature requests across the
# graph, so the gui edge lists only what it adds - but that additivity is exactly
# the kind of thing a later "tidy-up" breaks silently, and neither flavour would
# fail to build if it regressed. So assert it, from resolution alone, in seconds.
check_gui_flavor() {
  local base gui missing
  # Surface vcpkg's own error rather than discarding it. An earlier version sent
  # stderr to /dev/null, so a resolution failure here showed up as "could not
  # resolve one of the flavours" with no hint why - or, under `set -e`, as a bare
  # non-zero exit with no output at all.
  qt_features() {
    local out rc
    out=$("$VCPKG" "${ARGS[@]}" --dry-run ${1:+--x-feature=$1} 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "  FAIL  resolving the ${1:-headless} flavour failed (exit $rc):" >&2
      printf '%s\n' "$out" | tail -30 | sed 's/^/        /' >&2
      return "$rc"
    fi
    # Parsed with python3, not sed: BSD sed (macOS) has no \? operator, so the
    # previous expression matched nothing there and both Apple legs failed as
    # "found no qtbase line" while the plan plainly contained one.
    local parsed
    parsed=$(printf '%s\n' "$out" | "$PY_BIN" -c '
import re,sys
# Anchor on the target triplet. A cross build plans two qtbase packages - the
# target one and a host one for moc - and taking whichever came first picked the
# host on android, reporting a desktop Linux feature set as if it were the
# Android target.
triplet = sys.argv[1]
for line in sys.stdin:
    m = re.match(r"\s*\*?\s*qtbase\[([^]]*)\]:" + re.escape(triplet) + r"\b", line)
    if m:
        print(m.group(1).replace(",", " ")); break
' "$TRIPLET")
    if [ -z "$parsed" ]; then
      # Exited 0 but the plan had no qtbase line. Dump what it did say - guessing
      # from an empty feature list is what made the macOS failure undiagnosable.
      echo "  FAIL  resolved the ${1:-headless} flavour but found no qtbase line in the plan:" >&2
      printf '%s\n' "$out" | tail -40 | sed 's/^/        /' >&2
      return 1
    fi
    printf '%s\n' "$parsed"
  }
  echo "=== qtbase flavours ==="
  base=$(qt_features)  || return 1
  case "$TRIPLET" in
    *-ios*|*-android*)
      echo "  headless   : ${base}"
      echo "  skip  gui is desktop-only; tests/vcpkg.json does not offer it here"
      return 0
      ;;
  esac
  gui=$(qt_features gui) || return 1
  echo "  headless   : ${base}"
  echo "  + gui      : ${gui}"
  if [ -z "$base" ] || [ -z "$gui" ]; then
    echo "  FAIL  could not resolve one of the flavours" >&2; return 1
  fi
  # gui must be a superset of headless - it adds, it does not replace.
  missing=""
  for f in $base; do case " $gui " in *" $f "*) ;; *) missing="$missing $f" ;; esac; done
  if [ -n "$missing" ]; then
    echo "  FAIL  the gui flavour dropped:$missing" >&2; return 1
  fi
  for f in gui widgets; do
    case " $gui " in *" $f "*) ;; *) echo "  FAIL  gui flavour is missing $f" >&2; return 1 ;; esac
  done
  # Skipped on macOS: the qtbase port self-depends on cups there
  # ("platform": "osx"), and cups -> widgets -> gui, so gui and widgets are in the
  # base flavour whether or not anyone asked. Headless Qt is not achievable on
  # macOS with this port; it is on linux, android, ios and windows.
  case "$TRIPLET" in
    *-osx*) echo "  skip  gui/widgets are unavoidable on macOS (port self-depends on cups)" ;;
    *)
      for f in gui widgets; do
        case " $base " in *" $f "*) echo "  FAIL  $f present without the gui feature" >&2; return 1 ;; esac
      done
      ;;
  esac
  echo "  ok    gui is additive: headless set intact, plus gui and widgets"
}

case "$MODE" in
  resolve)  check_gui_flavor; ARGS+=(--dry-run) ;;
  consumer) check_gui_flavor ;;
  overlay)  ARGS+=(--overlay-ports="$REGISTRY/ports") ;;
  *)
    echo "mode must be consumer, resolve, overlay or verify" >&2
    exit 2
    ;;
esac

echo "=== vcpkg ${MODE} ${TRIPLET} (host ${HOST_TRIPLET}) ==="
"$VCPKG" "${ARGS[@]}"

case "$MODE" in
  consumer|overlay)
    echo
    bash "$REGISTRY/tests/verify.sh" "$TRIPLET" "$WORK/installed"
    ;;
esac
