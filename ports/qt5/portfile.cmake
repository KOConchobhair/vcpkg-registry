include(${CMAKE_TRIPLET_FILE})
include(vcpkg_common_functions)
set(SOURCE_PATH ${CURRENT_BUILDTREES_DIR}/src/qt-5.7.0)
set(OUTPUT_PATH ${CURRENT_BUILDTREES_DIR}/${TARGET_TRIPLET})
set(ENV{QTDIR} ${OUTPUT_PATH}/qtbase)
set(ENV{PATH} "${OUTPUT_PATH}/qtbase/bin;$ENV{PATH}")

find_program(NMAKE nmake)
vcpkg_find_acquire_program(JOM)
get_filename_component(JOM_EXE_PATH ${JOM} DIRECTORY)
set(ENV{PATH} "${JOM_EXE_PATH};$ENV{PATH}")

vcpkg_download_distfile(ARCHIVE_FILE
    URLS "http://download.qt.io/official_releases/qt/5.7/5.7.0/single/qt-everywhere-opensource-src-5.7.0.7z"
    FILENAME "qt-5.7.0.7z"
    SHA512 96f0b6bd221be0ed819bc9b52eefcee1774945e25b89169fa927148c1c4a2d85faf63b1d09ef5067573bda9bbf1270fce5f181d086bfe585ddbad4cd77f7f418
)
vcpkg_extract_source_archive(${ARCHIVE_FILE})
if (EXISTS ${CURRENT_BUILDTREES_DIR}/src/qt-everywhere-opensource-src-5.7.0)
    file(RENAME ${CURRENT_BUILDTREES_DIR}/src/qt-everywhere-opensource-src-5.7.0 ${CURRENT_BUILDTREES_DIR}/src/qt-5.7.0)
endif()

file(MAKE_DIRECTORY ${OUTPUT_PATH})
if(DEFINED VCPKG_CRT_LINKAGE AND VCPKG_CRT_LINKAGE STREQUAL static)
    list(APPEND QT_RUNTIME_LINKAGE "-static")
    list(APPEND QT_RUNTIME_LINKAGE "-static-runtime")
    vcpkg_apply_patches(
        SOURCE_PATH ${SOURCE_PATH}
        PATCHES "${CMAKE_CURRENT_LIST_DIR}/set-static-qmakespec.patch"
    )
else()
    vcpkg_apply_patches(
        SOURCE_PATH ${SOURCE_PATH}
        PATCHES "${CMAKE_CURRENT_LIST_DIR}/set-shared-qmakespec.patch"
    )
endif()

message(STATUS "Configuring ${TARGET_TRIPLET}")
vcpkg_execute_required_process(
    COMMAND "${SOURCE_PATH}/configure.bat"
        -confirm-license -opensource -platform win32-msvc2015
        -debug-and-release -force-debug-info ${QT_RUNTIME_LINKAGE}
        -nomake examples -nomake tests -skip webengine
        -prefix "${CURRENT_PACKAGES_DIR}"
    WORKING_DIRECTORY ${OUTPUT_PATH}
    LOGNAME configure-${TARGET_TRIPLET}
)
message(STATUS "Configure ${TARGET_TRIPLET} done")

message(STATUS "Building ${TARGET_TRIPLET}")
vcpkg_execute_required_process_repeat(
    COUNT 5
    COMMAND ${JOM}
    WORKING_DIRECTORY ${OUTPUT_PATH}
    LOGNAME build-${TARGET_TRIPLET}
)
message(STATUS "Build ${TARGET_TRIPLET} done")

message(STATUS "Installing ${TARGET_TRIPLET}")
vcpkg_execute_required_process(
    COMMAND ${NMAKE} install
    WORKING_DIRECTORY ${OUTPUT_PATH}
    LOGNAME install-${TARGET_TRIPLET}
)
message(STATUS "Install ${TARGET_TRIPLET} done")

message(STATUS "Packaging ${TARGET_TRIPLET}")
file(MAKE_DIRECTORY ${CURRENT_PACKAGES_DIR}/debug)
file(MAKE_DIRECTORY ${CURRENT_PACKAGES_DIR}/debug/lib)
file(MAKE_DIRECTORY ${CURRENT_PACKAGES_DIR}/debug/bin)
file(MAKE_DIRECTORY ${CURRENT_PACKAGES_DIR}/share)
file(RENAME ${CURRENT_PACKAGES_DIR}/lib/cmake ${CURRENT_PACKAGES_DIR}/share/cmake)

