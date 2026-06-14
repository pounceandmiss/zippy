# CMake toolchain for cross-compiling to Android (arm64-v8a) with the NDK.
# Used by the cmake-based deps (mbedtls, rtc, rtcma) in the Android cross-build.
# Chains the NDK's own toolchain file, then adds zippy's cross-built prefix to
# the find root - the same pattern as mingw-toolchain.cmake.
#
# ABI/platform set here (env from android.mk), NOT via -D: bundled libdatachannel
# is a cmake ExternalProject that forwards CMAKE_TOOLCHAIN_FILE but not
# -DANDROID_ABI, so a -D default builds it armeabi-v7a (32-bit). In the toolchain
# file, every sub-build inherits arm64.
set(ANDROID_ABI "$ENV{ANDROID_ABI}")
set(ANDROID_PLATFORM "$ENV{ANDROID_PLATFORM}")
include("$ENV{ANDROID_NDK}/build/cmake/android.toolchain.cmake")

# Our cross-built deps install into the prefixes on CMAKE_PREFIX_PATH
# (e.g. _build-android/local), which sit OUTSIDE the NDK sysroot. Add them to
# the find root so find_path/find_library (rtc's tcl.h/tclstub, libsrtp's
# bundled FindMbedTLS) reach them under ONLY mode. Keeping ONLY (not BOTH)
# avoids matching the image's native x86 tcl in /usr/local.
list(APPEND CMAKE_FIND_ROOT_PATH ${CMAKE_PREFIX_PATH} ${CMAKE_STAGING_PREFIX})

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
# BOTH: CONFIG-mode find_package also resolves deps whose *Config.cmake lands in
# a CMAKE_PREFIX_PATH dir not covered by the find-root rerooting above.
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
