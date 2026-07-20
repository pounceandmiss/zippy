# Zippy

Build system for self-contained Tcl/Tk executables using zipfs.

Downloads and compiles Tcl, Tk, and selected extensions from source, then packages everything into a single binary.

## Prerequisites

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
- `APP_DIR` — source directory for app files, default `.` (project root). Must contain `main.tcl`. Everything under it is bundled, minus the built-in excludes (the zippy directory, `_build/`, `Makefile`, the output binary).
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
  - `tkdnd` — native drag-and-drop for Tk (X11 XDND). Requires `SHELL_TYPE=wish`.
- `TCLLIB_INCLUDE` — whitelist of tcllib submodules, e.g. `math base64 json`. Unset ships all of tcllib. Transitive deps are not auto-resolved (list them yourself), and `package require tcllib` stops working in whitelist mode — require the specific submodules.
- `IMG_INCLUDE` — whitelist of tkimg format readers to compile in, e.g. `png jpeg bmp`. Unset ships every format. Changing it requires `make clean`.
- `STRIP` — `1` (default) strips debug symbols from the shipped binary and writes a `<binary>.debug` sidecar next to it; `0` leaves it unstripped.
- `WIN_ICON` — path to an `.ico` file for the exe's icon. Only applies to Windows targets.

## Targets

| Target          | Output    | Description                            |
|-----------------|-----------|----------------------------------------|
| `make`          | `./myapp` | Build the app (if `BIN_NAME` is set)   |
| `make wish`     | `./wish`  | Standalone wish with selected deps     |
| `make tclsh`    | `./tclsh` | Standalone tclsh with selected deps    |
| `make download` |           | Download all source tarballs           |
| `make test`     |           | Run the integration smoke test         |
| `make clean`    |           | Remove `_build/` and built binaries    |

## Standalone interpreter without a Makefile

You can build a standalone `tclsh` or `wish` with bundled extensions directly,
without creating a project `Makefile`:

```
make -f zippy/zippy.mk SHELL_TYPE=tclsh DEPS="tdom mtls" tclsh
```

This produces `./tclsh` with tdom and mtls baked in.

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