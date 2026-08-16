# Zippy

Build system for self-contained Tcl/Tk executables using zipfs.

Downloads and compiles Tcl, Tk, and selected extensions from source, then packages everything into a single binary.

## Prerequisites

Linux (native or cross), or macOS — see [macOS](#macos-native-build) for that
host's specifics.

- C compiler (gcc/clang)
- C++ compiler (g++, required for `rtc`/`rtcma`)
- make
- cmake (required for `mtls`, `rtc`, `rtcma`, `omemo` — they all build mbedtls)
- curl
- zip (required for Tk build)
- git (for `mtls`, `rtc`, `rtcma`, `omemo`, `tclwuffs`, `tkwuffs`, `tkdnd`)

## Quick start

Add `zippy` to your project as a directory or `git submodule`.

Create a `Makefile`:

```makefile
BIN_NAME   := myapp
SHELL_TYPE := wish
DEPS       := tdom mtls tcllib

include zippy/zippy.mk
```

Create a `main.tcl` at the project root:

```
myproject/
├── Makefile
├── main.tcl
├── other.tcl
├── zippy/        (submodule)
└── ...
```

Then run:

```
make
```

The output binary (`./myapp`) is placed at the project root.

## Configuration

- `BIN_NAME` — name of the app binary to produce. Omit for a standalone interpreter. App files are mounted at `//zipfs:/app/` at runtime.
- `SOURCES` — space-separated paths to bundle, default `./` (project root). Each path is copied into the zipfs under its basename; an entry whose basename is `.` or empty (e.g. `./`) globs its contents into the root instead. The built-in excludes (the zippy directory, `_build/`, `Makefile`, the patches directory, the output binary) apply to the top-level entries of each path.
- `ENTRY_SCRIPT` — path within the bundled tree of the script run at startup, default `main.tcl`. For a non-default value zippy synthesizes a `main.tcl` at the zipfs root that sources it.
- `APP_DIR` — deprecated alias for `SOURCES`.
- `APP_EXCLUDE` — extra file/directory names to leave out of the bundle, e.g. `tests docs .git`. Adds to the built-in excludes.
- `SHELL_TYPE` — `wish` (default, includes Tk) or `tclsh` (no Tk).
- `DEPS` — extensions to bundle, any combination of:
  - `tdom` — XML/HTML parsing
  - `tcllib` — standard Tcl library collection
  - `mtls` — TLS via mbedTLS
  - `img` — Tk Img (PNG, JPEG, TIFF, BMP, GIF, ICO, TGA, and more). Requires `SHELL_TYPE=wish`. Bundles its own libpng/libjpeg/libtiff/zlib — no system deps.
  - `rtc` — [libdatachannel-tcl](https://github.com/pounceandmiss/libdatachannel-tcl), a WebRTC binding. libdatachannel and mbedtls are brought in statically; libstdc++ is statically linked, libgcc_s remains dynamic.
  - `rtcma` — [rtc-ma](https://github.com/pounceandmiss/rtc-ma), a libdatachannel-miniaudio adapter. Requires `rtc` in `DEPS` too.
  - `omemo` — [picomemo-tcl](https://github.com/pounceandmiss/picomemo-tcl), OMEMO end-to-end encryption. Links mbedtls.
  - `tclwuffs` — [tclwuffs](https://github.com/pounceandmiss/tclwuffs), memory-safe image decode/encode/resize on wuffs+stb.
  - `tkwuffs` — Tk photo bridge for tclwuffs, from the same repo. Requires `SHELL_TYPE=wish` and `tclwuffs` in `DEPS`.
  - `tkdnd` — native drag-and-drop for Tk (X11 XDND). Requires `SHELL_TYPE=wish`. Not available on macOS.
- `TCLLIB_INCLUDE` — whitelist of tcllib submodules, e.g. `math base64 json`. Unset ships all of tcllib. Transitive deps are not auto-resolved (list them yourself), and `package require tcllib` stops working in whitelist mode — require the specific submodules.
- `IMG_INCLUDE` — whitelist of tkimg format readers to compile in, e.g. `png jpeg bmp`. Unset ships every format. Changing it requires `make clean`.
- `STRIP` — `1` (default) strips debug symbols from the shipped binary and writes a `<binary>.debug` sidecar next to it; `0` leaves it unstripped.
- `GC_SECTIONS` — `1` (default) compiles every dep with per-function/data sections and links with `--gc-sections` (`-dead_strip` on macOS) so unreferenced code is dropped; `0` disables. Changing it requires `make clean`.
- `PATCHES_DIR` — where source patches live, default `patches/` in the consuming project. See [Source patches](#source-patches).
- `WIN_ICON` — path to an `.ico` file for the exe's icon. Only applies to Windows targets.

## Targets

| Target           | Output         | Description                             |
|------------------|----------------|-----------------------------------------|
| `make`           | `./myapp`      | Build the app (if `BIN_NAME` is set)    |
| `make wish`      | `./wish`       | Standalone wish with selected deps      |
| `make tclsh`     | `./tclsh`      | Standalone tclsh with selected deps     |
| `make lib`       | `./libmyapp.a` | Static library — see [Static library](#static-library) |
| `make download`  |                | Fetch all pinned sources                |
| `make dep-bundle`|`zippy-deps-<id>.tar.zst`| Archive the fetched sources     |
| `make unpack-deps`|               | Unpack a bundle into `DEPSDIR`          |
| `make test`      |                | Run the integration smoke test          |
| `make clean`     |                | Remove the build tree and built binaries |
| `make distclean` |                | `clean` plus the downloaded sources     |

## Standalone interpreter without a Makefile

You can build a standalone `tclsh` or `wish` with bundled extensions directly,
without creating a project `Makefile`:

```
make -f zippy/zippy.mk SHELL_TYPE=tclsh DEPS="tdom mtls" tclsh
```

This produces `./tclsh` with tdom and mtls baked in.

## Offline builds

`make download` is the only step that touches the network. Once `DEPSDIR` is
populated, `ZIPPY_OFFLINE=1` builds without it, and any missing dep fails
immediately naming itself:

```
make -f zippy/zippy.mk download
make -f zippy/zippy.mk ZIPPY_OFFLINE=1 tclsh
```

`make dep-bundle` archives the fetched sources to move them between machines:

```
make -f zippy/zippy.mk dep-bundle
make -f zippy/zippy.mk unpack-deps DEPS_BUNDLE_FILE=zippy-deps-<id>.tar.zst
```

The bundle is named for a digest of every pin. Checkouts keep their `.git`;
`DEPS_BUNDLE_EXCLUDE_VCS=1` drops it.

`DEPSDIR` defaults to `$(BASEDIR)/_build/deps` and is overridable, so targets
with different `BASEDIR`s can share one cache:

```
$(MAKE) -f zippy/zippy.mk BASEDIR=$(CURDIR)/build/linux DEPSDIR=$(CURDIR)/build/deps app
```

Safe between native and Windows targets. Not safe for Android: `omemo` and
`tclwuffs` build in-tree and only the Windows build redirects them to an
isolated copy, so an Android build would leave its objects in a shared checkout.

## Reproducible builds

`SOURCE_DATE_EPOCH` normalizes the mtimes carried in the zipfs payload, remaps
build paths out of debug info and `__FILE__` (`-ffile-prefix-map`), and is
exported to dep build systems:

```
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct) make -f zippy/zippy.mk tclsh
```

Left unset, the build keeps real paths in the `.debug` sidecar for `addr2line`.

## Source patches

Patches in `$(PATCHES_DIR)/<tree>/*.patch` — `patches/` in the consuming
project by default — apply to that source tree with `patch -p1`, in lexical
order, right after extraction. `<tree>` is one of `tcl`, `tk`, `tcllib`,
`tdom`, `img`, `opus`, `mbedtls`. A changed patch forces a clean re-extract of
its tree.

Git deps (`mbedtls`) are fetched pristine into `$(DEPSDIR)/git/<name>-<pin>` and
copied to their build path before patching, so a changed patch re-applies
without refetching and a pre-staged checkout still gets patched.

## Static library

`make lib` emits a static archive instead of a runnable binary, for embedding
the interpreter in a foreign C/C++ host: the bundled script tree is stored as a
bare zip in `.rodata` and merged with every static Tcl/dep archive into
`lib$(LIB_NAME).a` at the project root.

- `LIB_SHIM_SRC` — path to the project's shim `.c` that drives the embedded
  interpreter (required).
- `LIB_NAME` — archive base name, default `$(BIN_NAME)` (or `app`).

The shim may `#include "static_pkgs.h"` (zippy is on its include path) and call
`Zippy_RegisterStaticPackages()` so the registered packages match what was
linked in; it mounts the embedded zip via `TclZipfs_MountBuffer` using the
`_binary_scripts_zip_{start,end}` symbols. `win-lib` is the Windows counterpart
and produces a MinGW-linkable PE archive the same way.

## Build parallelism

Each build step uses all available cores by default. Override with:

```
make NPROC=8
```

## Tests

To run a smoke test that builds wish with all dependencies and exercises each:

```
make -C zippy -f zippy.mk test
```

## macOS (native build)

`TARGET_OS` defaults to `macos` on a Darwin host, so the normal invocations work
unchanged:

```
make -f zippy.mk SHELL_TYPE=wish DEPS="tdom mtls" wish   # -> ./wish
```

Tk builds against Aqua. Output goes to `_build/`.

Extra prerequisites: the Xcode Command Line Tools (`xcode-select --install`)
for clang, the SDK and `dsymutil`. `cmake` is not among them; install it
separately for `mtls`/`rtc`/`rtcma`/`omemo`.

macOS has no static libSystem, so libSystem, libz and the system frameworks stay
dynamic; everything else is still bundled statically. `STRIP=1` writes
`<binary>.debug` as a `.dSYM` bundle — a directory, not a flat file.

All deps are supported except `tkdnd`, which only has its X11 XDND backend wired
up here and fails the build.

Cross-compiling to macOS from Linux is not supported. It needs an SDK extracted
from Xcode, whose licence restricts use to Apple hardware, and the result cannot
be run or smoke-tested.

## Windows (cross-build)

`TARGET_OS=windows` cross-compiles a static Windows `.exe` from Linux via
MinGW-w64. The whole Windows tree is isolated under `_build-win/`; a native
`_build/` is untouched.

Extra prerequisites: the MinGW-w64 cross toolchain (`x86_64-w64-mingw32-gcc`,
`...-g++`, binutils) and a host `tclsh9.0` (used to bundle the script library
into the exe; override with `HOST_TCLSH=...`).

```
make -f zippy.mk TARGET_OS=windows win-wish  DEPS="rtc rtcma"   # -> ./wish.exe
make -f zippy.mk TARGET_OS=windows win-tclsh DEPS="rtc rtcma"   # -> ./tclsh.exe
make -f zippy.mk TARGET_OS=windows win-test  DEPS="rtc rtcma"   # smoke test under wine
```

To build an app (a `BIN_NAME` project) for Windows, pass `TARGET_OS=windows`
and the `win-app` target the same way you invoke `app` natively; the output is
`$(BIN_NAME).exe`:

```
make -f zippy/zippy.mk TARGET_OS=windows BIN_NAME=myapp \
    SHELL_TYPE=wish DEPS="..." SOURCES="..." ENTRY_SCRIPT=main.tcl win-app
```

All deps are supported on Windows.

Set `WIN_ICON` to point to an `.ico` file to give the exe an icon.

## Android (cross-build)

`TARGET_OS=android` cross-compiles a bionic arm64 executable with the Android
NDK (arm64-v8a / API 30 by default; override with `ANDROID_ABI` /
`ANDROID_API`). The build tree is isolated under `_build-android/`. Only
`tclsh` is wired up — no Tk on Android.

Extra prerequisites: the NDK's API-versioned clang wrappers
(`aarch64-linux-android30-clang`) and llvm binutils on PATH, plus a host
`tclsh9.0` (override with `HOST_TCLSH=...`). The `ndk` docker profile ships all
of this.

```
make -f zippy.mk TARGET_OS=android DEPS="..." android-tclsh      # -> ./tclsh (arm64 ELF)
make -f zippy.mk TARGET_OS=android BIN_NAME=myapp ... android-app       # -> ./myapp
make -f zippy.mk TARGET_OS=android BIN_NAME=myapp ... android-jnilibs   # -> jniLibs/arm64-v8a/
```

`android-jnilibs` stages the app binary as `jniLibs/<abi>/lib<name>.so` (the
only shape the APK packager ships into `nativeLibraryDir`), plus
`libc++_shared.so` when C++ deps (`rtc`/`rtcma`) are linked — arm64-v8a has no
static libstdc++.

## Docker toolchains

`in_docker.sh <profile> <command...>` runs a build inside a pinned toolchain
container: the current directory is mounted at `/src` and the build tree is
cached per profile under `_build-docker/<profile>/`, so container builds never
share objects with a host-native `_build/`.

```
zippy/in_docker.sh linux-glibc2.36 make -f zippy.mk SHELL_TYPE=tclsh tclsh
zippy/in_docker.sh linux-glibc2.36 bash    # interactive toolchain shell
```

Profiles map to `docker/<profile>.Dockerfile`: `linux-glibc2.36` (native Linux
build against an old glibc, for portable binaries), `mingw` (Windows cross),
`ndk` (Android).

A tree belongs to one toolchain: objects a container built must not be reused by
a host-native build of the same target. Two ways to get that:

- **Cache mounts** (the default), for a project building into `./_build` — the
  container's tree goes to `_build-docker/<profile>/`, the host keeps `_build/`.
  Set `IN_DOCKER_BUILD_SUBDIR` if the tree isn't `_build`, space-separated (a
  cross target has two: `_build` for dep sources, `_build-win` for objects).
- **Separate `BASEDIR`s**, for a project already building per platform: give the
  container its own flavour dir (`BASEDIR=/src/build/windows-docker`), set
  `IN_DOCKER_BUILD_SUBDIR=` empty, name an `IN_DOCKER_CCACHE_DIR` in that tree.

Mounting a subdir the project never builds into gets neither: empty cache,
root-owned mountpoint in the project, unisolated build.