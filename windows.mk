# windows.mk - MinGW-w64 cross-build overlay, included by zippy.mk when
# TARGET_OS=windows (WIN=1). Supplies the recipes that differ from the native
# build: Tcl/Tk built in win/ rather than unix/, and the thread/sqlite3 TEA
# packages cross-built as standalone static archives, plus the kitsh link-var
# overrides for a static PE. The mbedtls/rtc/rtcma cmake builds reuse zippy.mk's
# shared recipes through the $(CMAKE_TOOLCHAIN) seam.
#
# Deliverable: $(KITSH_WISH) = $(BUILDDIR)/kitsh_wish.exe, a static PE32+
# launcher with Tk + rtc/rtcma + sqlite3 + thread linked in.
# Build with:  make TARGET_OS=windows win-wish

# Version strings with dots stripped: the win/ build and TEA name archives
# without separators (libtcl90.a, libtcl9thread304.a, libtcl9sqlite3510.a).
TCL_FLAT     := $(subst .,,$(TCL_BVER))
TK_FLAT      := $(subst .,,$(TK_BVER))
THREAD_FLAT  := $(subst .,,$(THREAD_VER))
SQLITE_FLAT  := $(subst .,,$(SQLITE3_VER))
TKDND_FLAT   := $(subst .,,$(TKDND_VER))

# Bundled-package source dirs (shared Tcl source tree) and the isolated copies
# they cross-build in. The native build TEA-builds thread/sqlite/zlib in-tree,
# so cross-building there too would cross-link ELF and PE objects and re-touch
# the archive the kitsh link reads. Build in private copies under $(BUILDDIR).
THREAD_PKG     := $(TCL_SRC)/pkgs/thread$(THREAD_VER)
SQLITE_PKG     := $(TCL_SRC)/pkgs/sqlite$(SQLITE3_VER)
WIN_ZLIB_SRC   := $(TCL_SRC)/compat/zlib
THREAD_BUILD   := $(BUILDDIR)/thread
SQLITE_BUILD   := $(BUILDDIR)/sqlite
WIN_ZLIB_BUILD := $(BUILDDIR)/zlib
THREAD_WIN_LIB := $(THREAD_BUILD)/libtcl9thread$(THREAD_FLAT).a
SQLITE_WIN_LIB := $(SQLITE_BUILD)/libtcl9sqlite$(SQLITE_FLAT).a
WIN_LIBZ       := $(PREFIX)/lib/libz.a

# ==== Tcl / Tk (win/ cross-build) ====
# $(TCLSH)/$(WISH) are the stamp files from zippy.mk; the host can't run the
# produced .exe. make install puts tclConfig.sh/tkConfig.sh, the static archives
# and the headers in $(PREFIX), where the deps and the kitsh link read them.

$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/win && \
		CFLAGS="$(SIZE_CFLAGS)" \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --enable-zipfs --disable-shared \
			--with-system-libtommath=no && \
		sed $(SED_INPLACE_FLAG) 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install TCL_EXE=$(HOST_TCLSH) && \
		$(MAKE) install-libraries TCL_EXE=$(HOST_TCLSH)
	touch $@

$(WISH): $(TK_SRC) $(TCLSH)
	cd $(TK_SRC)/win && \
		CFLAGS="$(SIZE_CFLAGS)" \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib \
			--enable-zipfs --disable-shared && \
		sed $(SED_INPLACE_FLAG) 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) && \
		$(MAKE) install TCL_EXE=$(HOST_TCLSH) && \
		$(MAKE) install-libraries TCL_EXE=$(HOST_TCLSH)
	touch $@

# ==== thread / sqlite3 (TEA cross-build) ====
# Natively Tcl's make install provides these; the win/ build doesn't, so
# cross-build each via its TEA configure against the win/ tclConfig.sh, in an
# isolated copy under $(BUILDDIR). The rm clears native config/objects so
# configure regenerates them for mingw. Feeds KITSH_BUNDLED_LIBS.

