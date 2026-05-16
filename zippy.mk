# zippy.mk — Build system for self-contained Tcl/Tk zipfs binaries
#
# User sets these before including:
#   SHELL_TYPE  := wish | tclsh    (default: wish)
#   DEPS        := tdom mtls tcllib img   (optional, any combination)
#   BIN_NAME    := myapp           (optional, omit for standalone interpreter)
#   APP_DIR     := .               (default: project root)
#   APP_EXCLUDE :=                 (optional, extra excludes: space-separated names)
#
# Note: `img` requires Tk and is only valid with SHELL_TYPE=wish (default).

# ==== Paths ====
ZIPPYDIR     := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
BASEDIR      := $(CURDIR)
BUILDDIR     := $(BASEDIR)/_build
PREFIX       := $(BUILDDIR)/local
DEPSDIR      := $(BUILDDIR)/deps
BUILD_TCL    := $(ZIPPYDIR)/build.tcl

SHELL_TYPE ?= wish
APP_DIR    ?= .

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

# Rtc (libdatachannel-tcl). C++ Tcl 9 binding for libdatachannel, cloned
# from GitHub; built via cmake with RTC_BUNDLE_DEPS=ON so
# libdatachannel/mbedtls fold in as static archives alongside the binding.
RTC_VER    := 0.1.0
RTC_REPO   := https://github.com/pounceandmiss/libdatachannel-tcl.git
RTC_COMMIT := fc623e5272604788ef1309ff31adb9fa1a8053d1
RTC_SRC    := $(DEPSDIR)/libdatachannel-tcl

# Rtcma (rtc-ma). Audio-over-libdatachannel adapter (miniaudio + opus +
# jitter buffer + SDP) with its own Tcl 9 binding, cloned from GitHub.
# Built via cmake with RTCMA_BUNDLE_OPUS=ON only — libdatachannel and
# mbedtls are *not* rebuilt, they're consumed from rtc's vendor prefix,
# which is why `rtc` must also be in DEPS (enforced below).
RTCMA_VER    := 0.1.0
RTCMA_REPO   := https://github.com/pounceandmiss/rtc-ma.git
RTCMA_COMMIT := 0dfd8ce39f58311a5b6d98e3ba7bea4e1526dd29
RTCMA_SRC    := $(DEPSDIR)/rtc-ma

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

TCLSH := $(PREFIX)/bin/tclsh$(TCL_BVER)
WISH  := $(PREFIX)/bin/wish$(TK_BVER)

NPROC := $(shell nproc 2>/dev/null || echo 4)

# ==== Dependency mapping ====
DEP_STAMPS :=
DEP_LIBS =

