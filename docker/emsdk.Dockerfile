# zippy toolchain image: Emscripten cross-build for the browser. Pins the emsdk
# release so the wasm is reproducible regardless of the host's emscripten, which
# is the whole point - a distro package moves under you, and emcc's output
# changes with it.

FROM emscripten/emsdk:6.0.9

# The image carries cmake, zip, git, curl, make and a native gcc already.
# pkg-config and file are wanted by the dep configure scripts; zlib1g-dev by the
# native tcl below; ccache by every rebuild after the first.
RUN apt-get update && apt-get install -y --no-install-recommends \
        pkg-config file ccache zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Native tcl9.0 for HOST_TCLSH. The bundling step (zipfs mkzip) and the TEA
# packages' install steps run a Tcl 9 on the build host, and the wasm one is an
# ES module rather than something make can execute. Ubuntu ships only 8.6, so
# build the same 9.0.x zippy pins, verified by sha; any 9.0.x matches the
# bundled 9.0 library line.
#
# Without this zippy would build its own into the project's tree (emscripten.mk's
# NATIVE_TCLSH), which works but pays for it once per project rather than once
# per image, and leaves a native tree inside a directory named for the wasm one.
RUN curl -fsSL http://prdownloads.sourceforge.net/tcl/tcl9.0.3-src.tar.gz -o /tmp/tcl.tar.gz \
    && echo "2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6  /tmp/tcl.tar.gz" | sha256sum -c \
    && tar xzf /tmp/tcl.tar.gz -C /tmp \
    && cd /tmp/tcl9.0.3/unix \
    && ./configure --prefix=/usr/local --disable-shared \
    && make -j"$(nproc)" && make install \
    && rm -rf /tmp/tcl.tar.gz /tmp/tcl9.0.3

# /emsdk/upstream/emscripten is on PATH ahead of /usr/bin and contains a
# *directory* called cmake (the toolchain files). A shell skips it and finds
# /usr/bin/cmake, but make execs what it finds and reports the directory as
# "cmake: Permission denied", which is a long way from what happened. /emsdk is
# the first PATH entry, so a link there is found first. Not ENV PATH=: the
# entrypoint sources emsdk_env.sh, which puts those entries back in front.
RUN ln -s /usr/bin/cmake /emsdk/cmake

# ccache shims shadow the native gcc/g++/cc, which build the host tools; emcc is
# not among them and caches through EM_CACHE instead.
ENV PATH=/usr/lib/ccache:$PATH

# emsdk leaves its sysroot cache world-writable, so --user $(id -u) can populate
# it on the first link. Named here because nothing else says it, and a cache that
# silently turned read-only would look like a compiler bug.
ENV EM_CACHE=/emsdk/upstream/emscripten/cache
