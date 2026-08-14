# NVIDIA Jetson Linux Multimedia API -- headers plus the Nv* helper class sources that consumers
# compile into their own targets. The API is distributed only as an L4T package, so this port
# unpacks that package rather than redistributing NVIDIA's sources.
#
# This is the JetPack 6 (L4T 36.4) API. Its terms are NVIDIA's, not open source; the license file
# from the package is installed alongside.
#
# Layout matches what NVIDIA installs at /usr/src/jetson_multimedia_api, so a consumer points its
# build at ${CURRENT_INSTALLED_DIR}/share/jetson-multimedia-api and finds include/ and
# samples/common/classes/ where it expects them.

set(VCPKG_POLICY_EMPTY_INCLUDE_FOLDER enabled)

vcpkg_download_distfile(MMAPI_DEB
    URLS "https://repo.download.nvidia.com/jetson/common/pool/main/n/nvidia-l4t-jetson-multimedia-api/nvidia-l4t-jetson-multimedia-api_${VERSION}-20240912212859_arm64.deb"
    FILENAME "nvidia-l4t-jetson-multimedia-api_${VERSION}-20240912212859_arm64.deb"
    SHA512 cd6cdd5b418b4c6f0fbb0660f71778ccc08fc4afcdae87dc963dfd7f2f2cd8ee92dbffa726bcbca4ffe60e05408318a3032f6aa09d5342ce520b47e5695d9f40
)

# A .deb is an ar archive wrapping data.tar.zst. Unpack rather than install it: the package's own
# dependencies target a running Jetson, and only the sources are wanted here.
set(EXTRACT_DIR "${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET}-extract")
file(REMOVE_RECURSE "${EXTRACT_DIR}")
file(MAKE_DIRECTORY "${EXTRACT_DIR}")

find_program(AR_EXE NAMES ar REQUIRED)
vcpkg_execute_required_process(
    COMMAND "${AR_EXE}" x "${MMAPI_DEB}"
    WORKING_DIRECTORY "${EXTRACT_DIR}"
    LOGNAME "ar-${TARGET_TRIPLET}"
)
file(GLOB DATA_TAR "${EXTRACT_DIR}/data.tar.*")
if(NOT DATA_TAR)
    message(FATAL_ERROR "No data.tar.* inside ${MMAPI_DEB}")
endif()
vcpkg_execute_required_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xf "${DATA_TAR}"
    WORKING_DIRECTORY "${EXTRACT_DIR}"
    LOGNAME "untar-${TARGET_TRIPLET}"
)

set(MMAPI_SRC "${EXTRACT_DIR}/usr/src/jetson_multimedia_api")
if(NOT EXISTS "${MMAPI_SRC}/include/nvbufsurface.h")
    message(FATAL_ERROR "Unexpected package layout: ${MMAPI_SRC}/include/nvbufsurface.h missing")
endif()

# nvbufsurface.h and NvBufSurface.h differ only in case. On a case-insensitive filesystem they
# collapse into one file and consumers fail to compile with "'NvBufSurf' has not been declared".
# This port is Linux-only, so catch it here rather than letting it surface much later.
if(NOT EXISTS "${MMAPI_SRC}/include/NvBufSurface.h")
    message(FATAL_ERROR "NvBufSurface.h missing -- unpacked on a case-insensitive filesystem?")
endif()

set(DEST "${CURRENT_PACKAGES_DIR}/share/${PORT}")
file(INSTALL "${MMAPI_SRC}/include/" DESTINATION "${DEST}/include")
file(INSTALL "${MMAPI_SRC}/samples/common/classes/" DESTINATION "${DEST}/samples/common/classes")

# The Khronos headers the package carries under include/ are only needed by the renderer samples,
# which nothing here compiles.
foreach(dir Argus EGL EGLStream GL GLES2 GLES3 KHR)
    file(REMOVE_RECURSE "${DEST}/include/${dir}")
endforeach()

# The package carries no single LICENSE file; the Tegra agreement governs, with per-component
# terms alongside it.
vcpkg_install_copyright(FILE_LIST
    "${MMAPI_SRC}/Tegra_Software_License_Agreement-Tegra-Linux.txt"
    "${MMAPI_SRC}/LICENSE.nvprop"
    "${MMAPI_SRC}/LICENSE.libnvjpeg"
)
