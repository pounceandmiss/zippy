# zippy.mk — Build system for self-contained Tcl/Tk zipfs binaries
#
# User sets these before including:
#   SHELL_TYPE   := wish | tclsh   (default: wish)
#   DEPS         := tdom mtls tcllib img  (optional, any combination)
#   BIN_NAME     := myapp          (optional, omit for standalone interpreter)
#   SOURCES      := ./             (default; space-separated list of paths to
#                                   bundle into the zipfs. Each path is copied
#                                   under its basename. Special case: `./` (or
#                                   any path whose basename is `.` / empty)
#                                   globs its CONTENTS into the root rather
#                                   than nesting under that name — preserves
#                                   the single-project-dir drop-in default.)
#   ENTRY_SCRIPT := main.tcl       (path within the bundled tree of the script
#                                   to run at startup. When non-default, zippy
#                                   synthesizes a main.tcl at zipfs root that
#                                   sources it.)
#   APP_EXCLUDE  :=                (optional, extra excludes: space-separated
#                                   names. Applied to top-level entries of each
#                                   bundled SOURCES path.)
#   APP_DIR      :=                (DEPRECATED — alias for SOURCES.)
#   STRIP       := 1 | 0           (default: 1 — strip symbols, save .debug sidecar)
#   GC_SECTIONS := 1 | 0           (default: 1 — drop unreferenced code at link)
#   TCLLIB_INCLUDE :=              (optional whitelist of tcllib submodules to
#                                   bundle, e.g. "math base64 json"; unset =
#                                   ship all of tcllib. The user must list
#                                   intra-tcllib deps explicitly — nothing is
#                                   auto-resolved, and `package require tcllib`
#                                   stops working in whitelist mode.)
#   IMG_INCLUDE :=                 (optional whitelist of tkimg format readers
#                                   to compile in, e.g. "png jpeg bmp"; unset =
#                                   all formats. Required base libs (zlibtcl /
#                                   pngtcl / jpegtcl / tifftcl) are auto-
#                                   derived from the format list. The Img
#                                   build itself still builds every subdir —
#                                   the whitelist only affects what gets
#                                   linked into kitsh and bundled into the
#                                   generated pkgIndex.tcl, so changes
#                                   require `make clean` to take effect.)
#
# Note: `img` and `tkwuffs` require Tk and are only valid with SHELL_TYPE=wish
# (default). `tkwuffs` additionally requires `tclwuffs` (its no-Tk base tier).
#
# When STRIP=1 (default), the shipped binary has debug symbols removed and a
# matching <binary>.debug sidecar is written next to it. Symbolize a crash with
# `addr2line -e <binary>.debug 0x...` or `gdb <binary>.debug core`.
#
# When GC_SECTIONS=1 (default), every dep is compiled with -ffunction-sections
# -fdata-sections and the kitsh link uses -Wl,--gc-sections so unreferenced
# code/data gets dropped. Changing the flag requires `make clean` (the per-
# section granularity is baked into the static archives at compile time).

# ==== Paths ====
ZIPPYDIR     := $(abspath $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST)))))
BASEDIR      := $(CURDIR)

# ==== Target platform ====
# TARGET_OS selects the build target; default (unset/linux) is the native build.
# The Windows variables below are empty when TARGET_OS != windows, so the native
# build is unchanged. TARGET_OS=windows cross-compiles a static PE via MinGW-w64;
# the divergent Tcl/Tk + TEA package recipes live in windows.mk (included at the
# bottom). The Windows tree sits under _build-win, separate from a native _build.
TARGET_OS    ?= linux
ifeq ($(TARGET_OS),windows)
  WIN          := 1
  CROSS        := x86_64-w64-mingw32
  CROSS_BUILD  := x86_64-pc-linux-gnu
  EXE_EXT      := .exe
  BUILDDIR     := $(BASEDIR)/_build-win
  # find_package/ExternalProject in the cmake deps need the mingw toolchain.
  CMAKE_TOOLCHAIN := -DCMAKE_TOOLCHAIN_FILE=$(ZIPPYDIR)/mingw-toolchain.cmake
else
  WIN          :=
  EXE_EXT      :=
  BUILDDIR     := $(BASEDIR)/_build
  CMAKE_TOOLCHAIN :=
endif

PREFIX       := $(BUILDDIR)/local
# Sources are platform-neutral and expensive to fetch (libdatachannel pulls
# large submodules), so they live in the native _build/deps and are shared
# across targets. Build outputs isolate by BUILDDIR; in-tree configures isolate
# by subdir (Tcl/Tk build in unix/ vs win/; the native build never TEA-builds
# the bundled pkgs the Windows build does).
DEPSDIR      := $(BASEDIR)/_build/deps
BUILD_TCL    := $(ZIPPYDIR)/build.tcl

SHELL_TYPE   ?= wish
SOURCES      ?= ./
ENTRY_SCRIPT ?= main.tcl
STRIP        ?= 1
GC_SECTIONS  ?= 1

# Backward-compat alias: APP_DIR → SOURCES (single entry).
ifneq ($(origin APP_DIR),undefined)
  SOURCES := $(APP_DIR)
  $(warning APP_DIR is deprecated; use SOURCES instead.)
endif

# ==== Versions ====
TCL_VER    := 9.0.3
TK_VER     := 9.0.3
TCLLIB_VER := 2.0
TDOM_VER   := 0.9.6
MTLS_VER   := 1.2.0
TCL_BVER   := 9.0
TK_BVER    := 9.0

# tclmtls has no v1.2.0 tag; the version bump and Tcl 9 fix sit on top of v1.1.0.
MTLS_COMMIT := 5b41f04

THREAD_VER  := 3.0.4
SQLITE3_VER := 3.51.0
ITCL_VER    := 4.3.5
TDBC_VER    := 1.1.13

# Img (tkimg). Bundles its own libpng/libjpeg/libtiff/zlib — no system deps.
IMG_VER       := 2.1.1
IMG_ZLIB_VER  := 1.3.2
IMG_PNG_VER   := 1.6.55
IMG_JPEG_VER  := 10.0.0
IMG_TIFF_VER  := 4.7.1

# Mbedtls. Shared crypto dep consumed by rtc/mtls/omemo. Built with the
# user-config file below to enable MBEDTLS_SSL_DTLS_SRTP (libdatachannel
# needs it; everyone else has to compile against the same headers or struct
# layouts diverge).
MBEDTLS_VER       := 3.6.6
MBEDTLS_REPO      := https://github.com/Mbed-TLS/mbedtls.git
MBEDTLS_COMMIT    := 5b64a9fdb979c8971561ec78221b528e3cc4e00a
MBEDTLS_SRC       := $(DEPSDIR)/mbedtls
MBEDTLS_USER_CFG  := $(ZIPPYDIR)/mbedtls-user-config.h