ifneq (,$(filter tdom,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.tdom_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/tdom*)
endif
ifneq (,$(filter tcllib,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.tcllib_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/tcllib*)
endif
ifneq (,$(filter mtls,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.mtls_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/mtls*)
endif
ifneq (,$(filter img,$(DEPS)))
  ifeq ($(SHELL_TYPE),tclsh)
    $(error img requires Tk; cannot be used with SHELL_TYPE=tclsh)
  endif
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

# When both mtls and rtc are enabled, point tclmtls at libdatachannel-tcl's
# bundled mbedtls so we don't link two copies (different patch versions, both
# exporting the same mbedtls_* symbols → multiple-definition). In this mode
# tclmtls's archive references the mbedtls symbols instead of baking them in;
# the kitsh link already includes $(RTC_BUILD)/vendor/lib/*.a.
#
# Also propagate the same MBEDTLS_USER_CONFIG_FILE to tclmtls's compile.
# Without it, tclmtls's backend-mbedtls.c sees mbedtls headers with
# MBEDTLS_SSL_DTLS_SRTP undefined while libmbedtls.a was built with it set —
# mbedtls_ssl_config/_context struct layouts diverge and f_rng lands at a
# different offset for caller vs callee, NULL-deref'ing in client_hello.
#
# rtcma is irrelevant here: its build consumes libdatachannel/mbedtls from
# rtc's vendor, it doesn't produce its own.
MTLS_EXTRA_CONFIG :=
MTLS_EXTRA_DEPS   :=
ifneq (,$(filter mtls,$(DEPS)))
  ifneq (,$(filter rtc,$(DEPS)))
    MTLS_EXTRA_CONFIG := --with-mbedtls=$(BUILDDIR)/rtc/vendor \
        CPPFLAGS='-DMBEDTLS_USER_CONFIG_FILE=\"$(RTC_SRC)/cmake/mbedtls-user-config.h\"'
    MTLS_EXTRA_DEPS   := $(PREFIX)/.rtc_installed
  endif
endif

# ==== Tcl/Tk bundled packages ====
# Exclude itcl/tdbc family (not zippy deps) and internal dirs
_TCL_PKG_EXCLUDE = pkgconfig tcl9 tk$(TK_BVER) \
    itcl$(ITCL_VER) \
    tdbc$(TDBC_VER) tdbcmysql$(TDBC_VER) tdbcodbc$(TDBC_VER) tdbcpostgres$(TDBC_VER)
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
  KITSH_DEP_FLAGS += -DWITH_IMG
  KITSH_DEP_LIBS  += $(wildcard $(PREFIX)/lib/Img$(IMG_VER)/libtcl9*.a)
endif

# Linker driver — gcc by default. Rtc / rtcma (C++) flip us to g++ +
# static libstdc++; -xc keeps kitsh.c itself compiled as C so the existing
# C-linkage `extern int <Pkg>_Init(Tcl_Interp *)` decls still match.
KITSH_LD              := gcc
KITSH_KITSH_LANG      :=
KITSH_KITSH_LANG_END  :=
KITSH_EXTRA_LDFLAGS   :=

# rtc owns libdatachannel + mbedtls (both bundled in $(RTC_BUILD)/vendor).
# rtcma reuses those — see its recipe below for the
# RTCMA_BUNDLE_OPUS=ON / CMAKE_PREFIX_PATH=$(RTC_BUILD)/vendor invocation.
# So at kitsh-link time:
#   - rtc contributes librtc_tcl.a + the full vendor archive set
#     (libdatachannel + juice + srtp2 + usrsctp + mbed{tls,crypto,x509}).
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

KITSH_TCLSH := $(BUILDDIR)/kitsh_tclsh
KITSH_WISH  := $(BUILDDIR)/kitsh_wish

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

$(RTC_SRC):
	git clone $(RTC_REPO) $(RTC_SRC)
	cd $(RTC_SRC) && git checkout $(RTC_COMMIT) && git submodule update --init --recursive

$(RTCMA_SRC):
	git clone $(RTCMA_REPO) $(RTCMA_SRC)
	cd $(RTCMA_SRC) && git checkout $(RTCMA_COMMIT) && git submodule update --init --recursive

$(DEPSDIR)/$(IMG_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ "$(IMG_URL)"
	echo "$(IMG_SHA256)  $@" | sha256sum -c

download: $(DEPSDIR)/$(TCL_TAR) $(DEPSDIR)/$(TK_TAR) $(DEPSDIR)/$(TDOM_TAR) $(DEPSDIR)/$(TCLLIB_TAR) $(MTLS_SRC) $(RTC_SRC) $(RTCMA_SRC) $(DEPSDIR)/$(IMG_TAR)

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

$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/unix && \
		./configure --prefix=$(PREFIX) --enable-zipfs --disable-shared --with-system-libtommath=no && \
		sed -i 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries && \
		cp $(TCL_SRC)/pkgs/thread$(THREAD_VER)/lib/ttrace.tcl $(PREFIX)/lib/thread$(THREAD_VER)/

$(WISH): $(TK_SRC) $(TCLSH)
	cd $(TK_SRC)/unix && \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --enable-zipfs --disable-shared --disable-libcups && \
		sed -i 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install && \
		$(MAKE) install-libraries

# ==== Build extensions ====

$(PREFIX)/.tdom_installed: $(DEPSDIR)/.tdom_extracted $(TCLSH)
	cd $$(ls -d $(DEPSDIR)/tdom-*/) && \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@

$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install
	touch $@

$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH) $(MTLS_EXTRA_DEPS)
	mkdir -p $(MTLS_SRC)/build
	cd $(MTLS_SRC)/build && \
		../configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared $(MTLS_EXTRA_CONFIG) && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@

# Img: configure with --disable-shared builds .a files but its `make install`
# target only assembles the umbrella pkgIndex.tcl in shared builds. We install
# manually: copy the .a files into Img$(IMG_VER)/ and emit a pkgIndex.tcl that
# resolves every sub-package via `load {} <Prefix>` — wired to the
# Tcl_StaticPackage entries in kitsh.c.
IMG_PKGINDEX_TCL := $(ZIPPYDIR)/img_pkgindex.tcl

$(PREFIX)/.img_installed: $(IMG_SRC) $(WISH) $(IMG_PKGINDEX_TCL)
	mkdir -p $(IMG_SRC)/build
	cd $(IMG_SRC)/build && \
		../configure --prefix=$(PREFIX) \
			--with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib \
			--disable-shared && \
		$(MAKE) -j$(NPROC)
	rm -rf $(PREFIX)/lib/Img$(IMG_VER)
	mkdir -p $(PREFIX)/lib/Img$(IMG_VER)
	find $(IMG_SRC)/build -name 'libtcl9*.a' -exec cp {} $(PREFIX)/lib/Img$(IMG_VER)/ \;
	$(TCLSH) $(IMG_PKGINDEX_TCL) \
		$(PREFIX)/lib/Img$(IMG_VER)/pkgIndex.tcl \
		$(IMG_VER) $(IMG_ZLIB_VER) $(IMG_PNG_VER) $(IMG_JPEG_VER) $(IMG_TIFF_VER)
	touch $@

# Rtc: out-of-tree cmake build against a local libdatachannel-tcl source dir.
# BUNDLE_DEPS rebuilds mbedtls/libdatachannel into static archives inside the
# build tree's vendor/lib; the tcl/ subdir's rtc_tcl_static target emits
# librtc_tcl.a (the Tcl 9 extension archive whose Rtc_Init we wire into
# kitsh.c via Tcl_StaticPackage).
$(PREFIX)/.rtc_installed: $(TCLSH) $(RTC_SRC)
	cmake -S $(RTC_SRC) -B $(BUILDDIR)/rtc \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTC_BUNDLE_DEPS=ON \
		-DCMAKE_PREFIX_PATH=$(PREFIX)
	cmake --build $(BUILDDIR)/rtc -j$(NPROC)
	mkdir -p $(PREFIX)
	touch $@

# Rtcma: out-of-tree cmake build. RTCMA_BUNDLE_OPUS=ON builds opus from
# source into the build tree's vendor/ prefix; libdatachannel and mbedtls
# are *not* rebuilt — rtcma's find_package(LibDataChannel) resolves
# against rtc's vendor install (see CMAKE_PREFIX_PATH). RTCMA_BUILD_TCL=ON
# pulls in tcl/CMakeLists.txt, which emits librtcma_tcl.a (the Tcl 9
# extension archive whose Rtcma_Init we wire into kitsh.c via
# Tcl_StaticPackage) alongside librtcma.a (the audio adapter library
# itself).
#
# The order-only dependency on .rtc_installed makes sure rtc's vendor
# install exists before rtcma's configure runs; the DEP_STAMPS block
# above already errors out at make-parse time if rtc isn't in DEPS.
$(PREFIX)/.rtcma_installed: $(TCLSH) $(RTCMA_SRC) $(PREFIX)/.rtc_installed
	cmake -S $(RTCMA_SRC) -B $(BUILDDIR)/rtcma \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
		-DRTCMA_BUNDLE_OPUS=ON \
		-DRTCMA_BUILD_TCL=ON \
		-DLibDataChannel_DIR=$(BUILDDIR)/rtc/vendor/lib/cmake/LibDataChannel \
		-DMbedTLS_DIR=$(BUILDDIR)/rtc/vendor/lib/cmake/MbedTLS \
		-DCMAKE_PREFIX_PATH='$(PREFIX);$(BUILDDIR)/rtc/vendor'
	cmake --build $(BUILDDIR)/rtcma -j$(NPROC)
	mkdir -p $(PREFIX)
	touch $@

# ==== KITSH launcher ====

$(KITSH_TCLSH): $(ZIPPYDIR)/kitsh.c $(TCLSH) $(DEP_STAMPS)
	$(KITSH_LD) $(KITSH_CFLAGS) $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		-Wl,--start-group $(KITSH_TCL_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS) $(KITSH_EXTRA_LDFLAGS)

$(KITSH_WISH): $(ZIPPYDIR)/kitsh.c $(WISH) $(DEP_STAMPS)
	$(KITSH_LD) $(KITSH_CFLAGS) -DWITH_TK $(KITSH_DEP_FLAGS) -o $@ $(KITSH_KITSH_LANG) $< $(KITSH_KITSH_LANG_END) \
		-Wl,--start-group $(KITSH_TK_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS) $(KITSH_TK_SYSLIBS) $(KITSH_EXTRA_LDFLAGS)

# ==== App ====

ifdef BIN_NAME
app: $(BASEDIR)/$(BIN_NAME)

$(BASEDIR)/$(BIN_NAME): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL) $(APP_DIR)/main.tcl
	$(TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ $(APP_DIR) $(_EXCLUDES_CSV) $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
endif

# ==== Standalone interpreters ====

wish: $(BASEDIR)/wish

$(BASEDIR)/wish: $(KITSH_WISH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) wish $(BASEDIR) $@ "" "" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)

tclsh: $(BASEDIR)/tclsh

$(BASEDIR)/tclsh: $(KITSH_TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)

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
	rm -f $(BASEDIR)/$(BIN_NAME)
endif
	rm -f $(BASEDIR)/wish $(BASEDIR)/tclsh

distclean: clean
