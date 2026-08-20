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

# ==== Host tool portability ====
# macOS has shasum rather than sha256sum (both take -c over "<hash>  <file>"),
# and BSD sed's -i requires a backup-suffix argument where GNU sed's is optional.
SHA256SUM        := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo shasum -a 256)
# Whole-tree copy (see git-dep). GNU cp shares extents on btrfs/xfs, making the
# copy near-free; BSD/macOS cp pays a real one. --version detects GNU.
CP_TREE          := $(shell cp --version >/dev/null 2>&1 && echo "cp -a --reflink=auto" || echo "cp -a")
SED_INPLACE_FLAG := $(shell sed --version >/dev/null 2>&1 && echo -i || echo "-i ''")

# ==== Target platform ====
# TARGET_OS selects the build target; default (unset/linux) is the native build.
# The Windows variables below are empty when TARGET_OS != windows, so the native
# build is unchanged. TARGET_OS=windows cross-compiles a static PE via MinGW-w64;
# the divergent Tcl/Tk + TEA package recipes live in windows.mk (included at the
# bottom). The Windows tree sits under _build-win, separate from a native _build.
#
# The default follows the build host, so a plain `make` on a Mac targets macos.
# macos is a *native* target, not a cross one: the built interp runs on the
# build host, so CROSS_OVERLAY stays unset and the native bundling path applies.
# Its toolchain differences (ld64 vs GNU ld, Tk on Aqua vs X11) are all
# flag-level, so it needs no overlay file — the seams below absorb them.
ifeq ($(shell uname -s),Darwin)
  TARGET_OS  ?= macos
else
  TARGET_OS  ?= linux
endif
ifeq ($(TARGET_OS),windows)
  WIN          := 1
  CROSS_OVERLAY := 1
  CROSS        := x86_64-w64-mingw32
  CROSS_BUILD  := x86_64-pc-linux-gnu
  EXE_EXT      := .exe
  BUILDDIR     := $(BASEDIR)/_build-win
  # find_package/ExternalProject in the cmake deps need the mingw toolchain.
  CMAKE_TOOLCHAIN := -DCMAKE_TOOLCHAIN_FILE=$(ZIPPYDIR)/mingw-toolchain.cmake
else ifeq ($(TARGET_OS),android)
  # CROSS is the autotools triple; the clang wrapper, ABI and platform live in
  # android.mk. arm64-v8a only ships a shared libc++, so STATIC_LIBSTDCXX=0 (read
  # by a parse-time ifeq below, so it stays in the seam).
  ANDROID      := 1
  CROSS_OVERLAY := 1
  CROSS        := aarch64-linux-android
  CROSS_BUILD  := x86_64-pc-linux-gnu
  EXE_EXT      :=
  BUILDDIR     := $(BASEDIR)/_build-android
  STATIC_LIBSTDCXX := 0
  CMAKE_TOOLCHAIN := -DCMAKE_TOOLCHAIN_FILE=$(ZIPPYDIR)/android-toolchain.cmake
else ifeq ($(TARGET_OS),macos)
  # Shares _build with the Linux native build: only one of the two can be the
  # host, so they never collide in one checkout.
  MACOS        := 1
  EXE_EXT      :=
  BUILDDIR     := $(BASEDIR)/_build
  # No cross toolchain, but the SDK ships Apple's Tcl 8.5 as a framework and
  # cmake's find_path prefers frameworks over CMAKE_PREFIX_PATH on Darwin — left
  # at the default, rtc resolves tcl.h to Tcl 8.5 and fails on Tcl_Size. LAST
  # demotes frameworks; explicit -framework link flags are unaffected.
  CMAKE_TOOLCHAIN := -DCMAKE_FIND_FRAMEWORK=LAST
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
#
# Overridable so targets with different BASEDIRs can share one cache, and so an
# offline build can be handed a pre-seeded one.
DEPSDIR      ?= $(BASEDIR)/_build/deps
BUILD_TCL    := $(ZIPPYDIR)/build.tcl

SHELL_TYPE   ?= wish
SOURCES      ?= ./
ENTRY_SCRIPT ?= main.tcl
STRIP        ?= 1
GC_SECTIONS  ?= 1

# Where source patches live ($(PATCHES_DIR)/<tree>/*.patch; see "Source
# patches"). $(CURDIR) is the consuming project's root, so a vendored zippy
# reads patches from the app rather than its own tree. Not BASEDIR: a project
# may repoint that at a build dir.
PATCHES_DIR  ?= $(CURDIR)/patches

# Backward-compat alias: APP_DIR → SOURCES (single entry).
ifneq ($(origin APP_DIR),undefined)
  SOURCES := $(APP_DIR)
  $(warning APP_DIR is deprecated; use SOURCES instead.)
endif

# ==== Versions ====
# Every dep's checkout path carries its version or pin, so bumping one names a
# path that doesn't exist yet and make refetches. The *_COMMIT pins need this:
# the git rules clone-then-checkout, and make would otherwise see an existing
# directory, skip the recipe and silently keep the old commit. Old checkouts
# stay behind until `make distclean`.
TCL_VER    := 9.0.3
TK_VER     := 9.0.3
TCLLIB_VER := 2.0
TDOM_VER   := 0.9.6
MTLS_VER   := 1.2.0
TCL_BVER   := 9.0
TK_BVER    := 9.0

