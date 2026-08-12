#!/usr/bin/env bash
# in_docker.sh - run a build command inside a pinned zippy toolchain container.
#
#   in_docker.sh <profile> <command...>
#
# <profile> names a toolchain image, docker/<profile>.Dockerfile, e.g.:
#   linux-glibc2.36   native Linux build against an old glibc (portable binaries)
#
# The current directory (the project to build) is bind-mounted at /src. The build
# tree is kept in a per-profile dir under the project (_build-docker/<profile>/)
# so it persists across runs and never shares objects with a host-native build in
# the project's own _build (different glibc/toolchain would poison it). Final
# outputs (the binary, dist/) are written back into the project as the host user.
#
# Examples:
#   zippy/in_docker.sh linux-glibc2.36 make -f zippy.mk SHELL_TYPE=tclsh tclsh
#   zippy/in_docker.sh linux-glibc2.36 bash    # interactive toolchain shell
#
# Env knobs:
#   IN_DOCKER_BUILD_SUBDIR  in-project path the cache backs (default: _build).
#                           Set to a project's BASEDIR-relative build dir when it
#                           does not build into ./_build. Set empty to mount
#                           nothing, for a project whose BASEDIR already gives
#                           the container its own tree (build/<platform>/).
#   IN_DOCKER_CCACHE_DIR    CCACHE_DIR, a path inside the container. Only needed
#                           when nothing is mounted; else it defaults into the
#                           first mounted subdir.
#   ZIPPY_DOCKER_CACHE      where the per-profile build trees live
#                           (default: <project>/_build-docker).
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: in_docker.sh <profile> <command...>" >&2
    exit 2
fi

profile=$1
shift

zippydir=$(cd "$(dirname "$0")" && pwd)
dockerfile=$zippydir/docker/$profile.Dockerfile
if [ ! -f "$dockerfile" ]; then
    echo "in_docker.sh: no such profile '$profile' ($dockerfile)" >&2
    echo "available:" >&2
    ls -1 "$zippydir/docker"/*.Dockerfile 2>/dev/null \
        | sed 's#.*/##; s#\.Dockerfile$##; s/^/  /' >&2
    exit 2
fi

project=$PWD
image=zippy-toolchain:$profile

# Build tree lives in its own per-profile dir (_build-docker/<profile>/), separate
# from the project's _build, so a container build (e.g. Debian glibc) never shares
# objects with a host-native build (e.g. Arch glibc). Keyed by profile, which is
# named for its toolchain/glibc baseline, so different baselines never collide.
# Under the project (gitignored), not a global dir.
#
# A profile may build into more than one subdir (e.g. a cross target whose outputs
# sit beside a native _build); list them space-separated in IN_DOCKER_BUILD_SUBDIR.
# Each is mounted from the cache; only the final binary and dist/ land in the
# bind-mounted project. _build is listed first so it backs CCACHE_DIR below.
#
# Unset means _build; set-but-empty means mount nothing, for a project that
# isolates by BASEDIR - hence ${VAR-default}, not ${VAR:-default}. Mounting a
# subdir the project never builds into leaves an empty cache, a root-owned
# mountpoint in the project, and an unisolated write-through build.
build_subdirs=${IN_DOCKER_BUILD_SUBDIR-_build}
cache=${ZIPPY_DOCKER_CACHE:-$project/_build-docker}/$profile

mount_args=()
for sub in $build_subdirs; do
    mkdir -p "$cache/$sub"
    mount_args+=(-v "$cache/$sub:/src/$sub")
done

# ccache lives with the tree it caches: the first mounted subdir by default, or
# IN_DOCKER_CCACHE_DIR when nothing is mounted. With neither it falls back to
# $HOME, which is ephemeral (--rm).
ccache_dir=${IN_DOCKER_CCACHE_DIR:-}
if [ -z "$ccache_dir" ] && [ -n "${build_subdirs%% *}" ]; then
    ccache_dir=/src/${build_subdirs%% *}/.ccache
fi
ccache_args=()
if [ -n "$ccache_dir" ]; then
    ccache_args=(-e "CCACHE_DIR=$ccache_dir")
fi

# Build (layer-cached; near-instant when the Dockerfile is unchanged). Send build
# chatter to stderr so the wrapped command keeps a clean stdout.
DOCKER_BUILDKIT=1 docker build -t "$image" -f "$dockerfile" "$zippydir/docker" >&2

# Interactive (-t -i) only when attached to a real terminal, so piped/CI use is
# unaffected but `in_docker.sh <profile> bash` gives a usable shell.
tty_flags=()
if [ -t 0 ] && [ -t 1 ]; then
    tty_flags=(-t -i)
fi

exec docker run --rm "${tty_flags[@]}" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    "${ccache_args[@]}" \
    -v "$project:/src" \
    "${mount_args[@]}" \
    -w /src \
    "$image" "$@"
