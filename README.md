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

Copy the `zippy` directory into your project root (or add it as a
`git submodule`).

Create a `Makefile`:

```makefile
APP_NAME   := myapp
SHELL_TYPE := wish
DEPS       := tdom mtls tcllib img

include zippy/zippy.mk
```

Create a directory matching your `APP_NAME` and place your code inside it:

```
myproject/
├── Makefile
├── zippy/
└── myapp/
    └── main.tcl
```

Then run:

```
make
```

Binaries will be placed under `./bin`.

## Configuration

### `SHELL_TYPE`

- `wish` (default) — base interpreter includes Tk (GUI support)
- `tclsh` — base interpreter without Tk

### `DEPS`

Optional, any combination of:

- `tdom` — XML/HTML parsing
- `tcllib` — standard Tcl library collection
- `img` — additional image format support (requires `wish`)
- `mtls` — TLS via mbedTLS

### `APP_NAME`

Set to bundle an app directory into the binary. This must be a directory at
the project root whose name matches the value of `APP_NAME`. All files in
that directory are bundled into the zipfs image, and `main.tcl` inside it
is executed on startup. Omit `APP_NAME` for a standalone interpreter.

At runtime, app files are mounted at `//zipfs:/app/`. 

## Targets

| Target          | Output      | Description                          |
|-----------------|-------------|--------------------------------------|
| `make`          | `bin/myapp` | Build the app (if `APP_NAME` is set) |
| `make wish`     | `bin/wish`  | Standalone wish with selected deps   |
| `make tclsh`    | `bin/tclsh` | Standalone tclsh with selected deps  |
| `make download` |             | Download all source tarballs         |
| `make clean`    |             | Remove `_build/` and `bin/`          |
| `make distclean`|             | Same as clean                        |

## Standalone interpreter without a Makefile

You can build a standalone `tclsh` or `wish` with bundled extensions directly,
without creating a project `Makefile`:

```
make -f zippy/zippy.mk SHELL_TYPE=tclsh DEPS="tdom mtls" tclsh
```

This produces `bin/tclsh` with tdom and mtls baked in.

## Build parallelism

Each build step uses all available cores by default. Override with:

```
make NPROC=8
```