# Rtc (libdatachannel-tcl). C++ Tcl 9 binding for libdatachannel. Built via
# cmake with RTC_BUNDLE_LIBDATACHANNEL=ON so libdatachannel/juice/srtp2/
# usrsctp fold in as static archives; mbedtls comes from zippy's shared
# install via find_package.
RTC_VER    := 0.1.0
RTC_REPO   := https://github.com/pounceandmiss/libdatachannel-tcl.git
RTC_COMMIT := 124d9c5442ca33d232a060ec9a61d5a4f238471e
RTC_SRC    := $(DEPSDIR)/libdatachannel-tcl

# Rtcma (rtc-ma). Audio-over-libdatachannel adapter (miniaudio + opus +
# jitter buffer + SDP) with its own Tcl 9 binding. Built via cmake with
# RTCMA_BUNDLE_OPUS=ON only; libdatachannel comes from rtc's vendor and
# mbedtls from zippy's shared install, which is why `rtc` must also be in
# DEPS (enforced below).
RTCMA_VER    := 0.1.0
RTCMA_REPO   := https://github.com/pounceandmiss/rtc-ma.git
RTCMA_COMMIT := 19ff9a8dd9689a9ad0c8487c8840419ddb47e529
RTCMA_SRC    := $(DEPSDIR)/rtc-ma

# Omemo (picomemo-tcl). Tcl 9 binding for picomemo.
OMEMO_VER    := 0.3.0
OMEMO_REPO   := https://github.com/pounceandmiss/picomemo-tcl.git
OMEMO_COMMIT := b354edb7c9033a94ec31d3da66bc8cb29e85d5ee
OMEMO_SRC    := $(DEPSDIR)/picomemo-tcl

# Tclwuffs. Memory-safe image decode/encode/resize on wuffs+stb. Two tiers:
# `tclwuffs` (no-Tk) and `tkwuffs` (Tk photo bridge); the shared wuffs/stb
# glue lives only in libtclwuffs.a.
TCLWUFFS_VER    := 0.1.0
TCLWUFFS_REPO   := https://github.com/pounceandmiss/tclwuffs.git
TCLWUFFS_COMMIT := 901eda7a67bef4c92a4f036fa347325b3ea93019
TCLWUFFS_SRC    := $(DEPSDIR)/tclwuffs

# Tkdnd. Native drag-and-drop for Tk (X11 XDND). TEA build that also ships Tcl
# support scripts (tkdnd.tcl + per-platform files) beside the static archive.
# Requires Tk (private headers + X11 selection), so wish-only. See the install
# recipe for the static-link wiring.
TKDND_VER    := 2.9.5
TKDND_REPO   := https://github.com/petasis/tkdnd.git
TKDND_COMMIT := 6efca37a22b93b2336dc973f2b4a9ba1e3feceaf
TKDND_SRC    := $(DEPSDIR)/tkdnd

# sqlite3 dir/lib suffix collapses the leading "3." of SQLITE3_VER into the "3"
# of the package name (dir is sqlite3.51.0 for version 3.51.0).
SQLITE3_DIR_SUFFIX := $(patsubst 3.%,%,$(SQLITE3_VER))

# ==== Tarballs ====
TCL_TAR    := tcl$(TCL_VER)-src.tar.gz
TK_TAR     := tk$(TK_VER)-src.tar.gz
TDOM_TAR   := tdom-latest-src.tar.gz
TCLLIB_TAR := tcllib-$(TCLLIB_VER).tar.gz
IMG_TAR    := Img-$(IMG_VER).tar.gz

# ==== URLs ====
TCL_URL    := http://prdownloads.sourceforge.net/tcl/$(TCL_TAR)
TK_URL     := http://prdownloads.sourceforge.net/tcl/$(TK_TAR)
TDOM_URL   := https://tdom.org/downloads/latest-src.tar.gz
TCLLIB_URL := https://core.tcl-lang.org/tcllib/uv/$(TCLLIB_TAR)
MTLS_REPO  := https://github.com/chpock/tclmtls.git
MTLS_SRC   := $(DEPSDIR)/tclmtls
IMG_URL    := https://sourceforge.net/projects/tkimg/files/tkimg/2.1/tkimg%202.1.1/$(IMG_TAR)/download

# ==== Checksums ====
TCL_SHA256    := 2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6
TK_SHA256     := bf344efadb618babb7933f69275620f72454d1c8220130da93e3f7feb0efbf9b
TDOM_SHA256   := 6d24734aef46d1dc16f3476685414794d6a4e65f48079e1029374477104e8319
TCLLIB_SHA256 := 590263de0832ac801255501d003441a85fb180b8ba96265d50c4a9f92fde2534
IMG_SHA256    := 0e41efa886c470ca0c38663e66640eb6d89e9e5f746724535ac224e2509ae34f

# ==== Source dirs ====
TCL_SRC    := $(DEPSDIR)/tcl$(TCL_VER)
TK_SRC     := $(DEPSDIR)/tk$(TK_VER)
TCLLIB_SRC := $(DEPSDIR)/tcllib-$(TCLLIB_VER)
IMG_SRC    := $(DEPSDIR)/Img-$(IMG_VER)

# omemo/tclwuffs build objects into their own source tree (no out-of-tree
# support). Native builds there directly; the Windows cross-build works from an
# isolated copy under $(BUILDDIR) so that sharing one DEPSDIR between a native
# and a Windows build (same checkout) doesn't leave the cross-build linking the
# native build's ELF objects (or vice versa). Native: BUILD == SRC, so the
# KITSH_DEP_LIBS paths below are byte-identical to before.
OMEMO_BUILD    := $(OMEMO_SRC)
TCLWUFFS_BUILD := $(TCLWUFFS_SRC)
ifdef WIN
  OMEMO_BUILD    := $(BUILDDIR)/omemo
  TCLWUFFS_BUILD := $(BUILDDIR)/tclwuffs
endif

TCLSH := $(PREFIX)/bin/tclsh$(TCL_BVER)
WISH  := $(PREFIX)/bin/wish$(TK_BVER)
ifdef WIN
  # Cross-build: the host never runs these, and the win/ build installs
  # tclsh90.exe/wish90.exe (not tclsh9.0), so the binary paths above would never
  # match. Use stamp files as the Tcl/Tk completion markers instead; they only
  # gate ordering (headers/stubs/archives present before deps link).
  TCLSH := $(PREFIX)/.tcl_win_installed
  WISH  := $(PREFIX)/.tk_win_installed
