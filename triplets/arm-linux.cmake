# 32-bit ARM Linux, hard-float. For embedded boards - the i.MX6 is the target that
# prompted it. Upstream's community arm-linux triplet plus this registry's linkage
# policy, opencv flags, and the cross toolchain upstream leaves to the caller.
#
# This is the only triplet here that cannot build on its own hardware in CI: the
# runners are x64 and arm64, never armv7. The compiler comes from Ubuntu's
# gcc-arm-linux-gnueabihf, installed by the workflow for this leg alone.
set(VCPKG_TARGET_ARCHITECTURE arm)
set(VCPKG_CRT_LINKAGE dynamic)

# Static by default - opencv4, libuv, amqpcpp, prometheus-cpp and everything else
# link straight into the SDK.
set(VCPKG_LIBRARY_LINKAGE static)

# Dynamic for the LGPL libraries, as on every other Linux triplet.
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
    set(VCPKG_FIXUP_ELF_RPATH ON)
endif()

# The i.MX6 is a Cortex-A9: ARMv7-A with NEON. Ubuntu's arm-linux-gnueabihf
# defaults to vfpv3-d16 and no NEON, which would cost OpenCV every hand-vectorised
# path on a chip that has the unit - the same trap the Android armeabi-v7a triplet
# used to fall into. Set explicitly rather than inherited.
set(VCPKG_C_FLAGS "-march=armv7-a -mfpu=neon")
set(VCPKG_CXX_FLAGS "-march=armv7-a -mfpu=neon")

# Parity with ci/build_opencv.sh, and the debug-info fix - see arm64-linux.cmake
# for the measurements behind the second one, and for why WITH_PTHREADS_PF=OFF
# is deliberately not carried over.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_AVFOUNDATION=OFF" "-DWITH_FLATBUFFERS=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_CHAINLOAD_TOOLCHAIN_FILE "${CMAKE_CURRENT_LIST_DIR}/toolchains/arm-linux-gnueabihf.cmake")

# Autotools ports must be told they are cross-compiling, or libb2's configure runs
# the armhf binaries it just built on an x64 host. Autoconf decides that solely by
# comparing --host with --build - see arm64-ios.cmake for the long version.
set(VCPKG_MAKE_BUILD_TRIPLET "--host=arm-linux-gnueabihf")

set(VCPKG_BUILD_TYPE release)
