# zippy toolchain image: MinGW-w64 cross-build for Windows. Pins the cross gcc
# (Debian bookworm: gcc 12) so the PE is reproducible regardless of the host's
# mingw version.

FROM debian:bookworm

# zip: Tcl/Tk and the TEA packages assemble their zipfs archives with system
# zip(1). zlib1g-dev: the native tcl below links zlib. The cross toolchain pulls
# binutils-mingw-w64 (ar/ranlib/windres) as a dependency.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git curl file zip ca-certificates pkg-config ccache \
        zlib1g-dev \
        gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64 \
    && rm -rf /var/lib/apt/lists/*

# posix threads model: libdatachannel (rtc/rtcma) uses std::thread/std::mutex,
# which the win32 threads variant lacks. Debian defaults to posix already, but
# pin it so the image does not depend on that default.
RUN update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix \
    && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Native tcl9.0 for HOST_TCLSH (the zipfs bundling step) and for the cross
# install steps that run a native interp (install-tzdata, thread's zipfs mkzip).
# Debian ships only 8.6, so build the same 9.0.x zippy pins, verified by sha.
# Any 9.0.x matches the bundled 9.0 library line.
RUN curl -fsSL http://prdownloads.sourceforge.net/tcl/tcl9.0.3-src.tar.gz -o /tmp/tcl.tar.gz \
    && echo "2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6  /tmp/tcl.tar.gz" | sha256sum -c \
    && tar xzf /tmp/tcl.tar.gz -C /tmp \
    && cd /tmp/tcl9.0.3/unix \
    && ./configure --prefix=/usr/local --disable-shared \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/tcl.tar.gz /tmp/tcl9.0.3

# ccache's compiler shims shadow gcc/g++/cc so the native + cmake deps get
# cached. in_docker.sh points CCACHE_DIR into the persistent per-profile cache.
ENV PATH=/usr/lib/ccache:$PATH
