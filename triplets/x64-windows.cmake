# Owned here rather than in the consuming project, so that port-specific
# workarounds can be retired as the ports absorb them.
#
# Retired: -DWITH_MSMF=OFF. msmf is a feature of this registry's opencv4, and any
# "default-features": false selection already leaves it off.
#
# No -fvisibility=hidden counterpart: it is a GCC/Clang flag, ci/build_opencv.sh's
# own notes say to drop it on Windows, and MSVC exports nothing from a static
# library unless told to.
#
# Note the name is upstream's `x64-windows` but the settings are upstream's
# `x64-windows-static-md`: dynamic CRT, static libraries. Upstream's own
# `x64-windows` links libraries dynamically. Keeping the plain name is deliberate -
# the same six triplet names are used on every platform here, and the linkage
# policy below is uniform across them - but anyone comparing against upstream
# should expect static-md behaviour, plus the LGPL exceptions.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)

# Static by default - opencv4, libuv, amqpcpp, prometheus-cpp and everything else
# link straight into the SDK.
set(VCPKG_LIBRARY_LINKAGE static)

# Every upstream Windows triplet sets this, so match them. It only affects ports
# that call vcpkg_find_fortran: ON means vcpkg acquires MinGW gfortran from MSYS
# rather than expecting the toolchain to supply a Fortran compiler. Nothing in
# tests/vcpkg.json needs Fortran today, so this is inert here - it matters the day
# something like lapack-reference enters the graph.
set(VCPKG_PROVIDED_FORTRAN ON)

# Dynamic for the LGPL libraries, on every platform. The LGPL's relinking
# requirement is satisfied by shipping them as replaceable DLLs; static linking
# would put that obligation on whoever redistributes the SDK. Same list in every
# triplet here, deliberately - numactl is Linux-only and simply never matches.
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
endif()

if(PORT MATCHES "opencv")
    # The port hard-codes -DBUILD_WITH_DEBUG_INFO=ON, which puts DWARF into the
    # release static libs: 79 MB of the 116 MB of libopencv_*.a on arm64-linux, 68%
    # of their size, with libopencv_dnn4.a alone going 59.7 -> 17.4 MB. Nothing else
    # in the tree carries debug info, so this is the one real size lever we have.
    # ADDITIONAL_BUILD_FLAGS is expanded after the port's own OPTIONS, so the later
    # -D wins.
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DBUILD_WITH_DEBUG_INFO=OFF")
    # Neither is a port feature, so this is the only lever. WITH_AVFOUNDATION is
    # not exposed at all; WITH_FLATBUFFERS is tied to the dnn feature, so it is on
    # wherever dnn is - it only adds TFLite model import, which the SDK does not
    # use. WITH_DSHOW, WITH_MSMF and WITH_CAROTENE need nothing here: all three
    # are features, so "default-features": false already makes vcpkg pass them
    # as OFF explicitly.
    list(APPEND ADDITIONAL_BUILD_FLAGS "-DWITH_AVFOUNDATION=OFF" "-DWITH_FLATBUFFERS=OFF")
endif()

set(VCPKG_BUILD_TYPE release)
