# CMake toolchain for cross-compiling to Windows x86-64 with MinGW-w64.
# Used by the cmake-based deps (mbedtls, rtc, rtcma) in the Windows cross-build.
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(TRIPLE x86_64-w64-mingw32)
set(CMAKE_C_COMPILER   ${TRIPLE}-gcc)
set(CMAKE_CXX_COMPILER ${TRIPLE}-g++)
set(CMAKE_RC_COMPILER  ${TRIPLE}-windres)
set(CMAKE_AR           ${TRIPLE}-ar)
set(CMAKE_RANLIB       ${TRIPLE}-ranlib)

set(CMAKE_FIND_ROOT_PATH /usr/${TRIPLE})
# Our cross-built deps install into the prefixes on CMAKE_PREFIX_PATH
# (e.g. _build-win/local), which sit OUTSIDE the MinGW sysroot. Add them to
# the find root so find_path/find_library reach them under ONLY mode; these
# are used by module-mode Find scripts like libdatachannel's bundled
# FindMbedTLS (consumed by libsrtp), which otherwise report version 0.0.0 and
# miss the libraries. Keeping ONLY (not BOTH) avoids matching host ELF libs.
list(APPEND CMAKE_FIND_ROOT_PATH ${CMAKE_PREFIX_PATH} ${CMAKE_STAGING_PREFIX})

# Find programs on the host, but libs/headers/packages only in the find root.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# BOTH: CONFIG-mode find_package also resolves deps whose *Config.cmake lands
# in a CMAKE_PREFIX_PATH dir not covered by the find-root rerooting above.
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