$(THREAD_WIN_LIB): $(TCLSH)
	rm -rf $(THREAD_BUILD)
	mkdir -p $(THREAD_BUILD)
	cp -a $(THREAD_PKG)/. $(THREAD_BUILD)/
	rm -f $(THREAD_BUILD)/*.o $(THREAD_BUILD)/*.a \
		$(THREAD_BUILD)/config.status $(THREAD_BUILD)/config.cache $(THREAD_BUILD)/Makefile
	cd $(THREAD_BUILD) && \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--with-tcl=$(TCL_SRC)/win --prefix=$(PREFIX) \
			--disable-shared --enable-threads && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH)

$(SQLITE_WIN_LIB): $(TCLSH)
	rm -rf $(SQLITE_BUILD)
	mkdir -p $(SQLITE_BUILD)
	cp -a $(SQLITE_PKG)/. $(SQLITE_BUILD)/
	rm -f $(SQLITE_BUILD)/*.o $(SQLITE_BUILD)/*.a \
		$(SQLITE_BUILD)/config.status $(SQLITE_BUILD)/config.cache $(SQLITE_BUILD)/Makefile
	cd $(SQLITE_BUILD) && \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--with-tcl=$(TCL_SRC)/win --prefix=$(PREFIX) \
			--disable-shared && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH)

# ==== zlib ====
# Tcl's bundled zlib symbols aren't exported, so the static link needs a
# standalone libz.a. Cross-build it from an isolated copy of Tcl's compat copy
# (the native build TEA-builds that dir in-tree), then install into $(PREFIX).
$(WIN_LIBZ): $(TCL_SRC)
	rm -rf $(WIN_ZLIB_BUILD)
	mkdir -p $(WIN_ZLIB_BUILD)
	cp -a $(WIN_ZLIB_SRC)/. $(WIN_ZLIB_BUILD)/
	rm -f $(WIN_ZLIB_BUILD)/*.o $(WIN_ZLIB_BUILD)/*.a
	cd $(WIN_ZLIB_BUILD) && \
		CC=$(CROSS)-gcc AR=$(CROSS)-ar RANLIB=$(CROSS)-ranlib \
		./configure --static && \
		$(MAKE) -j$(NPROC) libz.a
	mkdir -p $(PREFIX)/lib
	cp $(WIN_ZLIB_BUILD)/libz.a $(WIN_LIBZ)

# ==== Compiled extensions (TEA cross-builds) ====
# Each builds under $(BUILDDIR) against the win/ tclConfig.sh and installs into
# $(PREFIX) with the same layout the native recipes use, so the kitsh link's
# KITSH_DEP_LIBS and the bundling's DEP_LIBS/TCL_PKG_LIBS pick them up unchanged.
# mtls/img/tkdnd build out-of-tree from the shared $(DEPSDIR) source (their
# native recipes are out-of-tree too, so that source tree stays object-free).
# tdom/omemo/tclwuffs build in-tree, so their native build drops objects into
# the shared source; these recipes work from a private copy/extraction under
# $(BUILDDIR) so a shared DEPSDIR never cross-links ELF and PE objects.

# Pure-Tcl modules only (install-tcl); skips the critcl C accelerators.
$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install-tcl TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# Extract a pristine source under $(BUILDDIR) rather than building out-of-tree
# against the shared $(DEPSDIR)/tdom-*/: the native build configures+compiles
# there in-tree, and tdom's TEA Makefile sets VPATH=srcdir, so a cross-build
# would resolve the leftover native ELF .o through VPATH and link them into the
# PE archive. Re-extracting the tarball is cheap and gives a clean tree.
$(PREFIX)/.tdom_installed: $(DEPSDIR)/$(TDOM_TAR) $(TCLSH)
	rm -rf $(BUILDDIR)/tdom-src $(BUILDDIR)/tdom
	mkdir -p $(BUILDDIR)/tdom-src $(BUILDDIR)/tdom
	tar xzf $(DEPSDIR)/$(TDOM_TAR) -C $(BUILDDIR)/tdom-src --strip-components=1
	cd $(BUILDDIR)/tdom && \
		CFLAGS="$(SIZE_CFLAGS)" \
		$(BUILDDIR)/tdom-src/configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(TCL_SRC)/win --disable-shared && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# Links against the cross-built Windows mbedtls in $(PREFIX) (same user-config
