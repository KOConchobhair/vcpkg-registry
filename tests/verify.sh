#!/bin/bash
# Checks that a completed install actually has the shape the manifest asked for.
#
#   verify.sh <triplet> [installed-root]
#
# Run by tests/run.sh after a successful build, by ./tests/build.sh <arch> verify,
# and by the GitHub Actions workflow.
#
# Deliberately no `pipefail`. Every check here is a pipeline used as a condition,
# and `grep -q` exits as soon as it matches, which SIGPIPEs the producer - under
# pipefail a successful match reads as a failed pipeline. That silently inverted
# three of these checks. Matches are captured into variables and tested for
# emptiness instead, so the pipeline's exit status is never load-bearing.
set -u

TRIPLET="${1:?triplet required}"
INSTALLED="${2:-/work/installed}"
LIB="$INSTALLED/$TRIPLET/lib"
fail=0
skipped=0

ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
skip() { printf '  skip  %s\n' "$1"; skipped=$((skipped+1)); }

# Everything below is expressed per-platform rather than assuming ELF. The file
# naming and the binary-inspection tooling both differ, and pretending otherwise
# would turn the Windows and macOS runs into checks that cannot fail.
case "$TRIPLET" in
  *-windows*) OS=windows; STATIC_EXT=lib; SHARED_EXT=dll;   LIBPFX="";   TLS_BACKEND=schannel ;;
  *-ios*)     OS=ios;     STATIC_EXT=a;   SHARED_EXT=dylib; LIBPFX=lib;  TLS_BACKEND=securetransport ;;
  *-osx*)     OS=osx;     STATIC_EXT=a;   SHARED_EXT=dylib; LIBPFX=lib;  TLS_BACKEND=securetransport ;;
  *-android*) OS=android; STATIC_EXT=a;   SHARED_EXT=so;    LIBPFX=lib;  TLS_BACKEND=openssl ;;
  *)          OS=linux;   STATIC_EXT=a;   SHARED_EXT=so;    LIBPFX=lib;  TLS_BACKEND=openssl ;;
esac
# Shared libraries live in bin/ on Windows; the import .lib stays in lib/.
case "$OS" in windows) SHAREDDIR="$INSTALLED/$TRIPLET/bin" ;; *) SHAREDDIR="$LIB" ;; esac

# Names a shared library links, one per line - the platform's DT_NEEDED analogue.
needed_libs() {
  case "$OS" in
    linux|android) readelf -d "$@" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' ;;
    osx|ios)       otool -L "$@" 2>/dev/null | sed -n 's|^\t\([^ ]*\).*|\1|p' | xargs -n1 basename 2>/dev/null ;;
    *)             return 0 ;;   # no dumpbin guarantee on a bash runner; callers skip instead
  esac
}

# The port passes OPENCV_DLLVERSION=4, so modules land as libopencv_core4.a
# rather than libopencv_core.a. Match both, and match exactly - a glob would
# make the "video must be absent" check pass or fail on libopencv_videoio4.a,
# which is a different module and is legitimately present.
have_module() {
  for n in "${LIBPFX}opencv_$1" "${LIBPFX}opencv_${1}4"; do
    for e in "$STATIC_EXT" "$SHARED_EXT"; do
      [ -f "$LIB/$n.$e" ] && return 0
    done
  done
  return 1
}

# Qt libraries are libQt6Core.so / libQt6Core.dylib / Qt6Core.dll (+ Qt6Core.lib).
# Qt lands as a shared library, a static library, or - on macOS with the framework
# feature - a Qt6Xxx.framework bundle with the binary inside it.
have_qt() {
  local n
  for n in "${LIBPFX}Qt6$1.$SHARED_EXT" "Qt6$1.$SHARED_EXT" \
           "${LIBPFX}Qt6$1.$STATIC_EXT" "Qt6$1.$STATIC_EXT"; do
    [ -f "$LIB/$n" ] && return 0
    [ -f "$SHAREDDIR/$n" ] && return 0
  done
  [ -f "$LIB/Qt6$1.framework/Qt6$1" ] && return 0
  return 1
}

echo "=== verifying $TRIPLET ==="
echo "opencv4 modules that must be built:"
for m in core imgproc imgcodecs dnn features2d; do
  have_module "$m" && ok "opencv_$m" || bad "opencv_$m missing"
done

echo "opencv4 modules that must NOT be built (parity with ci/build_opencv.sh):"
for m in calib3d flann objdetect photo stitching video gapi highgui ts; do
  have_module "$m" && bad "opencv_$m present, should be excluded" || ok "opencv_$m absent"
done