if(DEFINED VCPKG_CRT_LINKAGE AND VCPKG_CRT_LINKAGE STREQUAL dynamic)
    file(INSTALL ${CURRENT_PACKAGES_DIR}/bin
        DESTINATION ${CURRENT_PACKAGES_DIR}/debug
        FILES_MATCHING PATTERN "*d.dll"
    )
    file(INSTALL ${CURRENT_PACKAGES_DIR}/bin
        DESTINATION ${CURRENT_PACKAGES_DIR}/debug
        FILES_MATCHING PATTERN "*d.pdb"
    )
    file(GLOB DEBUG_BIN_FILES "${CURRENT_PACKAGES_DIR}/bin/*d.dll")
    file(REMOVE ${DEBUG_BIN_FILES})
    file(GLOB DEBUG_BIN_FILES "${CURRENT_PACKAGES_DIR}/bin/*d.pdb")
    file(REMOVE ${DEBUG_BIN_FILES})
    file(RENAME ${CURRENT_PACKAGES_DIR}/debug/bin/Qt5Gamepad.dll ${CURRENT_PACKAGES_DIR}/bin/Qt5Gamepad.dll)
endif()

file(INSTALL ${CURRENT_PACKAGES_DIR}/lib
    DESTINATION ${CURRENT_PACKAGES_DIR}/debug
    FILES_MATCHING PATTERN "*d.lib"
)
file(INSTALL ${CURRENT_PACKAGES_DIR}/lib
    DESTINATION ${CURRENT_PACKAGES_DIR}/debug
    FILES_MATCHING PATTERN "*d.prl"
)
file(INSTALL ${CURRENT_PACKAGES_DIR}/lib
    DESTINATION ${CURRENT_PACKAGES_DIR}/debug
    FILES_MATCHING PATTERN "*d.pdb"
)
file(GLOB DEBUG_LIB_FILES "${CURRENT_PACKAGES_DIR}/lib/*d.lib")
file(REMOVE ${DEBUG_LIB_FILES})
file(GLOB DEBUG_LIB_FILES "${CURRENT_PACKAGES_DIR}/lib/*d.prl")
file(REMOVE ${DEBUG_LIB_FILES})
file(GLOB DEBUG_LIB_FILES "${CURRENT_PACKAGES_DIR}/lib/*d.pdb")
file(REMOVE ${DEBUG_LIB_FILES})
file(RENAME ${CURRENT_PACKAGES_DIR}/debug/lib/Qt5Gamepad.lib ${CURRENT_PACKAGES_DIR}/lib/Qt5Gamepad.lib)
file(RENAME ${CURRENT_PACKAGES_DIR}/debug/lib/Qt5Gamepad.prl ${CURRENT_PACKAGES_DIR}/lib/Qt5Gamepad.prl)
file(GLOB BINARY_TOOLS "${CURRENT_PACKAGES_DIR}/bin/*.exe")
file(MAKE_DIRECTORY ${CURRENT_PACKAGES_DIR}/tools)
foreach(BINARY ${BINARY_TOOLS})
    execute_process(COMMAND dumpbin /PDBPATH ${BINARY}
                    COMMAND findstr PDB
        OUTPUT_VARIABLE PDB_LINE
        ERROR_QUIET
        RESULT_VARIABLE error_code
    )
    if(NOT error_code AND PDB_LINE MATCHES "PDB file found at")
        string(REGEX MATCH '.*' PDB_PATH ${PDB_LINE}) # Extract the path which is in single quotes
        string(REPLACE ' "" PDB_PATH ${PDB_PATH}) # Remove single quotes
        file(INSTALL ${PDB_PATH} DESTINATION ${CURRENT_PACKAGES_DIR}/tools)
        file(REMOVE ${PDB_PATH})
    endif()
endforeach()
file(INSTALL ${BINARY_TOOLS} DESTINATION ${CURRENT_PACKAGES_DIR}/tools)
FILE(REMOVE ${BINARY_TOOLS})

set(SHARE_PATH ${CURRENT_PACKAGES_DIR}/share/qt5)
file(MAKE_DIRECTORY ${SHARE_PATH})
file(INSTALL ${SOURCE_PATH}/LICENSE.LGPLv3 DESTINATION ${SHARE_PATH} RENAME copyright)
file(RENAME ${CURRENT_PACKAGES_DIR}/doc ${SHARE_PATH}/doc)
file(RENAME ${CURRENT_PACKAGES_DIR}/mkspecs ${SHARE_PATH}/mkspecs)
file(RENAME ${CURRENT_PACKAGES_DIR}/phrasebooks ${SHARE_PATH}/phrasebooks)
file(RENAME ${CURRENT_PACKAGES_DIR}/plugins ${SHARE_PATH}/plugins)
file(RENAME ${CURRENT_PACKAGES_DIR}/qml ${SHARE_PATH}/qml)
file(RENAME ${CURRENT_PACKAGES_DIR}/translations ${SHARE_PATH}/translations)
file(RENAME ${CURRENT_PACKAGES_DIR}/qtvirtualkeyboard ${SHARE_PATH}/qtvirtualkeyboard)
vcpkg_copy_pdbs()