# Fork of chpock/tclmtls: tracks upstream plus a POSIX fix to configure (== -> =)
# so the Tcl 9 build detection works under dash (/bin/sh on Debian/Ubuntu/Termux,
# i.e. the docker toolchains); without it mtls silently builds as Tcl 8 and SEGVs
# in a Tcl 9 interp. Drop the fork once that fix lands upstream.
MTLS_COMMIT := 0d4055aa3f9bb5ef827e2ee76281102f54c7eca0

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
MBEDTLS_SRC       := $(DEPSDIR)/mbedtls-$(MBEDTLS_COMMIT)
MBEDTLS_USER_CFG  := $(ZIPPYDIR)/mbedtls-user-config.h

# Rtc (libdatachannel-tcl). C++ Tcl 9 binding for libdatachannel. Built via
# cmake with RTC_BUNDLE_LIBDATACHANNEL=ON so libdatachannel/juice/srtp2/
# usrsctp fold in as static archives; mbedtls comes from zippy's shared
# install via find_package.
RTC_VER    := 0.1.0
RTC_REPO   := https://github.com/pounceandmiss/libdatachannel-tcl.git
RTC_COMMIT := 9ae99076fd98df9157637b54d98fbe9bfb4b7ce0
RTC_SRC    := $(DEPSDIR)/libdatachannel-tcl-$(RTC_COMMIT)

# libdatachannel: rtc's WebRTC core, pre-staged so its cmake builds offline.
LIBDC_REPO   := https://github.com/paullouisageneau/libdatachannel.git
LIBDC_COMMIT := c47f5d77c124c35c31ac8378ad613295a124d354
LIBDC_SRC    := $(DEPSDIR)/libdatachannel-$(LIBDC_COMMIT)

# Rtcma (rtc-ma). Audio-over-libdatachannel adapter (miniaudio + opus +
# jitter buffer + SDP) with its own Tcl 9 binding. Built via cmake with
# RTCMA_BUNDLE_OPUS=ON only; libdatachannel comes from rtc's vendor and
# mbedtls from zippy's shared install, which is why `rtc` must also be in
# DEPS (enforced below).
RTCMA_VER    := 0.1.0
RTCMA_REPO   := https://github.com/pounceandmiss/rtc-ma.git
RTCMA_COMMIT := 07442896dce38ccc150c5b396bbd6b39cbcf3545
RTCMA_SRC    := $(DEPSDIR)/rtc-ma-$(RTCMA_COMMIT)

# opus: rtc-ma's audio codec, pre-staged tarball so its cmake builds offline.
OPUS_VER    := 1.6.1
OPUS_TAR    := opus-$(OPUS_VER).tar.gz
OPUS_URL    := https://downloads.xiph.org/releases/opus/$(OPUS_TAR)
OPUS_SHA256 := 6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
OPUS_SRC    := $(DEPSDIR)/opus-$(OPUS_VER)

# Omemo (picomemo-tcl). Tcl 9 binding for picomemo.
OMEMO_VER    := 0.3.0
OMEMO_REPO   := https://github.com/pounceandmiss/picomemo-tcl.git
OMEMO_COMMIT := 9523cb71d85510f61f342c84b1fc8176aff8797f
OMEMO_SRC    := $(DEPSDIR)/picomemo-tcl-$(OMEMO_COMMIT)

# Tclwuffs. Memory-safe image decode/encode/resize on wuffs+stb. Two tiers:
# `tclwuffs` (no-Tk) and `tkwuffs` (Tk photo bridge); the shared wuffs/stb
# glue lives only in libtclwuffs.a.
TCLWUFFS_VER    := 0.1.0
TCLWUFFS_REPO   := https://github.com/pounceandmiss/tclwuffs.git
TCLWUFFS_COMMIT := ddd4721499e2a2ad5f6ee0568c816591fbaf7e1b
TCLWUFFS_SRC    := $(DEPSDIR)/tclwuffs-$(TCLWUFFS_COMMIT)

# Tkdnd. Native drag-and-drop for Tk (X11 XDND). TEA build that also ships Tcl
# support scripts (tkdnd.tcl + per-platform files) beside the static archive.
# Requires Tk (private headers + X11 selection), so wish-only. See the install
# recipe for the static-link wiring.
TKDND_VER    := 2.9.5
TKDND_REPO   := https://github.com/petasis/tkdnd.git
TKDND_COMMIT := 6efca37a22b93b2336dc973f2b4a9ba1e3feceaf
TKDND_SRC    := $(DEPSDIR)/tkdnd-$(TKDND_COMMIT)

# sqlite3 dir/lib suffix collapses the leading "3." of SQLITE3_VER into the "3"
# of the package name (dir is sqlite3.51.0 for version 3.51.0).
SQLITE3_DIR_SUFFIX := $(patsubst 3.%,%,$(SQLITE3_VER))

# ==== Tarballs ====
TCL_TAR    := tcl$(TCL_VER)-src.tar.gz
TK_TAR     := tk$(TK_VER)-src.tar.gz
# Upstream serves tdom from a rolling "latest" URL, so the local name has to
# carry the version: a fixed name would keep an old tarball forever, and its
# recipe (hence the sha256 check) never re-runs once the file exists.
TDOM_TAR   := tdom-$(TDOM_VER)-src.tar.gz
TCLLIB_TAR := tcllib-$(TCLLIB_VER).tar.gz
IMG_TAR    := Img-$(IMG_VER).tar.gz