endif

NPROC := $(shell nproc 2>/dev/null || echo 4)

# Size optimization: emit per-function/data sections in every dep so the kitsh
# link can drop unreferenced ones with --gc-sections. Both halves are needed —
# the flag on the link alone does nothing if the static archives were compiled
# without per-section granularity. When GC_SECTIONS=0 these vars are empty and
# the CFLAGS=/CMAKE_C_FLAGS= insertions in the recipes become no-ops.
ifeq ($(GC_SECTIONS),1)
  SIZE_CFLAGS  := -ffunction-sections -fdata-sections
  SIZE_LDFLAGS := -Wl,--gc-sections
else
  SIZE_CFLAGS  :=
  SIZE_LDFLAGS :=
endif

# Per-dep cmake C/C++ flag strings. Identical to SIZE_CFLAGS natively (so the
# native cmake command is unchanged); the Windows static link needs extra
# defines: STATIC_BUILD drops dllimport decoration, RTC_STATIC builds
# libdatachannel static, OPUS_BUILD drops opus's __imp_ prefixes.
RTC_CMAKE_FLAGS   := $(SIZE_CFLAGS)
RTCMA_CMAKE_FLAGS := $(SIZE_CFLAGS)
# cmake --build target selection. Native builds the default (all), including
# the shared rtc.dll/rtcma module. Those don't link under mingw (usrsctp's
# GetAdaptersAddresses needs -liphlpapi, which isn't wired for the .dll) and
# aren't needed; the static kitsh link uses only the *_static archives. So
# Windows builds just those targets.
RTC_BUILD_TARGETS   :=
RTCMA_BUILD_TARGETS :=
ifdef WIN
  RTC_CMAKE_FLAGS     := $(SIZE_CFLAGS) -DSTATIC_BUILD -DRTC_STATIC
  RTCMA_CMAKE_FLAGS   := $(SIZE_CFLAGS) -DSTATIC_BUILD -DRTC_STATIC -DOPUS_BUILD
  RTC_BUILD_TARGETS   := --target rtc_tcl_static
  RTCMA_BUILD_TARGETS := --target rtcma rtcma_tcl_static
endif

# ==== Dependency mapping ====
DEP_STAMPS :=
DEP_LIBS =