# The triplets pass -fvisibility=hidden for opencv, matching ci/build_opencv.sh.
# With it, every defined global in the archive is HIDDEN; without it they are
# DEFAULT and would be re-exported from whatever shared library links opencv in.
echo "opencv4 built with hidden visibility (triplet parity):"
core=$(ls "$LIB"/libopencv_core*.a 2>/dev/null | head -1)
if [ "$OS" != linux ] && [ "$OS" != android ]; then
  skip "readelf-based visibility check needs ELF (Windows has no -fvisibility at all)"
elif [ -z "$core" ]; then
  bad "no libopencv_core archive to inspect"
else
  vis=$(readelf -sW "$core" 2>/dev/null | awk '$5=="GLOBAL" && $7!="UND" {print $6}' | sort | uniq -c)
  ndefault=$(echo "$vis" | awk '$2=="DEFAULT" {print $1}')
  nhidden=$(echo "$vis" | awk '$2=="HIDDEN" {print $1}')
  if [ -n "$nhidden" ] && [ -z "$ndefault" ]; then
    ok "all $nhidden defined globals are HIDDEN, none DEFAULT"
  else
    bad "visibility not applied: ${nhidden:-0} HIDDEN, ${ndefault:-0} DEFAULT"
  fi
fi

echo "qtbase libraries that must be built:"
for m in Core Network Concurrent; do
  have_qt "$m" && ok "Qt6$m" || bad "Qt6$m missing"
done

# macOS is the exception: the qtbase port self-depends on cups there
# ("platform": "osx"), and cups -> widgets -> gui -> opengl, so those three arrive
# whether or not anyone asked for them. Headless Qt is simply not achievable on
# macOS with this port. Asserted as expected-present rather than skipped, so that
# an upstream change to that self-dependency shows up as a test result.
if [ "$OS" = osx ]; then
  echo "qtbase GUI modules, unavoidable on macOS (port self-depends on cups):"
  for m in Gui Widgets OpenGL; do
    have_qt "$m" && ok "Qt6$m present, as expected on macOS" \
      || bad "Qt6$m absent - the cups self-dependency may be gone; update the README"
  done
  echo "qtbase libraries that must NOT be built:"
  for m in Sql Test DBus; do
    have_qt "$m" && bad "Qt6$m present, should be excluded" || ok "Qt6$m absent"
  done
else
  echo "qtbase libraries that must NOT be built:"
  for m in Gui Widgets Sql Test DBus OpenGL; do
    have_qt "$m" && bad "Qt6$m present, should be excluded" || ok "Qt6$m absent"
  done
fi

# Asserted present, not absent. build_qt6.sh passes -no-feature-xml, but the port
# hard-enables FEATURE_xml because moc is built from it - the one Qt parity gap
# the README records. Pinning it here means an upstream change shows up as a test
# result rather than as a surprise.
echo "known parity gap: Qt xml cannot be disabled, so Qt6Xml is expected:"
have_qt Xml && ok "Qt6Xml present, as documented" \
  || bad "Qt6Xml absent - upstream may have made FEATURE_xml optional; update the README"

# macOS is the only platform where the framework feature applies: qtbase declares it
# "osx & !static", so it needs the dynamic linkage arm64-osx gives qtbase. iOS gets
# static archives instead - see triplets/arm64-ios.cmake.
if [ "$OS" = osx ]; then
  echo "macOS framework build:"
  [ -d "$LIB/Qt6Core.framework" ] && ok "Qt6Core.framework present" \
    || bad "Qt6Core.framework missing - the framework feature did not take effect"
elif [ "$OS" = ios ]; then
  skip "frameworks are unavailable on ios (feature is osx & !static); static archives expected"
fi

# Since Qt 6.2 the TLS backends are plugins, so the Qt libraries themselves never
# link the TLS stack - the interesting facts live in the plugin. Each platform is
# meant to get a different backend, which is exactly what the manifest's
# platform-qualified features select, so the first check is simply: did this
# platform produce its own backend and not somebody else's?
echo "TLS backend plugin for ${OS} must be ${TLS_BACKEND}:"
plugin_for() { find "$INSTALLED/$TRIPLET" -name "*q${1}backend*.${SHARED_EXT}" -print -quit 2>/dev/null; }
plugin=$(plugin_for "$TLS_BACKEND")
if [ -z "$plugin" ]; then
  bad "no q${TLS_BACKEND}backend plugin - the platform's TLS feature produced no backend"
else
  ok "plugin at ${plugin#$INSTALLED/$TRIPLET/}"
fi
for other in openssl schannel securetransport; do
  [ "$other" = "$TLS_BACKEND" ] && continue
  if [ -n "$(plugin_for "$other")" ]; then
    bad "q${other}backend is also present - a backend for another platform leaked in"
  fi
done

