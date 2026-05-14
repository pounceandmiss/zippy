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

$(DEPSDIR)/$(IMG_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ "$(IMG_URL)"
	echo "$(IMG_SHA256)  $@" | sha256sum -c

download: $(DEPSDIR)/$(TCL_TAR) $(DEPSDIR)/$(TK_TAR) $(DEPSDIR)/$(TDOM_TAR) $(DEPSDIR)/$(TCLLIB_TAR) $(MTLS_SRC) $(DEPSDIR)/$(IMG_TAR)

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

$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH)
	mkdir -p $(MTLS_SRC)/build
	cd $(MTLS_SRC)/build && \
		../configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
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

# ==== KITSH launcher ====

$(KITSH_TCLSH): $(ZIPPYDIR)/kitsh.c $(TCLSH) $(DEP_STAMPS)
	gcc $(KITSH_CFLAGS) $(KITSH_DEP_FLAGS) -o $@ $< \
		-Wl,--start-group $(KITSH_TCL_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS)

$(KITSH_WISH): $(ZIPPYDIR)/kitsh.c $(WISH) $(DEP_STAMPS)
	gcc $(KITSH_CFLAGS) -DWITH_TK $(KITSH_DEP_FLAGS) -o $@ $< \
		-Wl,--start-group $(KITSH_TK_LIBS) -Wl,--end-group \
		$(KITSH_SYSLIBS) $(KITSH_TK_SYSLIBS)

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