# ==== URLs ====
TCL_URL    := http://prdownloads.sourceforge.net/tcl/$(TCL_TAR)
TK_URL     := http://prdownloads.sourceforge.net/tcl/$(TK_TAR)
TDOM_URL   := https://tdom.org/downloads/latest-src.tar.gz
TCLLIB_URL := https://core.tcl-lang.org/tcllib/uv/$(TCLLIB_TAR)
MTLS_REPO  := https://github.com/pounceandmiss/tclmtls.git
MTLS_SRC   := $(DEPSDIR)/tclmtls-$(MTLS_COMMIT)
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
TDOM_SRC   := $(DEPSDIR)/tdom-$(TDOM_VER)-src

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

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Size optimization: emit per-function/data sections in every dep so the kitsh
# link can drop unreferenced ones with --gc-sections. Both halves are needed —
# the flag on the link alone does nothing if the static archives were compiled
# without per-section granularity. When GC_SECTIONS=0 these vars are empty and
# the CFLAGS=/CMAKE_C_FLAGS= insertions in the recipes become no-ops.
ifeq ($(GC_SECTIONS),1)
  SIZE_CFLAGS  := -ffunction-sections -fdata-sections
  # ld64 has no --gc-sections; -dead_strip is the Mach-O equivalent.
  ifdef MACOS
    SIZE_LDFLAGS := -Wl,-dead_strip
  else
    SIZE_LDFLAGS := -Wl,--gc-sections
  endif
else
  SIZE_CFLAGS  :=
  SIZE_LDFLAGS :=
endif

# ==== Reproducible builds ====
# Opt-in via SOURCE_DATE_EPOCH; unset leaves dev builds with real debug paths.
# Zip entry mtimes are handled in build.tcl, which reads it from the environment.
# DEPSDIR is mapped before BUILDDIR because it nests inside it by default and
# gcc takes the first matching prefix.
ifdef SOURCE_DATE_EPOCH
  export SOURCE_DATE_EPOCH
  REPRO_CFLAGS := -ffile-prefix-map=$(DEPSDIR)=/zippy/deps \
                  -ffile-prefix-map=$(BUILDDIR)=/zippy/build \
                  -ffile-prefix-map=$(ZIPPYDIR)=/zippy \
                  -ffile-prefix-map=$(BASEDIR)=/zippy/src
  # Folded into SIZE_CFLAGS: that string already reaches every dep recipe and
  # the kitsh link. Needs gcc 8+ / clang 10+.
  SIZE_CFLAGS += $(REPRO_CFLAGS)
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
# aren't needed; the static kitsh link uses only the *_static archives. macOS
# skips them for a different reason: rtc-ma's test programs call
# clock_nanosleep(), which Darwin lacks. Both build just the static targets.
RTC_BUILD_TARGETS   :=
RTCMA_BUILD_TARGETS :=
ifdef WIN
  RTC_CMAKE_FLAGS     := $(SIZE_CFLAGS) -DSTATIC_BUILD -DRTC_STATIC
  RTCMA_CMAKE_FLAGS   := $(SIZE_CFLAGS) -DSTATIC_BUILD -DRTC_STATIC -DOPUS_BUILD
endif
ifneq (,$(WIN)$(MACOS))
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
  # Only the X11 XDND backend is wired up here; tkdnd's separate Objective-C
  # macOS backend is not, so there is nothing to build against Aqua.
  ifdef MACOS
    $(error tkdnd is X11-only in this build; not supported on TARGET_OS=macos)
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
# Extra objects for the kitsh link. Empty natively; windows.mk adds a
# windres-compiled icon resource here when WIN_ICON is set.
KITSH_EXTRA_OBJS      :=

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
  # Platforms that only ship a shared C++ runtime (Android/Termux: libc++_shared.so,
  # no static libstdc++) build with STATIC_LIBSTDCXX=0.
  ifeq ($(STATIC_LIBSTDCXX),0)
    KITSH_EXTRA_LDFLAGS :=
  else
    KITSH_EXTRA_LDFLAGS := -static-libstdc++
  endif
endif

KITSH_TCL_LIBS = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl9.0.a $(PREFIX)/lib/libtclstub.a
KITSH_TK_LIBS  = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl9tk$(TK_BVER).a $(PREFIX)/lib/libtcl9.0.a \
    $(PREFIX)/lib/libtkstub.a $(PREFIX)/lib/libtclstub.a
KITSH_CFLAGS      := -I$(PREFIX)/include
KITSH_SYSLIBS     := -lpthread -ldl -lz -lm
ifdef MACOS
  # CoreFoundation is not Tk-only: Tcl's own notifier (CFRunLoop) and bundle
  # loader need it, so tclsh links it too. Matches TCL_LIBS in tclConfig.sh.
  KITSH_SYSLIBS += -framework CoreFoundation
  # ld64 re-scans archives to a fixed point and rejects --start-group outright.
  LINK_GROUP_START :=
  LINK_GROUP_END   :=
  # Mirrors TK_LIBS in the generated tkConfig.sh, minus what KITSH_SYSLIBS
  # already carries. UniformTypeIdentifiers must stay weak: it only exists on
  # macOS 11+, and a hard link stops the binary launching on older systems.
  KITSH_TK_SYSLIBS := -framework Cocoa -framework Carbon -framework IOKit \
      -framework QuartzCore -framework Security -framework CoreGraphics \
      -weak_framework UniformTypeIdentifiers
