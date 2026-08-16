# Cross toolchain for 32-bit ARM Linux, hard-float (armhf).
#
# Chainloaded by triplets/arm-linux.cmake. Unlike Android and iOS, there is no
# vendor SDK to point at: the compiler is Ubuntu's gcc-arm-linux-gnueabihf, which
# CI installs for that leg only. Nothing else in this registry needs it, and it is
# deliberately not in tests/apt-packages.txt - that file is the container's
# contract, and no container build targets armhf.
#
# Deliberately minimal. The usual standalone cross-compile recipe also sets
#
#     set(CMAKE_FIND_ROOT_PATH /usr/arm-linux-gnueabihf)
#     set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
#     set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
#
# and that is what the first attempt at this file did. It breaks under vcpkg:
# amqpcpp's find_package(OpenSSL) came back OPENSSL_CRYPTO_LIBRARY-NOTFOUND
# against an openssl that had just built and installed successfully into
# installed/arm-linux. Restricting the search roots to the compiler's sysroot is
# the right instinct for a hand-rolled cross build, where it stops you linking
# host libraries by accident - but under vcpkg every dependency comes from the
# installed tree, and vcpkg is already managing CMAKE_PREFIX_PATH,
# CMAKE_LIBRARY_PATH and CMAKE_FIND_ROOT_PATH for exactly that purpose.
#
# So this file does only the part vcpkg cannot infer: which compiler to use.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(CMAKE_C_COMPILER   arm-linux-gnueabihf-gcc)
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)
