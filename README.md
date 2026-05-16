# Zippy

Super simple build system for self-contained Tcl/Tk executables using zipfs.

Downloads and compiles Tcl, Tk, and selected extensions from source, then packages everything into a single binary.

## Prerequisites

- C compiler (gcc/clang)
- C++ compiler (g++, required for `rtc`/`rtcma`)
- make
- cmake (required for `rtc`/`rtcma`)
- curl
- zip (required for Tk build)
- git (for `mtls`, `rtc`, `rtcma`)

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

### `BIN_NAME`

Set to produce an app binary. Omit `BIN_NAME` for a standalone
interpreter.

At runtime, app files are mounted at `//zipfs:/app/`.

### `APP_DIR`

Source directory for app files. Defaults to `.` (project root). Set this to a
subdirectory if you prefer to keep app code separate:

```makefile
BIN_NAME := myapp
APP_DIR  := src
```

A `main.tcl` must exist in `APP_DIR` (the
project root by default). All files in `APP_DIR` are bundled into the zipfs
image, except for built-in excludes (the zippy directory, `_build/`,
`Makefile`, and the output binary itself).

### `APP_EXCLUDE`

Space-separated list of additional file/directory names to exclude from the
bundle. Built-in excludes are always applied; this adds to them.

```makefile
APP_EXCLUDE := tests docs .git
```

### `SHELL_TYPE`

- `wish` (default) — base interpreter includes Tk (GUI support)
- `tclsh` — base interpreter without Tk

### `DEPS`

Optional, any combination of:

- `tdom` — XML/HTML parsing
- `tcllib` — standard Tcl library collection
- `mtls` — TLS via mbedTLS
- `img` — Tk Img (PNG, JPEG, TIFF, BMP, GIF, ICO, TGA, and more). Requires `SHELL_TYPE=wish`. Bundles its own libpng/libjpeg/libtiff/zlib — no system deps.
- `rtc` — libdatachannel wrapper. libdatachannel and mbedtls are brought in statically; libstdc++ is statically linked, libgcc_s remains dynamic. When combined with `mtls`, tclmtls is configured with `--with-mbedtls=` pointing at the rtc vendor prefix so both share a single mbedtls (avoids duplicate-symbol link errors).
- `rtcma` — libdatachannel-miniaudio adapter. Requires `rtc` to be in `DEPS` too: rtcma consumes libdatachannel and mbedtls from rtc's vendor prefix instead of rebuilding them.

## Targets

| Target          | Output    | Description                            |
|-----------------|-----------|----------------------------------------|
| `make`          | `./myapp` | Build the app (if `BIN_NAME` is set)   |
| `make wish`     | `./wish`  | Standalone wish with selected deps     |
| `make tclsh`    | `./tclsh` | Standalone tclsh with selected deps    |
| `make download` |           | Download all source tarballs           |
| `make test`     |           | Run the integration smoke test         |
| `make clean`    |           | Remove `_build/` and built binaries    |
| `make distclean`|           | Same as clean                          |

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

See `tests/smoke.sh` for the assertions.