else
  # GNU ld needs an explicit group for the mutual references between the Tcl/Tk
  # archives and the dep archives.
  LINK_GROUP_START := -Wl,--start-group
  LINK_GROUP_END   := -Wl,--end-group
  # Tk 9 statically pulls in X11, Xft/fontconfig and Xss (XScreenSaver).
  # CUPS is dropped via --disable-libcups in the Tk configure step.
  KITSH_TK_SYSLIBS := -lX11 -lXss -lXext -lXft -lfontconfig
endif
# tkdnd's Cursors.c links libXcursor (configure pulls it in when X11/Xcursor/
# Xcursor.h is present). Goes here rather than KITSH_EXTRA_LDFLAGS, which the
# rtc block overwrites with :=; wish-only, since tkdnd is.
ifneq (,$(filter tkdnd,$(DEPS)))
  KITSH_TK_SYSLIBS += -lXcursor
endif
# The mbedtls-based deps read the system trust store through the keychain
# (SecTrustSettingsCopyCertificates), which lives in the Security framework.
ifdef MACOS
ifneq (,$(filter mtls rtc rtcma omemo,$(DEPS)))
  KITSH_SYSLIBS += -framework Security
endif
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
_BUILTIN_EXCLUDES := $(notdir $(ZIPPYDIR)) _build Makefile $(notdir $(PATCHES_DIR))
ifdef BIN_NAME
  _BUILTIN_EXCLUDES += $(BIN_NAME)
endif
_ALL_EXCLUDES := $(_BUILTIN_EXCLUDES) $(APP_EXCLUDE)
_EXCLUDES_CSV := $(subst $(eval ) ,$(shell echo ','),$(_ALL_EXCLUDES))
_SOURCES_CSV  := $(subst $(eval ) ,$(shell echo ','),$(SOURCES))

# Every file bundled into the zipfs, so the app binary rebuilds when a *script*
# changes - not just a C source. Without this, a Tcl-only edit leaves the binary
# looking up-to-date (its prereqs are the interpreter, dep stamps, and build.tcl),
# so the change silently never makes it into the bundle. A touch here reruns only
# build.tcl's re-bundle/link step; the dep compiles stay gated by their stamps.
# (.git pruned so the default SOURCES=./ doesn't drag the whole history in.)
APP_SRC_FILES := $(shell find $(SOURCES) -type f -not -path '*/.git/*' 2>/dev/null)

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

