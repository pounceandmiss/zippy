# zippy.mk — Build system for self-contained Tcl/Tk zipfs binaries
#
# User sets these before including:
#   SHELL_TYPE  := wish | tclsh    (default: wish)
#   DEPS        := tdom mtls tcllib img   (optional, any combination)
#   BIN_NAME    := myapp           (optional, omit for standalone interpreter)
#   APP_DIR     := .               (default: project root)
#   APP_EXCLUDE :=                 (optional, extra excludes: space-separated names)

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
TCL_BVER   := 9.0
TK_BVER    := 9.0
IMG_VER    := 2.1.1

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
IMG_URL    := https://sourceforge.net/projects/tkimg/files/tkimg/2.1/tkimg%20$(IMG_VER)/$(IMG_TAR)/download
MTLS_REPO  := https://github.com/chpock/tclmtls.git
MTLS_SRC   := $(DEPSDIR)/tclmtls

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
ifneq (,$(filter img,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.img_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/Img*) $(wildcard $(PREFIX)/lib/img*)
endif
ifneq (,$(filter mtls,$(DEPS)))
  DEP_STAMPS += $(PREFIX)/.mtls_installed
  DEP_LIBS += $(wildcard $(PREFIX)/lib/mtls*)
endif

# ==== Select base interpreter ====
ifeq ($(SHELL_TYPE),tclsh)
  BASE_INTERP := $(TCLSH)
else
  BASE_INTERP := $(WISH)
endif

# ==== Built-in excludes ====
_BUILTIN_EXCLUDES := $(notdir $(ZIPPYDIR)) _build Makefile
ifdef BIN_NAME
  _BUILTIN_EXCLUDES += $(BIN_NAME)
endif
_ALL_EXCLUDES := $(_BUILTIN_EXCLUDES) $(APP_EXCLUDE)
_EXCLUDES_CSV := $(subst $(eval ) ,$(shell echo ','),$(_ALL_EXCLUDES))

# ==== Default target ====
ifdef BIN_NAME
  .DEFAULT_GOAL := app
else
  .DEFAULT_GOAL := $(SHELL_TYPE)
endif

.PHONY: app wish tclsh download clean distclean

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

$(DEPSDIR)/$(IMG_TAR):
	mkdir -p $(DEPSDIR)
	curl -L -o $@ $(IMG_URL)
	echo "$(IMG_SHA256)  $@" | sha256sum -c

$(MTLS_SRC):
	git clone $(MTLS_REPO) $(MTLS_SRC)
	cd $(MTLS_SRC) && git submodule update --init --recursive

download: $(DEPSDIR)/$(TCL_TAR) $(DEPSDIR)/$(TK_TAR) $(DEPSDIR)/$(TDOM_TAR) $(DEPSDIR)/$(TCLLIB_TAR) $(DEPSDIR)/$(IMG_TAR) $(MTLS_SRC)

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

$(DEPSDIR)/.img_extracted: $(DEPSDIR)/$(IMG_TAR)
	tar xzf $< -C $(DEPSDIR)
	touch $@

# ==== Build Tcl/Tk ====

$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/unix && \
		./configure --prefix=$(PREFIX) --enable-zipfs --disable-shared && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install

$(WISH): $(TK_SRC) $(TCLSH)
	cd $(TK_SRC)/unix && \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --enable-zipfs --disable-shared && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install

# ==== Build extensions ====

$(PREFIX)/.tdom_installed: $(DEPSDIR)/.tdom_extracted $(TCLSH)
	cd $$(ls -d $(DEPSDIR)/tdom-*/) && \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@

$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install
	touch $@

# Img's install-man needs dtplite (from tcllib) on PATH,
# and dtplite's shebang expects "tclsh", but we only have "tclsh9.0"
$(PREFIX)/.img_installed: $(DEPSDIR)/.img_extracted $(WISH) $(PREFIX)/.tcllib_installed
	ln -sf tclsh$(TCL_BVER) $(PREFIX)/bin/tclsh
	cd $$(ls -d $(DEPSDIR)/Img-*/) && \
		PATH="$(PREFIX)/bin:$$PATH" \
		./configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib && \
		PATH="$(PREFIX)/bin:$$PATH" $(MAKE) -j$(NPROC) && \
		PATH="$(PREFIX)/bin:$$PATH" $(MAKE) install
	touch $@

$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH)
	mkdir -p $(MTLS_SRC)/build
	cd $(MTLS_SRC)/build && \
		../configure --prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install
	touch $@

# ==== App ====

ifdef BIN_NAME
app: $(BASEDIR)/$(BIN_NAME)

$(BASEDIR)/$(BIN_NAME): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL) $(APP_DIR)/main.tcl
	$(TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ $(APP_DIR) $(_EXCLUDES_CSV) $(DEP_LIBS)
endif

# ==== Standalone interpreters ====

wish: $(BASEDIR)/wish

$(BASEDIR)/wish: $(WISH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) wish $(BASEDIR) $@ "" "" $(DEP_LIBS)

tclsh: $(BASEDIR)/tclsh

$(BASEDIR)/tclsh: $(TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	$(TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" $(DEP_LIBS)

# ==== Clean ====

clean:
	rm -rf $(BUILDDIR)
ifdef BIN_NAME
	rm -f $(BASEDIR)/$(BIN_NAME)
endif
	rm -f $(BASEDIR)/wish $(BASEDIR)/tclsh

distclean: clean
