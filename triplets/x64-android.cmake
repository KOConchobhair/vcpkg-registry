# Android x86_64. Release-only, like every triplet here - VCPKG_BUILD_TYPE release is
# the house rule, so it is not spelled out in the name. Settings are upstream's
# community arm64-android-release triplet, re-targeted plus this registry's linkage policy and
# opencv flags.
#
# Upstream has no x64-android triplet - only arm-android, armv6-android and
# x86-android - so this one is written to the same shape as
# arm64-android-release. It exists for the Android emulator, which runs the host
# architecture.
#
# Requires ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) in the environment. The GitHub
# runner images set it; locally, point it at your own NDK.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)

# Static by default - opencv4, libuv, amqpcpp, prometheus-cpp and everything else
# link straight into the SDK.
set(VCPKG_LIBRARY_LINKAGE static)

# Dynamic for the LGPL libraries, as on every other platform. Android is the one
# non-desktop target where this stays honest: an APK ships .so files in
# lib/<abi>/, so the LGPL relinking requirement is satisfied the same way it is on
# Linux. numactl is Linux-only and never matches here.
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()

# Parity with ci/build_opencv.sh, and the debug-info fix - see arm64-linux.cmake
# for the measurements behind the second one, and for why WITH_PTHREADS_PF=OFF
# is deliberately not carried over.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
    # Neither is a port feature, so this is the only lever. WITH_AVFOUNDATION is
    # not exposed at all; WITH_FLATBUFFERS is tied to the dnn feature, so it is on
    # wherever dnn is - it only adds TFLite model import, which the SDK does not
    # use. WITH_DSHOW, WITH_MSMF and WITH_CAROTENE need nothing here: all three
    # are features, so "default-features": false already makes vcpkg pass them
    # as OFF explicitly.
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_AVFOUNDATION=OFF" "-DWITH_FLATBUFFERS=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 28)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=x86_64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=x86_64)
set(VCPKG_BUILD_TYPE release)