ifneq (,$(filter tdom,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.tdom_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/tdom*)
endif
ifneq (,$(filter tcllib,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.tcllib_installed
  ifeq ($(strip $(TCLLIB_INCLUDE)),)
    DEP_LIBS += $(wildcard $(PREFIX)/lib/tcllib*)
  else
    # Whitelist mode: pass each requested submodule as its own libdir; it lands
    # at //zipfs:/app/lib/<module>/ and Tcl's auto_path scan discovers it. The
    # umbrella tcllib2.0/ dir is dropped (see _TCL_PKG_EXCLUDE below) — its
    # pkgIndex.tcl hard-codes the full module list and would error on missing
    # subdirs.
    DEP_LIBS += $(foreach m,$(TCLLIB_INCLUDE),$(PREFIX)/lib/tcllib$(TCLLIB_VER)/$(m))
  endif
endif
ifneq (,$(filter mtls,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.mtls_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/mtls*)
endif
ifneq (,$(filter img,$(DEPS)))
  ifeq ($(SHELL_TYPE),tclsh)
    $(error img requires Tk; cannot be used with SHELL_TYPE=tclsh)
  endif
  IMG_ALL_FORMATS := bmp dted flir gif ico jpeg pcx pixmap png ppm ps raw sgi sun tga tiff window xbm xpm
  ifeq ($(strip $(IMG_INCLUDE)),)
    IMG_FORMATS := $(IMG_ALL_FORMATS)
  else
    IMG_FORMATS := $(strip $(IMG_INCLUDE))
    _IMG_BAD := $(filter-out $(IMG_ALL_FORMATS),$(IMG_FORMATS))
    ifneq (,$(_IMG_BAD))
      $(error Unknown IMG_INCLUDE format(s): $(_IMG_BAD). Valid: $(IMG_ALL_FORMATS))
    endif
  endif
  # Base libs are auto-derived from the format whitelist: tkimg is always
  # required; zlibtcl/pngtcl/jpegtcl/tifftcl come in if a format that needs
  # them is selected (see configure.ac's TEA_CONFIG_SUBDIR --with-* args).
  IMG_BASE_PKGS := tkimg
  ifneq (,$(filter png tiff,$(IMG_FORMATS)))
    IMG_BASE_PKGS += zlibtcl
  endif
  ifneq (,$(filter png,$(IMG_FORMATS)))
    IMG_BASE_PKGS += pngtcl
  endif
  ifneq (,$(filter jpeg tiff,$(IMG_FORMATS)))
    IMG_BASE_PKGS += jpegtcl
  endif
  ifneq (,$(filter tiff,$(IMG_FORMATS)))
    IMG_BASE_PKGS += tifftcl
  endif
  # Uppercased token list for the -DWITH_IMG_<NAME> flags fed to kitsh.c.
  # Base vs format names don't collide (e.g. WITH_IMG_TIFF format vs
  # WITH_IMG_TIFFTCL base) so a single combined list is fine.
  IMG_KITSH_DEFINES := $(shell echo $(IMG_BASE_PKGS) $(IMG_FORMATS) | tr a-z A-Z)
  DEP_STAMPS += $(PREFIX)/.img_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/Img$(IMG_VER))
endif
ifneq (,$(filter rtc,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.rtc_installed
  # No DEP_LIBS entry: rtc is fully static-linked into the kitsh binary,
  # so nothing needs to land in the zipfs lib tree — STATIC_PKGS below
  # generates the synthetic pkgIndex.tcl.
endif
ifneq (,$(filter rtcma,$(DEPS)))
  # rtcma consumes libdatachannel + mbedtls from rtc's vendor prefix (the
  # rtc-ma build is invoked with RTCMA_BUNDLE_OPUS=ON only — see recipe
  # below — so its own bundle contains just opus). That means rtc must
  # be enabled too, otherwise rtcma's find_package(LibDataChannel) has
  # nothing to resolve against.
  ifeq (,$(filter rtc,$(DEPS)))
    $(error rtcma requires rtc — add rtc to DEPS)
  endif
  DEP_STAMPS += $(PREFIX)/.rtcma_installed
  # Same as rtc: fully static-linked, no zipfs lib entry.
endif
ifneq (,$(filter omemo,$(DEPS)))
  # picomemo links libmbedcrypto and pulls mbedtls headers from zippy's
  # shared mbedtls install.
  DEP_STAMPS += $(PREFIX)/.omemo_installed
  # Fully static-linked, no zipfs lib entry — see KITSH_DEP_LIBS below.
endif
ifneq (,$(filter tclwuffs,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.tclwuffs_installed
  # Fully static-linked, no zipfs lib entry — see KITSH_DEP_LIBS below.
endif
ifneq (,$(filter tkwuffs,$(DEPS)))
  # tkwuffs's archive depends on symbols from libtclwuffs.a, so the base
  # tier has to be in DEPS too.
  ifeq ($(SHELL_TYPE),tclsh)
    $(error tkwuffs requires Tk; cannot be used with SHELL_TYPE=tclsh)
  endif
  ifeq (,$(filter tclwuffs,$(DEPS)))
    $(error tkwuffs requires tclwuffs — add tclwuffs to DEPS)
  endif
  # No extra DEP_STAMPS entry: .tclwuffs_installed's recipe builds the
  # tkwuffs archive too when tkwuffs is in DEPS.
endif
ifneq (,$(filter tkdnd,$(DEPS)))
  ifeq ($(SHELL_TYPE),tclsh)
    $(error tkdnd requires Tk; cannot be used with SHELL_TYPE=tclsh)
  endif
  DEP_STAMPS += $(PREFIX)/.tkdnd_installed
  # Bundle the lib dir (tkdnd.tcl + platform scripts + pkgIndex.tcl). build.tcl
  # strips the .a out of the copied dir; the archive itself is linked into
  # kitsh via KITSH_DEP_LIBS below.
  DEP_LIBS += $(wildcard $(PREFIX)/lib/tkdnd$(TKDND_VER))
endif

# ==== Tcl/Tk bundled packages ====
# Exclude itcl/tdbc family (not zippy deps) and internal dirs. In tcllib
# whitelist mode also drop the umbrella tcllib2.0/ dir — its pkgIndex.tcl
# hard-codes the full module list and would crash on missing subdirs.
_TCL_PKG_EXCLUDE = pkgconfig tcl9 tk$(TK_BVER) \
    itcl$(ITCL_VER) \
    tdbc$(TDBC_VER) tdbcmysql$(TDBC_VER) tdbcodbc$(TDBC_VER) tdbcpostgres$(TDBC_VER)
ifneq (,$(filter tcllib,$(DEPS)))
  ifneq ($(strip $(TCLLIB_INCLUDE)),)
    _TCL_PKG_EXCLUDE += tcllib$(TCLLIB_VER)
  endif
endif
TCL_PKG_LIBS = $(filter-out $(foreach e,$(_TCL_PKG_EXCLUDE),$(PREFIX)/lib/$e) $(DEP_LIBS),\
                 $(patsubst %/pkgIndex.tcl,%,$(wildcard $(PREFIX)/lib/*/pkgIndex.tcl)))

# ==== KITSH static libs ====
KITSH_BUNDLED_LIBS := \
    $(PREFIX)/lib/thread$(THREAD_VER)/libtcl9thread$(THREAD_VER).a \
    $(PREFIX)/lib/sqlite3.$(SQLITE3_DIR_SUFFIX)/libtcl9sqlite3.$(SQLITE3_DIR_SUFFIX).a

# Lazy expansion so wildcards resolve at recipe time (after deps are built)
KITSH_DEP_LIBS =
KITSH_DEP_FLAGS :=

ifneq (,$(filter tdom,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_TDOM
  KITSH_DEP_LIBS  += $(wildcard $(PREFIX)/lib/tdom*/libtcl9tdom*.a)
endif
ifneq (,$(filter mtls,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_MTLS
  KITSH_DEP_LIBS  += $(wildcard $(PREFIX)/lib/mtls*/libtcl9mtls*.a)
endif
ifneq (,$(filter img,$(DEPS)))
  # Per-module gates in kitsh.c — only the whitelisted Tcl_StaticPackage calls
  # compile in. With nothing referencing the dropped <Pkg>_Init symbols, the
  # corresponding static archives (plus their libpng/libjpeg/libtiff/zlib
  # transitively) get pulled out of the --start-group/--end-group scan.
  KITSH_DEP_FLAGS += $(addprefix -DWITH_IMG_,$(IMG_KITSH_DEFINES))
  # Base archives carry a per-bundle-lib version suffix (zlibtcl uses the
  # zlib version, etc.); format archives all use $(IMG_VER).
  _IMG_LIB_tkimg   = $(PREFIX)/lib/Img$(IMG_VER)/libtcl9tkimg$(IMG_VER).a
  _IMG_LIB_zlibtcl = $(PREFIX)/lib/Img$(IMG_VER)/libtcl9zlibtcl$(IMG_ZLIB_VER).a
  _IMG_LIB_pngtcl  = $(PREFIX)/lib/Img$(IMG_VER)/libtcl9pngtcl$(IMG_PNG_VER).a
  _IMG_LIB_jpegtcl = $(PREFIX)/lib/Img$(IMG_VER)/libtcl9jpegtcl$(IMG_JPEG_VER).a
  _IMG_LIB_tifftcl = $(PREFIX)/lib/Img$(IMG_VER)/libtcl9tifftcl$(IMG_TIFF_VER).a
ifdef WIN
  # The Windows TEA build names archives without dots (libtcl9tkimg211.a), so
  # match them by wildcard. --start-group resolves link order and --gc-sections
  # drops the format modules not gated in via WITH_IMG_*.
  KITSH_DEP_LIBS  += $(wildcard $(PREFIX)/lib/Img$(IMG_VER)/libtcl9*.a)
else
  KITSH_DEP_LIBS  += $(foreach b,$(IMG_BASE_PKGS),$(_IMG_LIB_$(b))) \
                     $(foreach f,$(IMG_FORMATS),$(PREFIX)/lib/Img$(IMG_VER)/libtcl9tkimg$(f)$(IMG_VER).a)
endif
endif

# Linker driver — gcc by default. Rtc / rtcma (C++) flip us to g++ +
# static libstdc++; -xc keeps kitsh.c itself compiled as C so the existing
# C-linkage `extern int <Pkg>_Init(Tcl_Interp *)` decls still match.
KITSH_LD              := gcc
KITSH_KITSH_LANG      :=
KITSH_KITSH_LANG_END  :=
KITSH_EXTRA_LDFLAGS   :=

# rtc bundles libdatachannel/juice/srtp2/usrsctp in $(RTC_BUILD)/vendor; mbedtls
# is consumed via find_package from $(PREFIX) (built by .mbedtls_installed) and
# pulled in by the shared-mbedtls block below.
# rtcma reuses rtc's vendor for libdatachannel and zippy's prefix for mbedtls.
# So at kitsh-link time:
#   - rtc contributes librtc_tcl.a + the libdatachannel vendor archive set
#     (libdatachannel + juice + srtp2 + usrsctp).
#   - rtcma contributes librtcma_tcl.a + librtcma.a + just libopus.a
#     from its own vendor (the only thing it actually bundles).
ifneq (,$(filter rtc,$(DEPS)))
  RTC_BUILD := $(BUILDDIR)/rtc
  KITSH_DEP_FLAGS += -DWITH_RTC
  KITSH_DEP_LIBS  += \
      $(RTC_BUILD)/tcl/librtc_tcl.a \
      $(wildcard $(RTC_BUILD)/vendor/lib/*.a)
endif
ifneq (,$(filter rtcma,$(DEPS)))
  RTCMA_BUILD := $(BUILDDIR)/rtcma
  KITSH_DEP_FLAGS += -DWITH_RTCMA
  KITSH_DEP_LIBS  += \
      $(RTCMA_BUILD)/tcl/librtcma_tcl.a \
      $(RTCMA_BUILD)/librtcma.a \
      $(wildcard $(RTCMA_BUILD)/vendor/lib/libopus*.a)
endif
ifneq (,$(filter omemo,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_OMEMO
  # Built in-tree under OMEMO_BUILD — picomemo's Makefile drops the archive
  # next to the source. Lazy expansion is fine, the recipe below produces it
  # before kitsh links. OMEMO_BUILD == OMEMO_SRC natively; under WIN it is an
  # isolated copy so the cross-build never links the native build's objects.
  KITSH_DEP_LIBS  += $(OMEMO_BUILD)/libtcl9omemo$(OMEMO_VER).a
endif

# Shared mbedtls archives. mtls/rtc/omemo reference these symbols without
# embedding them. everest/p256m are mbedtls 3.6+ per-curve splits.
ifneq (,$(filter mtls rtc omemo,$(DEPS)))
  KITSH_DEP_LIBS  += \
      $(wildcard $(PREFIX)/lib/libmbed*.a) \
      $(wildcard $(PREFIX)/lib/libeverest.a) \
      $(wildcard $(PREFIX)/lib/libp256m.a)
endif

ifneq (,$(filter tclwuffs,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_TCLWUFFS
  KITSH_DEP_LIBS  += $(TCLWUFFS_BUILD)/libtclwuffs$(TCLWUFFS_VER).a
endif
ifneq (,$(filter tkwuffs,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_TKWUFFS
  KITSH_DEP_LIBS  += $(TCLWUFFS_BUILD)/libtkwuffs$(TCLWUFFS_VER).a
endif
ifneq (,$(filter tkdnd,$(DEPS)))
  KITSH_DEP_FLAGS += -DWITH_TKDND
  KITSH_DEP_LIBS  += $(wildcard $(PREFIX)/lib/tkdnd$(TKDND_VER)/libtcl9tkdnd*.a)
endif

# C++ link driver toggle: triggered by any libdatachannel-based dep.
ifneq (,$(filter rtc rtcma,$(DEPS)))
  KITSH_LD := g++
  # -xc forces g++ to treat kitsh.c as C (preserving C linkage on the
  # `extern int <Pkg>_Init(...)` decls); -xnone resets so the trailing
  # .a archives aren't compiled as C source.
  KITSH_KITSH_LANG := -xc
  KITSH_KITSH_LANG_END := -xnone
  # See BundleDeps.cmake: fold libstdc++ static; leave libgcc_s dynamic.
  KITSH_EXTRA_LDFLAGS := -static-libstdc++
endif

KITSH_TCL_LIBS = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl9.0.a $(PREFIX)/lib/libtclstub.a
KITSH_TK_LIBS  = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl9tk$(TK_BVER).a $(PREFIX)/lib/libtcl9.0.a \
    $(PREFIX)/lib/libtkstub.a $(PREFIX)/lib/libtclstub.a
KITSH_CFLAGS      := -I$(PREFIX)/include
KITSH_SYSLIBS     := -lpthread -ldl -lz -lm
# Tk 9 statically pulls in X11, Xft/fontconfig and Xss (XScreenSaver).
# CUPS is dropped via --disable-libcups in the Tk configure step.
KITSH_TK_SYSLIBS  := -lX11 -lXss -lXext -lXft -lfontconfig
# tkdnd's Cursors.c links libXcursor (configure pulls it in when X11/Xcursor/
# Xcursor.h is present). Goes here rather than KITSH_EXTRA_LDFLAGS, which the
# rtc block overwrites with :=; wish-only, since tkdnd is.
ifneq (,$(filter tkdnd,$(DEPS)))
  KITSH_TK_SYSLIBS += -lXcursor
endif

KITSH_TCLSH := $(BUILDDIR)/kitsh_tclsh$(EXE_EXT)
KITSH_WISH  := $(BUILDDIR)/kitsh_wish$(EXE_EXT)
ifdef WIN
  # The Windows launchers are intermediates: they have no script library and
  # error if run directly. Keep them out of $(BUILDDIR)'s top so the only exes
  # there are the runnable, library-bundled wish.exe/tclsh.exe (see windows.mk).
  KITSH_TCLSH := $(BUILDDIR)/_launcher/kitsh_tclsh$(EXE_EXT)
  KITSH_WISH  := $(BUILDDIR)/_launcher/kitsh_wish$(EXE_EXT)
endif

# ==== Select base interpreter ====
ifeq ($(SHELL_TYPE),tclsh)
  BASE_INTERP := $(KITSH_TCLSH)
else
  BASE_INTERP := $(KITSH_WISH)
endif

# ==== Built-in excludes ====
_BUILTIN_EXCLUDES := $(notdir $(ZIPPYDIR)) _build Makefile
ifdef BIN_NAME
  _BUILTIN_EXCLUDES += $(BIN_NAME)
endif
_ALL_EXCLUDES := $(_BUILTIN_EXCLUDES) $(APP_EXCLUDE)
_EXCLUDES_CSV := $(subst $(eval ) ,$(shell echo ','),$(_ALL_EXCLUDES))
_SOURCES_CSV  := $(subst $(eval ) ,$(shell echo ','),$(SOURCES))

# ==== Static-package wiring (pkg:loadname:version) ====
# kitsh.c registers each via Tcl_StaticPackage; build.tcl turns this list into
# a single pkgIndex.tcl so `package require` resolves through `load {} <name>`.
STATIC_PKGS := Thread:Thread:$(THREAD_VER) sqlite3:Sqlite3:$(SQLITE3_VER)
ifneq (,$(filter tdom,$(DEPS)))
  STATIC_PKGS += tdom:tdom:$(TDOM_VER)
endif
ifneq (,$(filter mtls,$(DEPS)))
  STATIC_PKGS += mtls:Mtls:$(MTLS_VER)
endif
ifneq (,$(filter rtc,$(DEPS)))
  STATIC_PKGS += rtc:Rtc:$(RTC_VER)
endif
ifneq (,$(filter rtcma,$(DEPS)))
  STATIC_PKGS += rtcma:Rtcma:$(RTCMA_VER)
endif
ifneq (,$(filter omemo,$(DEPS)))
  STATIC_PKGS += omemo:Omemo:$(OMEMO_VER)
endif
ifneq (,$(filter tclwuffs,$(DEPS)))
  STATIC_PKGS += tclwuffs:Tclwuffs:$(TCLWUFFS_VER)
endif
ifneq (,$(filter tkwuffs,$(DEPS)))
  STATIC_PKGS += tkwuffs:Tkwuffs:$(TCLWUFFS_VER)
endif
_STATIC_PKGS_CSV := $(subst $(eval ) ,$(shell echo ','),$(STATIC_PKGS))

# ==== Default target ====
ifdef BIN_NAME
  .DEFAULT_GOAL := app
else
  .DEFAULT_GOAL := $(SHELL_TYPE)
endif

.PHONY: app wish tclsh download test clean distclean

# ==== Download ====

$(DEPSDIR)/$(TCL_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ $(TCL_URL)
	echo "$(TCL_SHA256)  $@" | sha256sum -c

$(DEPSDIR)/$(TK_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ $(TK_URL)
	echo "$(TK_SHA256)  $@" | sha256sum -c

$(DEPSDIR)/$(TDOM_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ $(TDOM_URL)
	echo "$(TDOM_SHA256)  $@" | sha256sum -c

$(DEPSDIR)/$(TCLLIB_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ $(TCLLIB_URL)
	echo "$(TCLLIB_SHA256)  $@" | sha256sum -c

$(MTLS_SRC):
	git clone $(MTLS_REPO) $(MTLS_SRC)
	cd $(MTLS_SRC) && git checkout $(MTLS_COMMIT) && git submodule update --init --recursive

$(MBEDTLS_SRC):
	git clone $(MBEDTLS_REPO) $(MBEDTLS_SRC)
	cd $(MBEDTLS_SRC) && git checkout $(MBEDTLS_COMMIT) && git submodule update --init --recursive

$(RTC_SRC):
	git clone $(RTC_REPO) $(RTC_SRC)
	cd $(RTC_SRC) && git checkout $(RTC_COMMIT) && git submodule update --init --recursive

$(RTCMA_SRC):
	git clone $(RTCMA_REPO) $(RTCMA_SRC)
	cd $(RTCMA_SRC) && git checkout $(RTCMA_COMMIT) && git submodule update --init --recursive

$(OMEMO_SRC):
	git clone $(OMEMO_REPO) $(OMEMO_SRC)
	cd $(OMEMO_SRC) && git checkout $(OMEMO_COMMIT) && git submodule update --init --recursive

$(TCLWUFFS_SRC):
	git clone $(TCLWUFFS_REPO) $(TCLWUFFS_SRC)
	cd $(TCLWUFFS_SRC) && git checkout $(TCLWUFFS_COMMIT) && git submodule update --init --recursive

$(TKDND_SRC):
	git clone $(TKDND_REPO) $(TKDND_SRC)
	cd $(TKDND_SRC) && git checkout $(TKDND_COMMIT) && git submodule update --init --recursive

$(DEPSDIR)/$(IMG_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ "$(IMG_URL)"
	echo "$(IMG_SHA256)  $@" | sha256sum -c

download: $(DEPSDIR)/$(TCL_TAR) $(DEPSDIR)/$(TK_TAR) $(DEPSDIR)/$(TDOM_TAR) $(DEPSDIR)/$(TCLLIB_TAR) $(MTLS_SRC) $(MBEDTLS_SRC) $(RTC_SRC) $(RTCMA_SRC) $(OMEMO_SRC) $(TCLWUFFS_SRC) $(TKDND_SRC) $(DEPSDIR)/$(IMG_TAR)

# ==== Extract ====

$(TCL_SRC): $(DEPSDIR)/$(TCL_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

$(TK_SRC): $(DEPSDIR)/$(TK_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

$(TCLLIB_SRC): $(DEPSDIR)/$(TCLLIB_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

$(DEPSDIR)/.tdom_extracted: $(DEPSDIR)/$(TDOM_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

$(IMG_SRC): $(DEPSDIR)/$(IMG_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

# ==== Build Tcl/Tk ====
# Native builds in unix/; the Windows cross-build (win/) lives in windows.mk,
# so these native recipes are guarded out when WIN is set.
ifndef WIN
$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/unix && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --enable-zipfs --disable-shared --with-system-libtommath=no && \
		sed -i 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries && \
		cp $(TCL_SRC)/pkgs/thread$(THREAD_VER)/lib/ttrace.tcl $(PREFIX)/lib/thread$(THREAD_VER)/

$(WISH): $(TK_SRC) $(TCLSH)
	cd $(TK_SRC)/unix && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --enable-zipfs --disable-shared --disable-libcups && \
		sed -i 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries

endif

# ==== Build extensions ====

# tdom (and the other compiled extensions below) build natively here; the
# Windows cross-build variants live in windows.mk, so guard the native recipe.
ifndef WIN
$(PREFIX)/.tdom_installed: $(DEPSDIR)/.tdom_extracted $(TCLSH)
	cd $$(ls -d $(DEPSDIR)/tdom-*/) && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@
endif

# `make install` also builds tcllib's optional critcl C accelerators, which
# can't cross-compile (it shells out for a target tclsh.exe). Windows installs
# the pure-Tcl modules only (install-tcl); see windows.mk.
ifndef WIN
$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install
	touch $@
endif

# Builds against zippy's shared mbedtls, not mtls's own submodule.
# MBEDTLS_USER_CONFIG_FILE must match what libmbedtls.a was compiled with,
# otherwise struct layouts diverge between mtls and libmbedtls.
ifndef WIN
$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH) $(PREFIX)/.mbedtls_installed
	mkdir -p $(MTLS_SRC)/build
	cd $(MTLS_SRC)/build && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		../configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared \
			--with-mbedtls=$(PREFIX) \
			CPPFLAGS='-DMBEDTLS_USER_CONFIG_FILE=\"$(MBEDTLS_USER_CFG)\"' && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@
endif

# Img: configure with --disable-shared builds .a files but its `make install`
# target only assembles the umbrella pkgIndex.tcl in shared builds. We install
# manually: copy the .a files into Img$(IMG_VER)/ and emit a pkgIndex.tcl that
# resolves every sub-package via `load {} <Prefix>` — wired to the
# Tcl_StaticPackage entries in kitsh.c.
IMG_PKGINDEX_TCL := $(ZIPPYDIR)/img_pkgindex.tcl

ifndef WIN
$(PREFIX)/.img_installed: $(IMG_SRC) $(WISH) $(IMG_PKGINDEX_TCL)
	mkdir -p $(IMG_SRC)/build
	cd $(IMG_SRC)/build && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		../configure --prefix=$(PREFIX) \
			--with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib \
			--disable-shared && \
		$(MAKE) -j$(NPROC)
	rm -rf $(PREFIX)/lib/Img$(IMG_VER)
	mkdir -p $(PREFIX)/lib/Img$(IMG_VER)
	find $(IMG_SRC)/build -name 'libtcl9*.a' -exec cp {} $(PREFIX)/lib/Img$(IMG_VER)/ \;
	$(TCLSH) $(IMG_PKGINDEX_TCL) \
		$(PREFIX)/lib/Img$(IMG_VER)/pkgIndex.tcl \
		$(IMG_VER) $(IMG_ZLIB_VER) $(IMG_PNG_VER) $(IMG_JPEG_VER) $(IMG_TIFF_VER) \
		"$(IMG_BASE_PKGS)" "$(IMG_FORMATS)"
	touch $@
endif

# MBEDTLS_USER_CONFIG_FILE propagates as a PUBLIC compile def to consumers
# via find_package(MbedTLS), so all callers see matching struct layouts.
$(PREFIX)/.mbedtls_installed: $(MBEDTLS_SRC)
	cmake -S $(MBEDTLS_SRC) -B $(BUILDDIR)/mbedtls $(CMAKE_TOOLCHAIN) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DCMAKE_INSTALL_PREFIX=$(PREFIX) \
		-DENABLE_PROGRAMS=OFF \
		-DENABLE_TESTING=OFF \
		-DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
		-DUSE_STATIC_MBEDTLS_LIBRARY=ON \
		-DMBEDTLS_FATAL_WARNINGS=OFF \
		-DMBEDTLS_USER_CONFIG_FILE=$(MBEDTLS_USER_CFG) \
		-DCMAKE_C_FLAGS="$(SIZE_CFLAGS)"
	cmake --build $(BUILDDIR)/mbedtls -j$(NPROC)
	cmake --install $(BUILDDIR)/mbedtls
	touch $@

# RTC_BUNDLE_LIBDATACHANNEL=ON rebuilds libdatachannel/juice/srtp2/usrsctp
# into static archives under the build tree's vendor/lib; mbedtls is
# resolved via find_package against $(PREFIX).
$(PREFIX)/.rtc_installed: $(TCLSH) $(RTC_SRC) $(PREFIX)/.mbedtls_installed
	cmake -S $(RTC_SRC) -B $(BUILDDIR)/rtc $(CMAKE_TOOLCHAIN) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTC_BUNDLE_LIBDATACHANNEL=ON \
		-DCMAKE_C_FLAGS="$(RTC_CMAKE_FLAGS)" \
		-DCMAKE_CXX_FLAGS="$(RTC_CMAKE_FLAGS)" \
		-DCMAKE_PREFIX_PATH=$(PREFIX)
	cmake --build $(BUILDDIR)/rtc -j$(NPROC) $(RTC_BUILD_TARGETS)
	mkdir -p $(PREFIX)
	touch $@

# Rtcma: out-of-tree cmake build. RTCMA_BUNDLE_OPUS=ON builds opus from
# source into the build tree's vendor/ prefix; libdatachannel comes from
# rtc's vendor install and mbedtls from $(PREFIX) (see MbedTLS_DIR /
# CMAKE_PREFIX_PATH below). RTCMA_BUILD_TCL=ON pulls in tcl/CMakeLists.txt,
# which emits librtcma_tcl.a (the Tcl 9 extension archive whose Rtcma_Init
# we wire into kitsh.c via Tcl_StaticPackage) alongside librtcma.a (the
# audio adapter library itself).
#
# The order-only dependency on .rtc_installed makes sure rtc's vendor
# install exists before rtcma's configure runs; the DEP_STAMPS block
# above already errors out at make-parse time if rtc isn't in DEPS.
$(PREFIX)/.rtcma_installed: $(TCLSH) $(RTCMA_SRC) $(PREFIX)/.rtc_installed
	cmake -S $(RTCMA_SRC) -B $(BUILDDIR)/rtcma $(CMAKE_TOOLCHAIN) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTCMA_BUNDLE_OPUS=ON \
		-DRTCMA_BUILD_TCL=ON \
		-DCMAKE_C_FLAGS="$(RTCMA_CMAKE_FLAGS)" \
		-DCMAKE_CXX_FLAGS="$(RTCMA_CMAKE_FLAGS)" \
		-DLibDataChannel_DIR=$(BUILDDIR)/rtc/vendor/lib/cmake/LibDataChannel \
		-DMbedTLS_DIR=$(PREFIX)/lib/cmake/MbedTLS \
		-DCMAKE_PREFIX_PATH='$(PREFIX);$(BUILDDIR)/rtc/vendor'
	cmake --build $(BUILDDIR)/rtcma -j$(NPROC) $(RTCMA_BUILD_TARGETS)
	mkdir -p $(PREFIX)
	touch $@

# Shell out to picomemo's own Makefile. -fPIC overrides its STATIC_CF
# default so the archive links into our PIE kitsh binary.
ifndef WIN
$(PREFIX)/.omemo_installed: $(TCLSH) $(OMEMO_SRC) $(PREFIX)/.mbedtls_installed
	$(MAKE) -C $(OMEMO_SRC) libtcl9omemo$(OMEMO_VER).a \
		TCL_PREFIX=$(PREFIX) \
		MBED_PREFIX=$(PREFIX) \
		CFLAGS="-fPIC $(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@
endif

# Point TC{L,K}CONFIG at our install so tclwuffs's autodetect picks our
# static headers/stubs over any system Tcl/Tk. -fPIC overrides upstream's
# STATIC_CF default for our PIE kitsh link.
TCLWUFFS_MAKE_TARGETS := tclwuffs
TCLWUFFS_EXTRA_DEPS   :=
ifneq (,$(filter tkwuffs,$(DEPS)))
  TCLWUFFS_MAKE_TARGETS += tkwuffs
  TCLWUFFS_EXTRA_DEPS   := $(WISH)
endif

ifndef WIN
$(PREFIX)/.tclwuffs_installed: $(TCLSH) $(TCLWUFFS_SRC) $(TCLWUFFS_EXTRA_DEPS)
	$(MAKE) -C $(TCLWUFFS_SRC) $(TCLWUFFS_MAKE_TARGETS) \
		TCLCONFIG=$(PREFIX)/lib/tclConfig.sh \
		TKCONFIG=$(PREFIX)/lib/tkConfig.sh \
		CFLAGS="-fPIC $(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@
endif

# A static (--disable-shared) `make install` skips pkgIndex.tcl (gated on a
# shared build), as with Img, so the lib dir is installed manually: the archive,
# the Tcl scripts, and the configure-generated pkgIndex.tcl. tkdnd's pkgIndex
# loads the binary indirectly through tkdnd::initialise (in tkdnd.tcl), so that
# `load $dir/$PKG_LIB_FILE` is rewritten to `load {}` to resolve through the
# Tcl_StaticPackage("Tkdnd") entry in kitsh.c. tkdnd is therefore kept out of
# STATIC_PKGS — its own pkgIndex already registers `package ifneeded`. Tk
# private headers (tkInt.h) come from the Tk source tree via tkConfig.sh's
# TK_SRC_DIR, hence the $(WISH) dependency.
ifndef WIN
$(PREFIX)/.tkdnd_installed: $(TKDND_SRC) $(WISH)
	mkdir -p $(TKDND_SRC)/build
	cd $(TKDND_SRC)/build && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		../configure --prefix=$(PREFIX) \
			--with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib \
			--disable-shared && \
		$(MAKE) -j$(NPROC)
	rm -rf $(PREFIX)/lib/tkdnd$(TKDND_VER)
	mkdir -p $(PREFIX)/lib/tkdnd$(TKDND_VER)
	cp $(TKDND_SRC)/build/libtcl9tkdnd$(TKDND_VER).a $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	cp $(TKDND_SRC)/library/*.tcl $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	cp $(TKDND_SRC)/build/pkgIndex.tcl $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	sed -i 's|load $$dir/$$PKG_LIB_FILE|load {}|' $(PREFIX)/lib/tkdnd$(TKDND_VER)/tkdnd.tcl
	touch $@
endif

# ==== KITSH launcher ====

# Strip the kitsh launcher and stash debug info to a sidecar. Has to run here,
# before build.tcl appends the zipfs payload — strip rewrites ELF section
# layout, which would invalidate the absolute offsets in the appended ZIP
# central directory. The sidecar is later copied next to the shipped binary.
define maybe_strip_kitsh
$(if $(filter 1,$(STRIP)),objcopy --only-keep-debug $(1) $(1).debug && strip -s $(1),true)
endef

$(KITSH_TCLSH): $(ZIPPYDIR)/kitsh.c $(TCLSH) $(DEP_STAMPS)
	mkdir -p $(@D)
	$(KITSH_LD) $(KITSH_CFLAGS) $(SIZE_CFLAGS) $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		-Wl,--start-group $(KITSH_TCL_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS) $(KITSH_EXTRA_LDFLAGS) $(SIZE_LDFLAGS)
	$(call maybe_strip_kitsh,$@)

$(KITSH_WISH): $(ZIPPYDIR)/kitsh.c $(WISH) $(DEP_STAMPS)
	mkdir -p $(@D)
	$(KITSH_LD) $(KITSH_CFLAGS) $(SIZE_CFLAGS) -DWITH_TK $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		-Wl,--start-group $(KITSH_TK_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS) $(KITSH_TK_SYSLIBS) $(KITSH_EXTRA_LDFLAGS) $(SIZE_LDFLAGS)
	$(call maybe_strip_kitsh,$@)

# ==== App ====

# Place the kitsh launcher's .debug sidecar next to the shipped binary so a
# crash address can be resolved with `addr2line -e <binary>.debug 0x...`.
define maybe_copy_debug
$(if $(filter 1,$(STRIP)),cp $(1).debug $(2).debug,true)
endef

ifdef BIN_NAME
app: $(BASEDIR)/$(BIN_NAME)

$(BASEDIR)/$(BIN_NAME): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ $(_SOURCES_CSV) $(ENTRY_SCRIPT) $(_EXCLUDES_CSV) $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
	$(call maybe_copy_debug,$(BASE_INTERP),$@)
endif

# ==== Standalone interpreters ====

wish: $(BASEDIR)/wish

$(BASEDIR)/wish: $(KITSH_WISH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) wish $(BASEDIR) $@ "" "" "" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
	$(call maybe_copy_debug,$(KITSH_WISH),$@)

tclsh: $(BASEDIR)/tclsh

$(BASEDIR)/tclsh: $(KITSH_TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" "" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
	$(call maybe_copy_debug,$(KITSH_TCLSH),$@)

# ==== Test ====
# Smoke test that builds standalone tclsh/wish across DEPS combinations and
# asserts each works end-to-end. Depends on $(TCLSH)/$(WISH) so the Tcl/Tk
# bootstrap is done before the per-case rebuilds.
test: $(TCLSH) $(WISH)
	$(ZIPPYDIR)/tests/smoke.sh

# ==== Clean ====

clean:
	rm -rf $(BUILDDIR)
ifdef BIN_NAME
	rm -f $(BASEDIR)/$(BIN_NAME) $(BASEDIR)/$(BIN_NAME).debug
endif
	rm -f $(BASEDIR)/wish$(EXE_EXT) $(BASEDIR)/wish$(EXE_EXT).debug \
	      $(BASEDIR)/tclsh$(EXE_EXT) $(BASEDIR)/tclsh$(EXE_EXT).debug

distclean: clean

# ==== Windows cross-build ====
# Tcl/Tk (win/) + thread/sqlite3 TEA recipes and the kitsh link-var overrides.
# Included last so its KITSH_* assignments take precedence. No-op when native.
ifdef WIN
include $(ZIPPYDIR)/windows.mk
endif
