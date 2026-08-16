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

# One pass over the installed tree, so lookups match on basename instead of
# assuming a directory layout. Every layout assumption here has now been wrong on
# some platform: Android installs opencv under sdk/native/staticlibs/<abi>/ rather
# than lib/, Qt suffixes its Android libraries with the ABI, static Qt plugins land
# in a plugins/ directory, and Windows splits the .dll from the import .lib.
#
# The failure mode that matters is not the false FAIL - it is that a hard-coded
# lib/ made every "must NOT be built" check on Android pass vacuously. Nothing was
# in the directory being searched, so the excluded modules were "absent" for the
# same reason the required ones were "missing".
#
# Rooted at the triplet, never at $INSTALLED: on the cross-compiling legs the host
# packages sit next door in installed/x64-linux and installed/arm64-osx, and a
# host Qt6Gui would otherwise fail an absence check for the target.
#
# Narrowed to libraries at the find level so match() iterates over a few hundred
# entries rather than the whole tree's tens of thousands of headers.
#
# tools/ is pruned. It holds deployed copies of the runtime libraries next to moc
# and rcc on Windows, which are duplicates for a presence check but would make an
# absence check fail on a module that is only there because a tool links it. The
# TLS plugins are unaffected - they sit in Qt6/plugins/tls on all five platforms.
TREE=$(find "$INSTALLED/$TRIPLET" -path "$INSTALLED/$TRIPLET/tools" -prune -o \
    \( -type f -o -type l \) \
    \( -name '*.a' -o -name '*.so' -o -name '*.so.*' \
       -o -name '*.dylib' -o -name '*.dll' -o -name '*.lib' \) -print 2>/dev/null)

# Paths in the tree whose basename matches any of the given shell globs. The
# patterns are always an exact name plus extension - a bare Qt6Gui* would match
# Qt6GuiTools, and a bare opencv_video* would match opencv_videoio4, which is a
# different module and is legitimately present.
match() {
  local p pat
  printf '%s\n' "$TREE" | while IFS= read -r p; do
    for pat in "$@"; do
      case "${p##*/}" in $pat) printf '%s\n' "$p"; break ;; esac
    done
  done
}

# Names a shared library links, one per line - the platform's DT_NEEDED analogue.
needed_libs() {
  case "$OS" in
    linux|android) readelf -d "$@" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' ;;
    osx|ios)       otool -L "$@" 2>/dev/null | sed -n 's|^\t\([^ ]*\).*|\1|p' | xargs -n1 basename 2>/dev/null ;;
    *)             return 0 ;;   # no dumpbin guarantee on a bash runner; callers skip instead
  esac
}

# The port passes OPENCV_DLLVERSION=4, so modules land as libopencv_core4.a
# rather than libopencv_core.a on most platforms. The Android build numbers them
# differently and installs them somewhere else entirely, so both spellings are
# matched and the search covers the whole tree.
have_module() {
  local n e pats=()
  for n in "${LIBPFX}opencv_$1" "${LIBPFX}opencv_${1}4"; do
    for e in "$STATIC_EXT" "$SHARED_EXT"; do
      pats+=("$n.$e")
    done
  done
  [ -n "$(match "${pats[@]}")" ]
}

# Qt libraries are libQt6Core.so / libQt6Core.dylib / Qt6Core.dll (+ Qt6Core.lib).
# Qt lands as a shared library, a static library, or - on macOS with the framework
# feature - a framework bundle. Note the bundle drops the major version from its
# name: QtCore.framework/Versions/A/QtCore, not Qt6Core. Checking for "Qt6Core"
# there is why every macOS Qt assertion failed against a build that was in fact
# correct.
#
# Android adds a fourth spelling: Qt suffixes every library with the ABI, so Core
# arrives as libQt6Core_arm64-v8a.so. The variant is anchored on the underscore
# rather than written as a bare Qt6Core*, which would also match Qt6CoreTools.
have_qt() {
  local pats=("${LIBPFX}Qt6$1.$SHARED_EXT" "Qt6$1.$SHARED_EXT" \
              "${LIBPFX}Qt6$1.$STATIC_EXT" "Qt6$1.$STATIC_EXT")
  [ "$OS" = android ] && pats+=("${LIBPFX}Qt6${1}_*.$SHARED_EXT" "${LIBPFX}Qt6${1}_*.$STATIC_EXT")
  [ -n "$(match "${pats[@]}")" ] && return 0
  [ -f "$LIB/Qt$1.framework/Versions/A/Qt$1" ] && return 0
  [ -f "$LIB/Qt$1.framework/Qt$1" ] && return 0
  return 1
}