# as libmbedtls.a, so struct layouts match).
$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH) $(PREFIX)/.mbedtls_installed
	mkdir -p $(BUILDDIR)/mtls
	cd $(BUILDDIR)/mtls && \
		CFLAGS="$(SIZE_CFLAGS)" \
		$(MTLS_SRC)/configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(TCL_SRC)/win --disable-shared \
			--with-mbedtls=$(PREFIX) \
			CPPFLAGS='-DMBEDTLS_USER_CONFIG_FILE=\"$(MBEDTLS_USER_CFG)\"' && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# picomemo's Makefile builds in-tree (objects in build/, archive at top), so
# cross-compile in an isolated copy ($(OMEMO_BUILD)) rather than the shared
# $(OMEMO_SRC): a native build there leaves ELF objects in build/ that the
# Makefile would treat as up-to-date and archive into the PE build. cp -a brings
# the picomemo submodule along; the rm drops any native build/ + archives.
$(PREFIX)/.omemo_installed: $(TCLSH) $(OMEMO_SRC) $(PREFIX)/.mbedtls_installed
	rm -rf $(OMEMO_BUILD)
	mkdir -p $(OMEMO_BUILD)
	cp -a $(OMEMO_SRC)/. $(OMEMO_BUILD)/
	rm -rf $(OMEMO_BUILD)/build $(OMEMO_BUILD)/libtcl9omemo*.a $(OMEMO_BUILD)/libtcl9omemo*.so
	$(MAKE) -C $(OMEMO_BUILD) libtcl9omemo$(OMEMO_VER).a \
		CC=$(CROSS)-gcc AR=$(CROSS)-ar RANLIB=$(CROSS)-ranlib \
		TCL_PREFIX=$(PREFIX) MBED_PREFIX=$(PREFIX) CFLAGS="$(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@

# tclwuffs/tkwuffs via their Makefile (in-tree, objects in build/), cross-built
# in an isolated copy ($(TCLWUFFS_BUILD)) against the Windows
# tclConfig.sh/tkConfig.sh in $(PREFIX), for the same reason as omemo above.
# cp -a carries the vendored wuffs/stb sources; the rm drops native build/ +
# archives. TCLWUFFS_MAKE_TARGETS/TCLWUFFS_EXTRA_DEPS come from zippy.mk
# (tkwuffs adds Tk + $(WISH)).
$(PREFIX)/.tclwuffs_installed: $(TCLSH) $(TCLWUFFS_SRC) $(TCLWUFFS_EXTRA_DEPS)
	rm -rf $(TCLWUFFS_BUILD)
	mkdir -p $(TCLWUFFS_BUILD)
	cp -a $(TCLWUFFS_SRC)/. $(TCLWUFFS_BUILD)/
	rm -rf $(TCLWUFFS_BUILD)/build $(TCLWUFFS_BUILD)/libt*wuffs*.a $(TCLWUFFS_BUILD)/libt*wuffs*.so
	$(MAKE) -C $(TCLWUFFS_BUILD) $(TCLWUFFS_MAKE_TARGETS) \
		CC=$(CROSS)-gcc AR=$(CROSS)-ar RANLIB=$(CROSS)-ranlib \
		TCLCONFIG=$(PREFIX)/lib/tclConfig.sh \
		TKCONFIG=$(PREFIX)/lib/tkConfig.sh \
		CFLAGS="$(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@

