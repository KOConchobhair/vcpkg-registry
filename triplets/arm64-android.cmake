# Android arm64. Release-only, like every triplet here - VCPKG_BUILD_TYPE release is
# the house rule, so it is not spelled out in the name. Settings are upstream's
# community arm64-android-release triplet plus this registry's linkage policy and
# opencv flags.
#
# Requires ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) in the environment. The GitHub
# runner images set it; locally, point it at your own NDK.
set(VCPKG_TARGET_ARCHITECTURE arm64)
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
# for the measurements behind the second one.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_PTHREADS_PF=OFF")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME Android)
set(VCPKG_CMAKE_SYSTEM_VERSION 28)
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-linux-android")
set(VCPKG_CMAKE_CONFIGURE_OPTIONS -DANDROID_ABI=arm64-v8a)
set(VCPKG_BUILD_TYPE release)