# ==== Source patches ====
# Patches in $(PATCHES_DIR)/<tree>/*.patch apply to that tree (tcl, tk, tcllib,
# tdom, img, opus) with `patch -p1` in lexical order after extraction. They're
# prerequisites of the extract rule, so a changed patch forces a clean
# re-extract (rm -rf): patching over an existing tree leaves stale .o files
# whose struct layouts no longer match the patched headers.
patches-for    = $(sort $(wildcard $(PATCHES_DIR)/$(1)/*.patch))
# $(call apply-patches,<tree-dir>,<patch-list>)
apply-patches  = $(foreach p,$(2),patch -d $(1) -p1 < $(p) &&) true

TCL_PATCHES    := $(call patches-for,tcl)
TK_PATCHES     := $(call patches-for,tk)
TCLLIB_PATCHES := $(call patches-for,tcllib)
TDOM_PATCHES   := $(call patches-for,tdom)
IMG_PATCHES    := $(call patches-for,img)
OPUS_PATCHES   := $(call patches-for,opus)
MBEDTLS_PATCHES := $(call patches-for,mbedtls)

# ==== Download ====
# The only phase that touches the network. Everything here is content-addressed
# (sha256 per tarball, commit per git dep), so a populated DEPSDIR is all a
# build needs — see ZIPPY_OFFLINE below.

TAR_DEPS := TCL TK TDOM TCLLIB IMG OPUS
GIT_DEPS := MTLS MBEDTLS RTC LIBDC RTCMA OMEMO TCLWUFFS TKDND

# Pristine per-pin checkout for each git dep, kept apart from the tree the build
# uses. See git-dep below for why the two are separate.
$(foreach d,$(GIT_DEPS),$(eval $(d)_GIT := $$(DEPSDIR)/git/$$(notdir $$($(d)_SRC))))

DEPS_TARBALLS := $(foreach d,$(TAR_DEPS),$(DEPSDIR)/$($(d)_TAR))
DEPS_GIT      := $(foreach d,$(GIT_DEPS),$($(d)_GIT))

# ZIPPY_OFFLINE=1 replaces every network recipe with one that names the missing
# dep and exits, instead of failing later as a curl/git error.
# $(call offline-missing,<target>)
define offline-missing
echo "zippy: ZIPPY_OFFLINE=1, but this dep is not in DEPSDIR:" >&2; \
	echo "    $(1)" >&2; \
	echo "  DEPSDIR = $(DEPSDIR)" >&2; \
	echo "  Seed it with 'make -f zippy.mk download' (needs network), or" >&2; \
	echo "  unpack a bundle there ('make -f zippy.mk dep-bundle' builds one)." >&2; \
	exit 1
endef

ifeq ($(ZIPPY_OFFLINE),1)

define fetch-tar
$$(DEPSDIR)/$$($(1)_TAR):
	@$$(call offline-missing,$$@)
endef

define git-fetch
$$($(1)_GIT):
	@$$(call offline-missing,$$@)
endef

else

define fetch-tar
$$(DEPSDIR)/$$($(1)_TAR):
	mkdir -p $$(DEPSDIR)
	curl -L -o $$@ "$$($(1)_URL)"
	echo "$$($(1)_SHA256)  $$@" | $$(SHA256SUM) -c
endef

# Cloned into a .tmp beside the target and renamed only once the checkout and
# submodules are done, so the target directory never exists half-finished. Make
# has no prerequisites to compare a fetched dep against — it only asks whether
# the directory is there — so a run interrupted mid-clone would otherwise be
# taken as complete on the next run and built at the wrong commit.
define git-fetch
$$($(1)_GIT):
	mkdir -p $$(dir $$@)
	rm -rf $$@.tmp
	git clone $$($(1)_REPO) $$@.tmp
	cd $$@.tmp && git checkout $$($(1)_COMMIT) && git submodule update --init --recursive
	mv $$@.tmp $$@
endef

endif

# The tree the build compiles from: a copy of the pristine checkout with this
# project's patches applied. Patching a copy rather than the checkout itself
# keeps the fetched sources shareable (PATCHES_DIR is the consuming project's),
# lets a changed patch re-apply without refetching, and means a pre-staged
# checkout still gets patched instead of silently building unpatched.
#
# Costs a second copy on disk, or near-nothing where CP_TREE can share extents.
#
# touch because CP_TREE preserves the pristine checkout's timestamps: without it
# the copy stays older than a patch that was checked out later, so every run
# re-copies and re-patches. A fresh clone or worktree always lands that way.
#
# Same .tmp-then-rename as git-fetch: an interrupted copy, or a patch that fails
# partway, would otherwise leave a tree the next run accepts as finished.
define git-dep
$$($(1)_SRC): $$($(1)_GIT) $$($(1)_PATCHES)
	rm -rf $$@ $$@.tmp
	$$(CP_TREE) $$< $$@.tmp
	$$(call apply-patches,$$@.tmp,$$($(1)_PATCHES))
	mv $$@.tmp $$@
	touch $$@
endef

$(foreach d,$(TAR_DEPS),$(eval $(call fetch-tar,$(d))))
$(foreach d,$(GIT_DEPS),$(eval $(call git-fetch,$(d))))
$(foreach d,$(GIT_DEPS),$(eval $(call git-dep,$(d))))

# The pristine sources only; the patched build trees are made locally by git-dep.
download: $(DEPS_TARBALLS) $(DEPS_GIT)

# ==== Dep bundle ====
# One archive of every pinned source: unpack into DEPSDIR and build with
# ZIPPY_OFFLINE=1. Sources are platform-neutral, so one bundle serves every
# target sharing a DEPSDIR. Named by a digest of the pins, so a bump names a
# different bundle.
DEPS_PINS      := $(foreach d,$(TAR_DEPS),$(d)=$($(d)_SHA256)) \
                  $(foreach d,$(GIT_DEPS),$(d)=$($(d)_COMMIT))
DEPS_BUNDLE_ID := $(shell printf '%s\n' "$(DEPS_PINS)" | $(SHA256SUM) | cut -c1-12)
DEPS_BUNDLE_EXT  := $(shell command -v zstd >/dev/null 2>&1 && echo tar.zst || echo tar.gz)
DEPS_BUNDLE_COMP := $(if $(filter tar.zst,$(DEPS_BUNDLE_EXT)),--zstd,-z)
DEPS_BUNDLE    ?= $(BASEDIR)/zippy-deps-$(DEPS_BUNDLE_ID).$(DEPS_BUNDLE_EXT)

# .git is kept by default — some dep build systems read it for versioning.
# DEPS_BUNDLE_EXCLUDE_VCS=1 drops it, which is most of the size.
DEPS_BUNDLE_TAR_EXCLUDE := $(if $(DEPS_BUNDLE_EXCLUDE_VCS),--exclude=.git,)

.PHONY: dep-bundle unpack-deps flatpak-sources

dep-bundle: download
	tar $(DEPS_BUNDLE_COMP) $(DEPS_BUNDLE_TAR_EXCLUDE) -cf $(DEPS_BUNDLE) \
	    -C $(DEPSDIR) $(foreach d,$(TAR_DEPS),$($(d)_TAR)) git
	$(SHA256SUM) $(DEPS_BUNDLE)

unpack-deps:
	@[ -n "$(DEPS_BUNDLE_FILE)" ] || { \
	    echo "usage: make -f zippy.mk unpack-deps DEPS_BUNDLE_FILE=<bundle>" >&2; exit 1; }
	mkdir -p $(DEPSDIR)
	tar xf $(DEPS_BUNDLE_FILE) -C $(DEPSDIR)

# ==== Flatpak sources ====
# Emit the pin table as a flatpak `sources:` list, so the pins are not hand-synced
# into the manifest.
#
#   make -f zippy.mk flatpak-sources FLATPAK_DEPS_DIR=build/deps
#
# Paste the output into the module's `sources:` block (already indented for it).
# Each git dep lands at the pristine path git-dep copies from, so the build finds
# it staged and applies the project's patches itself.
FLATPAK_DEPS_DIR ?= _build/deps

flatpak-sources:
	@$(foreach d,$(TAR_DEPS), \
	    printf '      - type: file\n'                             ; \
	    printf '        url: %s\n'            '$($(d)_URL)'       ; \
	    printf '        sha256: %s\n'         '$($(d)_SHA256)'    ; \
	    printf '        dest: %s\n'           '$(FLATPAK_DEPS_DIR)' ; \
	    printf '        dest-filename: %s\n'  '$($(d)_TAR)'       ; )
	@$(foreach d,$(GIT_DEPS), \
	    printf '      - type: git\n'                              ; \
	    printf '        url: %s\n'            '$($(d)_REPO)'      ; \
	    printf '        commit: %s\n'         '$($(d)_COMMIT)'    ; \
	    printf '        dest: %s\n'           '$(FLATPAK_DEPS_DIR)/git/$(notdir $($(d)_SRC))' ; )

# ==== Extract ====
# Clean-extract (rm -rf) then apply patches; see "Source patches".

$(TCL_SRC): $(DEPSDIR)/$(TCL_TAR) $(TCL_PATCHES)
	rm -rf $@
	tar xzf $< -C $(DEPSDIR)
	$(call apply-patches,$@,$(TCL_PATCHES))
	touch $@

$(TK_SRC): $(DEPSDIR)/$(TK_TAR) $(TK_PATCHES)
	rm -rf $@
	tar xzf $< -C $(DEPSDIR)
	$(call apply-patches,$@,$(TK_PATCHES))
	touch $@

$(TCLLIB_SRC): $(DEPSDIR)/$(TCLLIB_TAR) $(TCLLIB_PATCHES)
	rm -rf $@
	tar xzf $< -C $(DEPSDIR)
	$(call apply-patches,$@,$(TCLLIB_PATCHES))
	touch $@

# The tarball is whatever "latest" was when it was fetched, so check that it
# unpacked the version TDOM_VER (and STATIC_PKGS) claims instead of building
# some other tree.
$(DEPSDIR)/.tdom_extracted: $(DEPSDIR)/$(TDOM_TAR) $(TDOM_PATCHES)
	rm -rf $(TDOM_SRC)
	tar xzf $< -C $(DEPSDIR)
	@[ -d $(TDOM_SRC) ] || { \
	    echo "zippy: $(TDOM_TAR) did not unpack $(notdir $(TDOM_SRC)):" >&2; \
	    echo "  got $$(ls -d $(DEPSDIR)/tdom-*/ 2>/dev/null | tr '\n' ' ')" >&2; \
	    echo "  Update TDOM_VER/TDOM_SHA256 to match upstream latest-src." >&2; \
	    exit 1; }
	$(call apply-patches,$(TDOM_SRC),$(TDOM_PATCHES))
	touch $@

$(IMG_SRC): $(DEPSDIR)/$(IMG_TAR) $(IMG_PATCHES)
	rm -rf $@
	tar xzf $< -C $(DEPSDIR)
	$(call apply-patches,$@,$(IMG_PATCHES))
	touch $@

$(OPUS_SRC): $(DEPSDIR)/$(OPUS_TAR) $(OPUS_PATCHES)
	rm -rf $@
	tar xzf $< -C $(DEPSDIR)
	$(call apply-patches,$@,$(OPUS_PATCHES))
	touch $@

# ==== Build Tcl/Tk ====
# Tk's windowing backend. Aqua builds from the same unix/ tree; without
# --enable-aqua Tk configures for X11 and the result needs XQuartz installed,
# which defeats the point. --disable-libcups only applies to the X11 print path.
ifdef MACOS
  TK_CONFIGURE_EXTRA := --enable-aqua
else
  TK_CONFIGURE_EXTRA := --disable-libcups
endif

# Native builds in unix/; the Windows cross-build (win/) lives in windows.mk,
# so these native recipes are guarded out when WIN is set.
ifndef CROSS_OVERLAY
$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/unix && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --enable-zipfs --disable-shared --with-system-libtommath=no && \
		sed $(SED_INPLACE_FLAG) 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries && \
		cp $(TCL_SRC)/pkgs/thread$(THREAD_VER)/lib/ttrace.tcl $(PREFIX)/lib/thread$(THREAD_VER)/

$(WISH): $(TK_SRC) $(TCLSH)
	cd $(TK_SRC)/unix && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --enable-zipfs --disable-shared $(TK_CONFIGURE_EXTRA) && \
		sed $(SED_INPLACE_FLAG) 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries

endif

# ==== Build extensions ====

# tdom (and the other compiled extensions below) build natively here; the
# Windows cross-build variants live in windows.mk, so guard the native recipe.
ifndef CROSS_OVERLAY
$(PREFIX)/.tdom_installed: $(DEPSDIR)/.tdom_extracted $(TCLSH)
	cd $(TDOM_SRC) && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@
endif

# `make install` also builds tcllib's optional critcl C accelerators, which
# can't cross-compile (it shells out for a target tclsh.exe). Windows installs
# the pure-Tcl modules only (install-tcl); see windows.mk.
ifndef CROSS_OVERLAY
$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install
	touch $@
endif

# Builds against zippy's shared mbedtls, not mtls's own submodule.
# MBEDTLS_USER_CONFIG_FILE must match what libmbedtls.a was compiled with,
# otherwise struct layouts diverge between mtls and libmbedtls.
ifndef CROSS_OVERLAY
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

ifndef CROSS_OVERLAY
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
		-DCMAKE_INSTALL_LIBDIR=lib \
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
$(PREFIX)/.rtc_installed: $(TCLSH) $(RTC_SRC) $(LIBDC_SRC) $(PREFIX)/.mbedtls_installed
	cmake -S $(RTC_SRC) -B $(BUILDDIR)/rtc $(CMAKE_TOOLCHAIN) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTC_BUNDLE_LIBDATACHANNEL=ON \
		-DRTC_LIBDATACHANNEL_SOURCE_DIR=$(LIBDC_SRC) \
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
$(PREFIX)/.rtcma_installed: $(TCLSH) $(RTCMA_SRC) $(OPUS_SRC) $(PREFIX)/.rtc_installed
	cmake -S $(RTCMA_SRC) -B $(BUILDDIR)/rtcma $(CMAKE_TOOLCHAIN) \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTCMA_BUNDLE_OPUS=ON \
		-DRTCMA_OPUS_SOURCE_DIR=$(OPUS_SRC) \
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
ifndef CROSS_OVERLAY
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

ifndef CROSS_OVERLAY
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
ifndef CROSS_OVERLAY
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
	sed $(SED_INPLACE_FLAG) 's|load $$dir/$$PKG_LIB_FILE|load {}|' $(PREFIX)/lib/tkdnd$(TKDND_VER)/tkdnd.tcl
	touch $@
endif

# ==== KITSH launcher ====

# Strip the kitsh launcher and stash debug info to a sidecar. Has to run here,
# before build.tcl appends the zipfs payload — strip rewrites ELF section
# layout, which would invalidate the absolute offsets in the appended ZIP
# central directory. The sidecar is later copied next to the shipped binary.
OBJCOPY  ?= objcopy
STRIP_BIN ?= strip
ifdef MACOS
# No objcopy in the Xcode tools, and Mach-O keeps debug info in the object files
# rather than the linked image, so dsymutil collects it into a .dSYM *bundle* —
# a directory, hence the cp -R in maybe_copy_debug.
define maybe_strip_kitsh
$(if $(filter 1,$(STRIP)),dsymutil $(1) -o $(1).debug && $(STRIP_BIN) -S $(1),true)
endef
else
define maybe_strip_kitsh
$(if $(filter 1,$(STRIP)),$(OBJCOPY) --only-keep-debug $(1) $(1).debug && $(STRIP_BIN) -s $(1),true)
endef
endif

$(KITSH_TCLSH): $(ZIPPYDIR)/kitsh.c $(TCLSH) $(DEP_STAMPS)
	mkdir -p $(@D)
	$(KITSH_LD) $(KITSH_CFLAGS) $(SIZE_CFLAGS) $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		$(KITSH_EXTRA_OBJS) \
		$(LINK_GROUP_START) $(KITSH_TCL_LIBS) $(LINK_GROUP_END) \
		$(KITSH_SYSLIBS) $(KITSH_EXTRA_LDFLAGS) $(SIZE_LDFLAGS)
	$(call maybe_strip_kitsh,$@)

$(KITSH_WISH): $(ZIPPYDIR)/kitsh.c $(WISH) $(DEP_STAMPS)
	mkdir -p $(@D)
	$(KITSH_LD) $(KITSH_CFLAGS) $(SIZE_CFLAGS) -DWITH_TK $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		$(KITSH_EXTRA_OBJS) \
		$(LINK_GROUP_START) $(KITSH_TK_LIBS) $(LINK_GROUP_END) \
		$(KITSH_SYSLIBS) $(KITSH_TK_SYSLIBS) $(KITSH_EXTRA_LDFLAGS) $(SIZE_LDFLAGS)
	$(call maybe_strip_kitsh,$@)

# ==== App ====

# Place the kitsh launcher's .debug sidecar next to the shipped binary so a
# crash address can be resolved with `addr2line -e <binary>.debug 0x...`.
define maybe_copy_debug
$(if $(filter 1,$(STRIP)),cp -R $(1).debug $(2).debug,true)
endef

# Native bundling runs $(TCLSH); a cross target can't (its interp is foreign), so
# the overlays (windows.mk / android.mk) provide their own HOST_TCLSH bundlers.
ifndef CROSS_OVERLAY

# build.tcl's argv in one place. CSVs hold commas, so they can't be $(call) args:
# name them here, vary only shell type. bundle_bare = no app sources ($(1)=type).
define bundle_app
$(TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ "$(_SOURCES_CSV)" "$(ENTRY_SCRIPT)" "$(_EXCLUDES_CSV)" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
endef
define bundle_bare
$(TCLSH) $(BUILD_TCL) $(1) $(BASEDIR) $@ "" "" "" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
endef

ifdef BIN_NAME
app: $(BASEDIR)/$(BIN_NAME)

$(BASEDIR)/$(BIN_NAME): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL) $(APP_SRC_FILES)
	$(bundle_app)
	$(call maybe_copy_debug,$(BASE_INTERP),$@)
endif

# ==== Standalone interpreters ====

wish: $(BASEDIR)/wish

$(BASEDIR)/wish: $(KITSH_WISH) $(DEP_STAMPS) $(BUILD_TCL)
	$(call bundle_bare,wish)
	$(call maybe_copy_debug,$(KITSH_WISH),$@)

tclsh: $(BASEDIR)/tclsh

$(BASEDIR)/tclsh: $(KITSH_TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	$(call bundle_bare,tclsh)
	$(call maybe_copy_debug,$(KITSH_TCLSH),$@)

endif

# ==== Static library ====
# Emit a static archive (instead of a runnable binary) that a foreign C/C++ host
# links: the SOURCES script tree lives in .rodata as a bare zip mounted via
# TclZipfs_MountBuffer, merged with every static Tcl/dep archive. Shared by the
# native build and the cross overlays - only the bare-zip bundling step (host
# tclsh) and the binutils (KIT_LD/KIT_OBJCOPY/KIT_AR) differ per target, so an
# overlay just overrides those vars and supplies its own $(SCRIPTS_ZIP) recipe.
#
# The project supplies the shim C source that drives the embedded interp:
#   LIB_SHIM_SRC  path to the shim .c (required for the `lib` target)
#   LIB_NAME      archive base name -> lib$(LIB_NAME).a  (default: BIN_NAME/app)
# The shim may `#include "static_pkgs.h"` (zippy is added to its include path)
# and call Zippy_RegisterStaticPackages(), and must reference the bundled zip as
# `_binary_scripts_zip_{start,end}` (the `ld -b binary` symbols for scripts.zip).
KIT_LD       ?= ld
KIT_OBJCOPY  ?= $(OBJCOPY)
KIT_AR       ?= $(AR)
SCRIPTS_ZIP  := $(BUILDDIR)/scripts.zip
SCRIPTS_OBJ  := $(BUILDDIR)/scripts.o
SHIM_OBJ     := $(BUILDDIR)/shim.o
LIB_NAME     ?= $(or $(BIN_NAME),app)
LIBOUT       := $(BASEDIR)/lib$(LIB_NAME).a

.PHONY: lib scripts-zip scripts-obj

scripts-zip: $(SCRIPTS_ZIP)

# Bare zipfs image of the SOURCES tree (ZIPPY_BASE_INTERP= => no prepended exe).
# A cross overlay can't run its foreign target interp, so the cross branch drives
# build.tcl with the overlay's HOST_TCLSH instead (shared by windows.mk and
# android.mk); native runs $(TCLSH) directly.
ifndef CROSS_OVERLAY
$(SCRIPTS_ZIP): $(DEP_STAMPS) $(BUILD_TCL) $(APP_SRC_FILES)
	mkdir -p $(@D)
	ZIPPY_BASE_INTERP= $(bundle_app)
else
$(SCRIPTS_ZIP): $(DEP_STAMPS) $(BUILD_TCL) $(APP_SRC_FILES)
	mkdir -p $(@D)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP= \
	$(HOST_TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ \
		"$(_SOURCES_CSV)" "$(ENTRY_SCRIPT)" "$(_EXCLUDES_CSV)" \
		$(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
endif

# Park the zip in .rodata (demand-paged, read-only). `ld -b binary` names its
# symbols after the *input filename*, so run it from $(@D) with a bare name to
# get _binary_scripts_zip_{start,end,size}. objcopy moves .data -> .rodata.
scripts-obj: $(SCRIPTS_OBJ)
$(SCRIPTS_OBJ): $(SCRIPTS_ZIP)
	cd $(@D) && $(KIT_LD) -r -b binary -o $(@F) $(<F)
	$(KIT_OBJCOPY) --rename-section .data=.rodata,alloc,load,readonly,data,contents $@

# The project's shim, compiled as C even under the g++ link driver via
# -xc/-xnone, with the same -DWITH_* flags as the launcher (so its static-package
# set matches) plus -I$(ZIPPYDIR) so it can include static_pkgs.h.
$(SHIM_OBJ): $(LIB_SHIM_SRC) $(ZIPPYDIR)/static_pkgs.h $(DEP_STAMPS)
	mkdir -p $(@D)
	$(KITSH_LD) $(KITSH_CFLAGS) -I$(ZIPPYDIR) $(KITSH_DEP_FLAGS) -c -o $@ \
	    $(KITSH_KITSH_LANG) $(LIB_SHIM_SRC) $(KITSH_KITSH_LANG_END)

# lib$(LIB_NAME).a = shim + scripts.o + every static Tcl/dep archive, merged into
# one archive with ar -M so GNU ld re-scans it without --start-group.
lib: $(LIBOUT)
$(LIBOUT): $(SHIM_OBJ) $(SCRIPTS_OBJ) $(DEP_STAMPS)
	@[ -n "$(strip $(LIB_SHIM_SRC))" ] || \
	    { echo "the 'lib' target needs LIB_SHIM_SRC set to the project's shim .c" >&2; exit 1; }
	rm -f $@
	{ echo 'create $@'; \
	  echo 'addmod $(SHIM_OBJ)'; \
	  echo 'addmod $(SCRIPTS_OBJ)'; \
	  $(foreach a,$(KITSH_TCL_LIBS),echo 'addlib $(a)';) \
	  echo 'save'; echo 'end'; } | $(KIT_AR) -M

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

# clean only removes $(BUILDDIR), which for a cross target leaves the shared
# $(DEPSDIR) behind. distclean drops the fetched sources too — including the
# older checkouts left by a *_COMMIT bump, since those are keyed by pin.
distclean: clean
	rm -rf $(DEPSDIR)

# ==== Windows cross-build ====
# Tcl/Tk (win/) + thread/sqlite3 TEA recipes and the kitsh link-var overrides.
# Included last so its KITSH_* assignments take precedence. No-op when native.
ifdef WIN
include $(ZIPPYDIR)/windows.mk
endif

# ==== Android cross-build ====
# Tcl + TEA recipes (unix/, --host=aarch64-linux-android) and the kitsh link-var
# overrides for a bionic ELF. Included last so its KITSH_* assignments win.
ifdef ANDROID
include $(ZIPPYDIR)/android.mk
endif