# Img bundles its own libpng/libjpeg/libtiff/zlib (cross-built by its TEA build).
# img_pkgindex.tcl runs on the host tclsh. The winshim dir forwards capitalized
# Windows headers (e.g. tiff.c's <Windows.h>) to mingw's lowercase ones; the
# cross build is case-sensitive. C_INCLUDE_PATH propagates it to every sub-build.
$(PREFIX)/.img_installed: $(IMG_SRC) $(WISH) $(IMG_PKGINDEX_TCL)
	mkdir -p $(BUILDDIR)/winshim
	echo '#include <windows.h>' > $(BUILDDIR)/winshim/Windows.h
	mkdir -p $(BUILDDIR)/img
	cd $(BUILDDIR)/img && \
		C_INCLUDE_PATH=$(BUILDDIR)/winshim \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		$(IMG_SRC)/configure --host=$(CROSS) --build=$(CROSS_BUILD) --prefix=$(PREFIX) \
			--with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib --disable-shared && \
		C_INCLUDE_PATH=$(BUILDDIR)/winshim $(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH)
	rm -rf $(PREFIX)/lib/Img$(IMG_VER)
	mkdir -p $(PREFIX)/lib/Img$(IMG_VER)
	find $(BUILDDIR)/img -name 'libtcl9*.a' -exec cp {} $(PREFIX)/lib/Img$(IMG_VER)/ \;
	$(HOST_TCLSH) $(IMG_PKGINDEX_TCL) \
		$(PREFIX)/lib/Img$(IMG_VER)/pkgIndex.tcl \
		$(IMG_VER) $(IMG_ZLIB_VER) $(IMG_PNG_VER) $(IMG_JPEG_VER) $(IMG_TIFF_VER) \
		"$(IMG_BASE_PKGS)" "$(IMG_FORMATS)"
	touch $@