# Every Qt binary, whichever layout is in use - so the link checks below inspect
# something real on macOS instead of globbing for dylibs that a framework build
# never produces and passing vacuously.
qt_binaries() {
  local out=""
  out="$(ls "$LIB"/${LIBPFX}Qt6*."$SHARED_EXT" 2>/dev/null)"
  [ -n "$out" ] || out="$(ls "$LIB"/Qt*.framework/Versions/A/Qt* 2>/dev/null)"
  [ -n "$out" ] || out="$(ls "$LIB"/${LIBPFX}Qt6*."$STATIC_EXT" 2>/dev/null)"
  printf '%s\n' "$out"
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
core=$(match "${LIBPFX}opencv_core.$STATIC_EXT" "${LIBPFX}opencv_core4.$STATIC_EXT" | head -1)
if [ "$OS" = windows ]; then
  skip "the triplet passes no -fvisibility on Windows; there is nothing to check"
elif [ "$OS" = osx ] || [ "$OS" = ios ]; then
  skip "this check reads an ELF symbol table; the same assertion on Mach-O needs nm -m"
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
    echo "        in ${core#$INSTALLED/$TRIPLET/}"
    # Which member objects the DEFAULT symbols are in, and a few of their names.
    # A count on its own does not distinguish "the flag was dropped" from "some
    # third-party code vendored into this archive annotates its API by hand",
    # and those want opposite fixes.
    echo "        archive members contributing DEFAULT globals (top 10):"
    readelf -sW "$core" 2>/dev/null | awk '
      /^File: / { m=$0; sub(/.*\(/, "", m); sub(/\)$/, "", m) }
      $5=="GLOBAL" && $6=="DEFAULT" && $7!="UND" { cnt[m]++ }
      END { for (k in cnt) printf "%8d  %s\n", cnt[k], k }' \
      | sort -rn | head -10 | sed 's/^/        /'
    echo "        sample DEFAULT symbols:"
    syms=$(readelf -sW "$core" 2>/dev/null \
      | awk '$5=="GLOBAL" && $6=="DEFAULT" && $7!="UND" {print $8}' | sort -u)
    printf '%s\n' "$syms" | { c++filt 2>/dev/null || cat; } | head -8 \
      | cut -c1-110 | sed 's/^/          /'
  fi
fi

echo "qtbase libraries that must be built:"
for m in Core Network Concurrent; do
  have_qt "$m" && ok "Qt6$m" || bad "Qt6$m missing"
done

# No macOS exception any more. The qtbase port used to force its own cups feature
# on osx, and cups -> widgets -> gui -> opengl put all three in every build; this
# registry's qtbase drops that (6.11.1#3), so the same assertion holds everywhere.
echo "qtbase libraries that must NOT be built:"
for m in Gui Widgets Sql Test DBus OpenGL; do
  have_qt "$m" && bad "Qt6$m present, should be excluded" || ok "Qt6$m absent"
done

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
  [ -d "$LIB/QtCore.framework" ] && ok "QtCore.framework present" \
    || bad "QtCore.framework missing - the framework feature did not take effect"
elif [ "$OS" = ios ]; then
  skip "frameworks are unavailable on ios (feature is osx & !static); static archives expected"
fi

# Since Qt 6.2 the TLS backends are plugins, so the Qt libraries themselves never
# link the TLS stack - the interesting facts live in the plugin. Each platform is
# meant to get a different backend, which is exactly what the manifest's
# platform-qualified features select, so the first check is simply: did this
# platform produce its own backend and not somebody else's?
echo "TLS backend plugin for ${OS} must be ${TLS_BACKEND}:"
# Both extensions: a static triplet builds the plugin as an archive, so arm64-ios
# produces libqsecuretransportbackend.a and searching only for .dylib found
# nothing at all. Substring rather than exact name, because Android spells the
# same plugin libplugins_tls_qopensslbackend_arm64-v8a.so.
plugin_for() { match "*q${1}backend*.${SHARED_EXT}" "*q${1}backend*.${STATIC_EXT}" | head -1; }
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

# On a static Qt the archive on disk is inert. Qt normally finds and dlopens a
# backend at run time; a static build has nothing to dlopen, which is what qtbase's
# own configure output says:
#
#   Note: Using static linking will disable the use of dynamically loaded plugins.
#   Make sure to import all needed static plugins, or compile needed modules into
#   the library.
#
# So the backend reaches the binary only if the application links its import
# target, which is exactly what vcpkg's usage text for this install tells the
# consumer to do:
#
#   target_link_libraries(main PRIVATE Qt6::Network Qt6::QTlsBackendCertOnlyPlugin
#                         Qt6::QSecureTransportBackendPlugin ...)
#
# iOS is the only triplet this applies to: everywhere else qtbase is dynamic for
# the LGPL, and keeps ordinary run-time plugin loading. Presence of the .a is
# therefore necessary but not sufficient there, so assert what a consumer needs -
# that the plugin is importable - rather than only that it was built.
if [ "$OS" = ios ] && [ -n "$plugin" ]; then
  echo "static Qt: the TLS backend must be importable, not merely present:"
  target=$(find "$INSTALLED/$TRIPLET" -name '*SecureTransportBackendPlugin*.cmake' -print -quit 2>/dev/null)
  if [ -n "$target" ]; then
    ok "import target at ${target#$INSTALLED/$TRIPLET/}"
  else
    bad "no CMake import target for the plugin - a consumer cannot link it, so a"
    echo "        static build would silently have no TLS backend at all."
    echo "        plugin-related CMake files that are present:"
    find "$INSTALLED/$TRIPLET" -name '*Plugin*.cmake' 2>/dev/null \
      | sed "s|^$INSTALLED/$TRIPLET/||" | sort | head -12 | sed 's/^/          /'
  fi
fi

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
  qt_ssl=$(needed_libs $(qt_binaries) | grep -E 'libssl|libcrypto' | sort -u | tr '\n' ' ')
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
  qt_icu=$(needed_libs $(qt_binaries) | grep -E 'libicu|ICU')
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
