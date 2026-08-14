# Owned here rather than in the consuming project, so that port-specific
# workarounds can be retired as the ports absorb them.
#
# Retired: -DWITH_MSMF=OFF. msmf is a feature of this registry's opencv4, and any
# "default-features": false selection already leaves it off.
#
# No -fvisibility=hidden counterpart: it is a GCC/Clang flag, ci/build_opencv.sh's
# own notes say to drop it on Windows, and MSVC exports nothing from a static
# library unless told to.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)

# Static by default - opencv4, libuv, amqpcpp, prometheus-cpp and everything else
# link straight into the SDK.
set(VCPKG_LIBRARY_LINKAGE static)

# Dynamic for the LGPL libraries, on every platform. The LGPL's relinking
# requirement is satisfied by shipping them as replaceable DLLs; static linking
# would put that obligation on whoever redistributes the SDK. Same list in every
# triplet here, deliberately - numactl is Linux-only and simply never matches.
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()

if(PORT MATCHES "opencv")
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_PTHREADS_PF=OFF")
endif()

set(VCPKG_BUILD_TYPE release)
