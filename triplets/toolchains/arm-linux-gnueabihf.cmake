# Cross toolchain for 32-bit ARM Linux, hard-float (armhf).
#
# Chainloaded by triplets/arm-linux.cmake. Unlike Android and iOS, there is no
# vendor SDK to point at: the compiler is Ubuntu's gcc-arm-linux-gnueabihf, which
# CI installs for that leg only. Nothing else in this registry needs it, and it is
# deliberately not in tests/apt-packages.txt - that file is the container's
# contract, and no container build targets armhf.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(TOOLCHAIN_PREFIX arm-linux-gnueabihf)
set(CMAKE_C_COMPILER   ${TOOLCHAIN_PREFIX}-gcc)
set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}-g++)

# Look for headers and libraries in the target sysroot, but run programs from the
# host - otherwise CMake tries to execute armhf binaries during find_package.
set(CMAKE_FIND_ROOT_PATH /usr/${TOOLCHAIN_PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
