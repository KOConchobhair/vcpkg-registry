# ROC: upstream's port with cuBLAS and cuDNN off, so CUDA builds need no system
# cuDNN (rank-1/rankone#4804 dropped it). Only CUTLASS's tests and profiler use
# either library, and neither is built here. Upstream's ON also stamps
# CUTLASS_ENABLE_CUBLAS=1 / CUTLASS_ENABLE_CUDNN=1 on the exported target, and in
# v4.8.x only tools/profiler headers read those. The delta: no cudnn dependency in
# vcpkg.json, no find_package(CUDNN) block below, and the two options OFF.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO NVIDIA/cutlass
    REF "v${VERSION}"
    SHA512 cbdf86439281f5c037eebe95aa2a74fe02a384badeda772b95c44e6e64b42d1e009253836dd1139471d7c4a7a7264303ecf8a3a114aacc8ba47aa39c542d57ab
    HEAD_REF main
)

vcpkg_find_acquire_program(PYTHON3)
get_filename_component(PYTHON_PATH "${PYTHON3}" PATH)
vcpkg_add_to_path(PREPEND "${PYTHON_PATH}")

vcpkg_find_cuda(OUT_CUDA_TOOLKIT_ROOT cuda_toolkit_root)
list(APPEND FEATURE_OPTIONS
    "-DCMAKE_CUDA_COMPILER=${NVCC}"
    "-DCUDAToolkit_ROOT=${cuda_toolkit_root}"
)


vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DCMAKE_SUPPRESS_REGENERATION=ON # for some reason it keeps regenerating in Windows
        "-DCUTLASS_REVISION:STRING=v${VERSION}"
        -DCUTLASS_NATIVE_CUDA=OFF
        -DCUTLASS_ENABLE_HEADERS_ONLY=ON
        -DCUTLASS_ENABLE_TOOLS=ON
        -DCUTLASS_ENABLE_LIBRARY=OFF
        -DCUTLASS_ENABLE_PROFILER=OFF
        -DCUTLASS_ENABLE_PERFORMANCE=OFF
        -DCUTLASS_ENABLE_TESTS=OFF
        -DCUTLASS_ENABLE_GTEST_UNIT_TESTS=OFF
        -DCUTLASS_ENABLE_CUBLAS=OFF
        -DCUTLASS_ENABLE_CUDNN=OFF
        "-DPython3_EXECUTABLE:FILEPATH=${PYTHON3}"
        ${FEATURE_OPTIONS}
    MAYBE_UNUSED_VARIABLES
        CUTLASS_NATIVE_CUDA
)
vcpkg_cmake_install()
vcpkg_cmake_config_fixup(CONFIG_PATH "lib/cmake/NvidiaCutlass" PACKAGE_NAME "NvidiaCutlass")

vcpkg_replace_string(
    "${CURRENT_PACKAGES_DIR}/include/cutlass/version.h"
    "@CUTLASS_VERSION@"
    "${VERSION}"
)
vcpkg_replace_string(
    "${CURRENT_PACKAGES_DIR}/include/cutlass/version.h"
    "@CUTLASS_REVISION@"
    "v${VERSION}"
)
vcpkg_replace_string(
    "${CURRENT_PACKAGES_DIR}/share/NvidiaCutlass/NvidiaCutlassTargets.cmake"
    "INTERFACE_COMPILE_DEFINITIONS \""
    "INTERFACE_COMPILE_DEFINITIONS \"CUTLASS_VERSIONS_GENERATED;"
)

file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug"
    "${CURRENT_PACKAGES_DIR}/test"
    "${CURRENT_PACKAGES_DIR}/lib"
)
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE.txt")
