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
# for the measurements behind the second one.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_PTHREADS_PF=OFF")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME iOS)

# Autotools ports (libb2, which qtbase requires on every non-Windows platform) must
# be told they are cross-compiling, or configure tries to run the test binaries it
# just built and dies with "cannot run C compiled programs". --host differing from
# --build is what puts autoconf into cross mode. Upstream's arm64-ios triplet omits
# this; its community status means nothing exercises libb2 there.
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-apple-darwin")

set(VCPKG_BUILD_TYPE release)
