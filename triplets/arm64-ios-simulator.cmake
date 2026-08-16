# iOS arm64, simulator. Upstream's community arm64-ios-simulator triplet plus this
# registry's opencv flags. It differs from arm64-ios by one line -
# VCPKG_OSX_SYSROOT - which selects the simulator SDK instead of the device one.
#
# Static, like the device triplet, but for a different reason. On arm64-ios that
# is an LGPL exposure this project accepts because iOS cannot practically load
# third-party shared libraries. Nothing is shipped to a user from a simulator
# build, so no licence obligation attaches here at all; it is static so that
# simulator artifacts stay ABI-comparable to the device ones and the two triplets
# do not quietly diverge. Do not copy the arm64-ios licence rationale into this
# file - it would be false.
#
# No framework build here either: qtbase's "framework" feature is
# "osx & !static", and this is neither.
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
    # Neither is a port feature, so this is the only lever. WITH_AVFOUNDATION is
    # not exposed at all; WITH_FLATBUFFERS is tied to the dnn feature, so it is on
    # wherever dnn is - it only adds TFLite model import, which the SDK does not
    # use. WITH_DSHOW, WITH_MSMF and WITH_CAROTENE need nothing here: all three
    # are features, so "default-features": false already makes vcpkg pass them
    # as OFF explicitly.
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_AVFOUNDATION=OFF" "-DWITH_FLATBUFFERS=OFF")
endif()

set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphonesimulator)

# Same cross-compile signal as arm64-ios: autoconf decides it is cross-compiling
# only when --host differs from --build, and without it libb2's configure runs
# the iOS binaries it just built on the macOS host. See arm64-ios.cmake for the
# full reasoning.
set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-apple-ios-simulator")

set(VCPKG_BUILD_TYPE release)
