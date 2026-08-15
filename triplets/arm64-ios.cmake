# iOS arm64, device. Based on upstream's community triplet
# (triplets/community/arm64-ios.cmake) plus this registry's opencv flags.
#
# EVERYTHING IS STATIC HERE, INCLUDING THE LGPL LIBRARIES.
#
# This is the one triplet that deliberately breaks the rule the other four follow.
# iOS has no practical way to ship and load third-party shared libraries, so
# qtbase, ffmpeg and openssl are linked statically like everything else. That
# forfeits the relinking path the LGPL expects: whoever ships the app takes on the
# obligation to make relinking possible (object files, or an equivalent). The ROC
# SDK already does this on iOS - it is a constraint of the platform, not a
# preference - but it is a legal exposure and not merely a build setting, so it is
# recorded here rather than left implicit.
#
# There is also no framework build on this triplet. qtbase's "framework" feature is
# declared `supports: "osx & !static"`, so it is unavailable twice over: iOS is not
# osx, and this triplet is static. Frameworks are enabled on arm64-osx, where
# qtbase is dynamic. Wrapping these static archives into a .framework bundle for
# iOS is an SDK packaging step, not something vcpkg does.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)

# Parity with ci/build_opencv.sh, and the debug-info fix - see arm64-linux.cmake
# for the measurements behind the second one, and for why WITH_PTHREADS_PF=OFF
# is deliberately not carried over.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME iOS)

# Autotools ports (libb2, which qtbase requires on every non-Windows platform) must
# be told they are cross-compiling, or configure runs the test binaries it just
# built - iOS binaries, on a macOS host - and dies with "cannot run C compiled
# programs". Autoconf decides that solely by comparing --host with --build.
#
# vcpkg cannot get this right by itself when the runner is an Apple-silicon Mac.
# z_vcpkg_make_determine_target_triplet in the vcpkg-make port does:
#
#     elseif(VCPKG_TARGET_IS_IOS OR VCPKG_TARGET_IS_OSX)
#         set(output "${TARGET_ARCH}-apple-darwin")
#
# which yields aarch64-apple-darwin, while --build is read from the host's
# build_opt_triplet.txt and is also aarch64-apple-darwin. Identical, so no cross
# mode. vcpkg knows the rule elsewhere - the UWP branch just above says "Needs to be
# different from --build to enable cross builds" - it just does not apply it to iOS.
# The bug is invisible on an Intel Mac, where --build is x86_64-apple-darwin.
#
# aarch64-apple-ios is correct rather than merely different: it names the same
# architecture and the actual target OS, and autoconf's config.sub canonicalises it
# (arm64-apple-ios normalises to it too). An earlier attempt used arm-apple-darwin,
# which worked only by being a different string - and said 32-bit ARM, which is a
# lie about a build the compiler is emitting arm64 for.
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-apple-ios")

set(VCPKG_BUILD_TYPE release)