# tkdnd: --host selects its win32/OLE backend instead of the X11 one.
$(PREFIX)/.tkdnd_installed: $(TKDND_SRC) $(WISH)
	mkdir -p $(BUILDDIR)/tkdnd
	cd $(BUILDDIR)/tkdnd && \
		CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		$(TKDND_SRC)/configure --host=$(CROSS) --build=$(CROSS_BUILD) --prefix=$(PREFIX) \
			--with-tcl=$(PREFIX)/lib --with-tk=$(PREFIX)/lib --disable-shared && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH)
	rm -rf $(PREFIX)/lib/tkdnd$(TKDND_VER)
	mkdir -p $(PREFIX)/lib/tkdnd$(TKDND_VER)
	cp $(BUILDDIR)/tkdnd/libtcl9tkdnd$(TKDND_FLAT).a $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	cp $(TKDND_SRC)/library/*.tcl $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	cp $(BUILDDIR)/tkdnd/pkgIndex.tcl $(PREFIX)/lib/tkdnd$(TKDND_VER)/
	sed $(SED_INPLACE_FLAG) 's|load $$dir/$$PKG_LIB_FILE|load {}|' $(PREFIX)/lib/tkdnd$(TKDND_VER)/tkdnd.tcl
	touch $@

# ==== kitsh link overrides ====
# rtc/rtcma/mbedtls archives already resolve through KITSH_DEP_LIBS (they derive
# from $(BUILDDIR)/$(PREFIX), retargeted by TARGET_OS). Override only what
# differs on Windows: the Tcl/Tk core archive names, the thread/sqlite paths,
# libz, the link driver, and the syslibs.

# Build the package archives + libz before the kitsh link; they aren't pulled in
# by $(WISH). Adds prerequisites without redefining the recipe.
$(KITSH_WISH) $(KITSH_TCLSH): $(THREAD_WIN_LIB) $(SQLITE_WIN_LIB) $(WIN_LIBZ)

# C++ link driver, libstdc++ and the -xc wrapper only when a C++ dep (rtc/rtcma)
# is linked, matching zippy.mk's native gating; a pure-C build links with gcc.
# -xc keeps kitsh.c compiled as C under g++ so the extern <Pkg>_Init decls retain
# C linkage.
ifneq (,$(filter rtc rtcma,$(DEPS)))
  KITSH_LD := $(CROSS)-g++
  KITSH_KITSH_LANG     := -xc
  KITSH_KITSH_LANG_END := -xnone
  KITSH_WIN_CXXLIB := -lstdc++
else
  KITSH_LD := $(CROSS)-gcc
endif
# -municode at compile defines UNICODE, exposing the wide-argv Tk_Main/Tcl_Main
# that match kitsh.c's wmain; STATIC_BUILD drops dllimport; RTC_STATIC for
# libdatachannel. Do NOT define USE_TCL_STUBS/USE_TK_STUBS: tcl.h gates on
# #ifdef (not the value), so even =0 routes the bootstrap (TclZipfs_AppHook,
# Tcl_FindExecutable, Tcl_MainEx) through TclStubCall, which dlopens tcl90.dll
# and aborts in a static build. Leaving them undefined links the core directly.
KITSH_CFLAGS := -I$(PREFIX)/include -I$(TCL_SRC)/win -municode \
                -DSTATIC_BUILD -DRTC_STATIC

KITSH_BUNDLED_LIBS := $(THREAD_WIN_LIB) $(SQLITE_WIN_LIB)

KITSH_TCL_LIBS = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl$(TCL_FLAT).a $(PREFIX)/lib/libtclstub.a $(WIN_LIBZ)
KITSH_TK_LIBS  = $(KITSH_BUNDLED_LIBS) $(KITSH_DEP_LIBS) \
    $(PREFIX)/lib/libtcl9tk$(TK_FLAT).a $(PREFIX)/lib/libtcl$(TCL_FLAT).a \
    $(PREFIX)/lib/libtkstub.a $(PREFIX)/lib/libtclstub.a $(WIN_LIBZ)

# Windows GUI/system import libs replace the Unix X11/pthread/dl set. -static
# links libstdc++/libwinpthread statically; -municode selects the wmain entry.
# KITSH_WIN_CXXLIB is -lstdc++ only when a C++ dep is linked.
# KITSH_TK_SYSLIBS folds in here (gdi32/comdlg32/... are syslibs).
KITSH_SYSLIBS := -static \
    -lws2_32 -lnetapi32 -luserenv -lbcrypt -lole32 -loleaut32 -luuid \
    -lwinmm -lgdi32 -lcomdlg32 -limm32 -lcomctl32 -lshell32 -luxtheme \
    -ldwmapi -lwinspool -liphlpapi -lcrypt32 -lsecur32 -lncrypt -lwinhttp \
    -ldnsapi $(KITSH_WIN_CXXLIB) -lwinpthread -lssp -lm

# Mark the wish launcher as a GUI-subsystem PE
KITSH_TK_SYSLIBS    := -Wl,--subsystem,windows
KITSH_EXTRA_LDFLAGS := -municode

# ==== Executable icon ====
# WIN_ICON=/path/to/app.ico links an icon into the launcher. windres
# turns a generated .rc referencing the .ico into a COFF object; the
# lowest-id ICON resource (1 here) becomes the application icon. It
# has to go into the kitsh link, not the bundling step: build.tcl only
# appends the zipfs payload, it never relinks the PE.
WINDRES ?= $(CROSS)-windres
ifdef WIN_ICON
KITSH_ICON_RC  := $(BUILDDIR)/kitsh_icon.rc
KITSH_ICON_OBJ := $(BUILDDIR)/kitsh_icon.o
KITSH_EXTRA_OBJS += $(KITSH_ICON_OBJ)

$(KITSH_ICON_OBJ): $(WIN_ICON)
	mkdir -p $(@D)
	printf '1 ICON "%s"\n' '$(abspath $(WIN_ICON))' > $(KITSH_ICON_RC)
	$(WINDRES) -O coff -o $@ $(KITSH_ICON_RC)

$(KITSH_WISH) $(KITSH_TCLSH): $(KITSH_ICON_OBJ)
endif

# ==== Bundle the script library into a runnable exe ====
# The launcher alone can't boot: kitsh.c's TclZipfs_AppHook expects the Tcl/Tk
# script library appended as a zipfs. build.tcl does that append (zipfs mkimg,
# which only manipulates files), so a host tclsh can bundle for a Windows
# target. ZIPPY_BUILDDIR/ZIPPY_EXE_EXT point build.tcl at the _build-win .exe
# launcher. HOST_TCLSH must be a tclsh of the same 9.0 line as the bundled lib.
HOST_TCLSH ?= tclsh$(TCL_BVER)

# Output lands in the repo root (./wish.exe, ./tclsh.exe), matching the native
# wish/tclsh targets, which drop ./wish and ./tclsh there.
.PHONY: win-wish win-tclsh win-test
win-wish:  $(BASEDIR)/wish$(EXE_EXT)
win-tclsh: $(BASEDIR)/tclsh$(EXE_EXT)

# Windows counterpart of `test`: builds ./wish.exe and asserts against it under
# wine (skips without wine or a display). The script does its own build.
win-test:
	$(ZIPPYDIR)/tests/smoke-win.sh

# build.tcl auto-includes the core tcl/tk library from $(PREFIX); the dep script
# dirs ($(DEP_LIBS)/$(TCL_PKG_LIBS), derived from $(PREFIX)) carry the rest, same
# as the native wish/tclsh targets.
$(BASEDIR)/wish$(EXE_EXT): $(KITSH_WISH) $(WISH) $(DEP_STAMPS) $(BUILD_TCL)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP=$(KITSH_WISH) \
	$(HOST_TCLSH) $(BUILD_TCL) wish $(BASEDIR) $@ "" "" "" \
		$(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)

$(BASEDIR)/tclsh$(EXE_EXT): $(KITSH_TCLSH) $(TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP=$(KITSH_TCLSH) \
	$(HOST_TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" "" \
		$(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)

# ==== Windows counterpart of `app` ====
# Bundle the project's SOURCES/ENTRY_SCRIPT onto the launcher with a host tclsh,
# exactly as win-wish/win-tclsh do, but driven by BIN_NAME instead of a bare
# interpreter. $(BASE_INTERP) is the SHELL_TYPE launcher (kitsh_wish.exe /
# kitsh_tclsh.exe). Output is $(BIN_NAME).exe at the repo root, matching the
# native `app` target which drops $(BIN_NAME) there.
ifdef BIN_NAME
.PHONY: win-app
win-app: $(BASEDIR)/$(BIN_NAME)$(EXE_EXT)

$(BASEDIR)/$(BIN_NAME)$(EXE_EXT): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL) $(APP_SRC_FILES)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP=$(BASE_INTERP) \
	$(HOST_TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ \
		$(_SOURCES_CSV) $(ENTRY_SCRIPT) $(_EXCLUDES_CSV) $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
endif

# ==== Windows counterpart of `lib` ====
# The shared static-library rules in zippy.mk build the shim, park the script zip
# in .rodata and merge the archive; the cross scripts.zip recipe there bundles
# with HOST_TCLSH (the cross-built PE tclsh can't run on the build host). Here we
# just retarget the binutils to the MinGW cross tools; the shim compiles with the
# same KITSH_* cross flags as the launcher. Output is $(BASEDIR)/lib<...>.a,
# a static PE archive a MinGW-Qt app links exactly like the native .a.
KIT_LD      := $(CROSS)-ld
KIT_OBJCOPY := $(CROSS)-objcopy
KIT_AR      := $(CROSS)-ar

.PHONY: win-lib
win-lib: lib
