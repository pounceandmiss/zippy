# Zippy

Super simple build system for self-contained Tcl/Tk executables using zipfs.

Downloads and compiles Tcl, Tk, and selected extensions from source, then packages everything into a single binary.

## Prerequisites

- C compiler (gcc/clang)
- make
- curl
- zip (required for Tk build)
- git (for tclmtls)

## Quick start

Add `zippy` to your project as a directory or `git submodule`.

Create a `Makefile`:

```makefile
BIN_NAME   := myapp
SHELL_TYPE := wish
DEPS       := tdom mtls tcllib img

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
bundle. Built-in excludes are always applied, this adds to them.

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
- `img` — additional image format support (requires `wish`)
- `mtls` — TLS via mbedTLS

## Targets

| Target          | Output    | Description                            |
|-----------------|-----------|----------------------------------------|
| `make`          | `./myapp` | Build the app (if `BIN_NAME` is set)   |
| `make wish`     | `./wish`  | Standalone wish with selected deps     |
| `make tclsh`    | `./tclsh` | Standalone tclsh with selected deps    |
| `make download` |           | Download all source tarballs           |
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