# On the OpenSSL platforms there is a second question: linked or dlopened. That
# distinction lives entirely in the plugin, so checking the Qt libraries instead
# would pass either way and would not be a check at all.
#   linked  -> the plugin links libssl/libcrypto
#   runtime -> it links neither, and resolves the names through QLibrary
# Which to expect comes from the manifest rather than being hard-coded, so this
# stays honest if the TLS choice is ever revisited.
MANIFEST="$(dirname "$0")/vcpkg.json"
if grep -q '"openssl-runtime"' "$MANIFEST" 2>/dev/null; then WANT=runtime; else WANT=linked; fi

if [ "$TLS_BACKEND" != openssl ]; then
  skip "linked-vs-runtime is an OpenSSL question; ${OS} uses ${TLS_BACKEND}"
elif [ "$OS" = windows ]; then
  skip "no reliable link-inspection tool on a bash Windows runner"
elif [ -n "$plugin" ]; then
  echo "OpenSSL plugin must be ${WANT} (per tests/vcpkg.json):"
  needed=$(needed_libs "$plugin" | grep -E 'libssl|libcrypto')
  if [ "$WANT" = linked ]; then
    [ -n "$needed" ] && ok "plugin links OpenSSL: $(echo $needed | tr '\n' ' ')" \
                     || bad "plugin does not link OpenSSL - INPUT_openssl=linked did not take effect"
  else
    if [ -n "$needed" ]; then
      bad "plugin links OpenSSL - INPUT_openssl=runtime did not take effect: $(echo $needed | tr '\n' ' ')"
    else
      ok "plugin links neither libssl nor libcrypto"
    fi
    # Positive control, so "does not link OpenSSL" cannot be satisfied by a plugin
    # with no OpenSSL support at all. Qt resolves through QLibrary and builds the
    # name at run time (QLibrary("ssl", "3")), so there is no literal "libssl.so"
    # to look for - what shows up is undefined QLibrary symbols and bare names.
    qlib=$(nm -D --undefined-only "$plugin" 2>/dev/null | grep QLibrary)
    [ -n "$qlib" ] && ok "plugin imports QLibrary - the run-time resolver is compiled in" \
                   || bad "plugin does not import QLibrary - OpenSSL would be unreachable"
    # Informational, not an assertion. Whether the bare library names survive as
    # standalone strings depends on the compiler's string merging: gcc on aarch64
    # emits "crypto" on its own, gcc on x86_64 does not, and that difference is
    # not a defect. The QLibrary import above is the real positive control.
    names=$(strings "$plugin" | grep -xE 'ssl|crypto')
    [ -n "$names" ] && ok "bare OpenSSL name(s) also visible: $(echo $names | tr '\n' ' ')" \
                    || skip "bare OpenSSL names not separately visible (compiler string merging)"
  fi
fi

# With INPUT_openssl=linked, QtNetwork itself links libcrypto for the parts of the
# API outside the backend plugin, so the shipped library is bound to a specific
# soname. Under runtime nothing is - which is the whole reason that mode exists.
if [ "$OS" = windows ]; then
  skip "Qt library link inspection needs readelf/otool"
else
  echo "Qt libraries linking OpenSSL (expected under ${WANT} on ${OS}):"
  qt_ssl=$(needed_libs "$LIB"/${LIBPFX}Qt6*.${SHARED_EXT} | grep -E 'libssl|libcrypto' | sort -u | tr '\n' ' ')
  if [ "$TLS_BACKEND" != openssl ]; then
    [ -z "$qt_ssl" ] && ok "none - ${OS} uses ${TLS_BACKEND}, so OpenSSL is absent entirely" \
                     || bad "bound to $qt_ssl despite using ${TLS_BACKEND}"
  elif [ "$WANT" = linked ]; then
    [ -n "$qt_ssl" ] && ok "bound to $qt_ssl - expected, linked mode" \
                     || ok "none (backend confined to the plugin)"
  else
    [ -z "$qt_ssl" ] && ok "none - nothing is bound to an OpenSSL soname" \
                     || bad "bound to $qt_ssl despite runtime mode"
  fi

  echo "no-icu parity: no Qt library may link ICU:"
  qt_icu=$(needed_libs "$LIB"/${LIBPFX}Qt6*.${SHARED_EXT} | grep -E 'libicu|ICU')
  [ -z "$qt_icu" ] && ok "no link against ICU" \
                   || bad "links ICU: $(echo $qt_icu | tr '\n' ' ')"
fi

echo
if [ "$fail" = 0 ]; then
  if [ "$skipped" -gt 0 ]; then
    echo "=== $TRIPLET: all checks passed ($skipped skipped as platform-inapplicable) ==="
  else
    echo "=== $TRIPLET: all checks passed ==="
  fi
else
  echo "=== $TRIPLET: FAILURES ==="
fi
exit "$fail"
