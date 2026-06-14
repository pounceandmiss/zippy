# zippy toolchain image: Android NDK cross-build (arm64-v8a, API 30). Pins NDK r29
# (the clang Termux shipped, which produced the known-good reference binary) so the
# bionic ELF is reproducible.
#
# No on-host runtime: an x86_64 host cannot run the aarch64 cross binary, so the
# Tcl/Tk install and TEA zipfs steps run a native tclsh (windows.mk-style TCL_EXE /
# TCLSH_PROG), shipped below.
FROM debian:bookworm

# build-essential/zlib1g-dev: for the native tcl below. cmake: mbedtls + the rtc/
# rtcma WebRTC stack cross-build via the NDK's android.toolchain.cmake. unzip: NDK
# archive. zip: Tcl/Tk + TEA zipfs assembly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git curl file zip unzip ca-certificates pkg-config ccache \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# NDK r29. ~783 MB download, ~5 GB unpacked. The clang wrappers
# (aarch64-linux-android30-clang) and android.toolchain.cmake live under it.
ENV ANDROID_NDK=/opt/android-ndk-r29
RUN curl -fsSL https://dl.google.com/android/repository/android-ndk-r29-linux.zip -o /tmp/ndk.zip \
    && echo "4abbbcdc842f3d4879206e9695d52709603e52dd68d3c1fff04b3b5e7a308ecf  /tmp/ndk.zip" | sha256sum -c \
    && unzip -q /tmp/ndk.zip -d /opt \
    && rm -f /tmp/ndk.zip

# Native tcl9.0 for HOST_TCLSH (zipfs bundling) and the cross install steps that
# run a native interp (install-tzdata, thread's zipfs mkzip). Same 9.0.x zippy
# pins, verified by sha; any 9.0.x matches the bundled 9.0 library line.
RUN curl -fsSL http://prdownloads.sourceforge.net/tcl/tcl9.0.3-src.tar.gz -o /tmp/tcl.tar.gz \
    && echo "2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6  /tmp/tcl.tar.gz" | sha256sum -c \
    && tar xzf /tmp/tcl.tar.gz -C /tmp \
    && cd /tmp/tcl9.0.3/unix \
    && ./configure --prefix=/usr/local --disable-shared \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/tcl.tar.gz /tmp/tcl9.0.3

# NDK clang wrappers on PATH (aarch64-linux-android30-clang/-clang++); ccache shims
# shadow the native gcc/g++/cc for the native + host-tool builds.
ENV PATH=/usr/lib/ccache:$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
