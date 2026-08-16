# Owned here rather than in the consuming project, so that port-specific
# workarounds can be retired as the ports absorb them.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)

# Static by default - opencv4, libuv, amqpcpp, prometheus-cpp and everything else
# link straight into the SDK.
set(VCPKG_LIBRARY_LINKAGE static)

# Dynamic for the LGPL libraries, on every platform. The LGPL's relinking
# requirement is satisfied by shipping them as replaceable shared objects; static
# linking would put that obligation on whoever redistributes the SDK. Same list in
# every triplet here, deliberately.
if(PORT MATCHES "^(qtbase|ffmpeg|openssl|numactl)$")
    set(VCPKG_LIBRARY_LINKAGE dynamic)
    # ELF only: rewrites absolute RPATH/RUNPATH entries to be $ORIGIN-relative.
    # Carried over from the original triplet. Note it only rewrites what is there
    # - the artifacts here end up with no RUNPATH at all, so the consuming link
    # step still has to set one (this is the job ci/build_qt6.sh's
    # -R /LONG/ENOUGH/TO/REPLACE placeholder was doing by hand).
    set(VCPKG_FIXUP_ELF_RPATH ON)
endif()

# Parity with ci/build_opencv.sh, for the one item no port feature can express:
# visibility is a compiler flag. WITH_PTHREADS_PF=OFF is deliberately not
# carried over - see arm64-linux.cmake for why.
if(PORT MATCHES "opencv")
    set(VCPKG_C_FLAGS "${VCPKG_C_FLAGS} -fvisibility=hidden")
    set(VCPKG_CXX_FLAGS "${VCPKG_CXX_FLAGS} -fvisibility=hidden")
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

set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_BUILD_TYPE release)
