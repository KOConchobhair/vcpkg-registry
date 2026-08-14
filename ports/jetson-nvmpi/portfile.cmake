# libnvmpi -- the library behind FFmpeg's *_nvmpi codecs on Jetson.
#
# JetPack 6 (L4T 36.x, Orin) only. Orin's video engines are reachable only through the V4L2
# multimedia API, because NVIDIA does not publish libnvidia-encode/libnvidia-decode for JetPack 6.
# JetPack 7 (Thor) does publish them, so nvenc/nvdec/cuvid work there directly and this port is
# not needed -- one FFmpeg built with both feature sets covers Orin and Thor.

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO gjrtimmer/jetson-ffmpeg
    REF 8d70c17efeee57f4d956df500fec78a73f8c27d4
    SHA512 177c6b148fc07ded7e920d84042323e5ced3fd1fdabec562b0daa10b143e9bb4f919982b4c0bdd3b5a6c3e87dc16380bf33989cde47a6cc83695d647b1a5cab2
    HEAD_REF main
)

# jetson-ffmpeg compiles the Multimedia API's helper classes, so it needs that API's headers and
# samples/common/classes. The jetson-multimedia-api port lays them out exactly as NVIDIA does.
set(MMAPI_DIR "${CURRENT_INSTALLED_DIR}/share/jetson-multimedia-api")
if(NOT EXISTS "${MMAPI_DIR}/include/nvbufsurface.h")
    message(FATAL_ERROR "jetson-multimedia-api did not provide ${MMAPI_DIR}/include/nvbufsurface.h")
endif()

# WITH_STUBS links the stub libraries upstream ships, so this builds with no Jetson attached and
# no Tegra libraries present. On the device the real libraries under /usr/lib/aarch64-linux-gnu
# satisfy the same sonames at run time.
#
# WITH_NVUTILS is not an option -- upstream defines it when nvbufsurface.h is present in the API
# headers, which is the case for L4T 36.4.
vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DWITH_STUBS=ON
        -DJETSON_MULTIMEDIA_API_DIR=${MMAPI_DIR}
)

vcpkg_cmake_install()
vcpkg_fixup_pkgconfig()

# Upstream installs nvmpi.pc under both share/ and lib/; keep the lib/ copy only.
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/share/pkgconfig"
                    "${CURRENT_PACKAGES_DIR}/debug/share"
                    "${CURRENT_PACKAGES_DIR}/debug/include")

# The stubs exist purely so something can link off-device. They must never land in lib/, or they
# would be packaged and shadow the real Tegra libraries at run time. They are kept aside so a
# consumer's link step can point -rpath-link at them.
file(INSTALL "${SOURCE_PATH}/stubs/" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}/stubs"
     FILES_MATCHING PATTERN "*.so*")

# FFmpeg's nvmpi patches are carried here so the ffmpeg port can apply the one matching its
# version without a second checkout of jetson-ffmpeg.
file(INSTALL "${SOURCE_PATH}/ffmpeg/patches/" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}/patches"
     FILES_MATCHING PATTERN "*.patch")

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
