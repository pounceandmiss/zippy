# zippy toolchain image: native Linux build against Debian bookworm (glibc 2.36),
# so the binaries run on distros older than the build host.
FROM debian:bookworm

# zip: Tk's configure uses the system zip(1) to assemble its zipfs archive;
# without it Tk falls back to a bundled "minizip" it can't build. The X11/font
# -dev libs are what zippy's Tk/tkdnd deps statically link against.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git curl file zip ca-certificates pkg-config \
        zlib1g-dev libx11-dev libxext-dev libxss-dev libxft-dev \
        libxcursor-dev libfontconfig-dev ccache \
    && rm -rf /var/lib/apt/lists/*

# ccache's compiler shims shadow gcc/g++/cc so even the cmake deps get cached.
# in_docker.sh points CCACHE_DIR into the persistent per-profile cache mount.
ENV PATH=/usr/lib/ccache:$PATH
