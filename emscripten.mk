# emscripten.mk - wasm32 cross-build overlay, included by zippy.mk when
# TARGET_OS=emscripten. Builds Tcl + the TEA deps with emcc for a browser or
# node, single-threaded (no -pthread: no SharedArrayBuffer, so the page that
# loads the result needs no COOP/COEP headers).
#
# What comes out:
#   make TARGET_OS=emscripten tclsh     ./tclsh.mjs + ./tclsh.wasm: an ES module
#                                       whose factory boots an interpreter over
#                                       the bundled script library; driven from
#                                       JavaScript through zippy_eval (see
#                                       emscripten/kitsh_em.c)
#   make TARGET_OS=emscripten app       the same with BIN_NAME's SOURCES bundled
#                                       and ENTRY_SCRIPT run at boot
#   make TARGET_OS=emscripten lib       lib<name>.a, a wasm archive of the shim,
#                                       the script zip, the notifier and every
#                                       static package; the project links it
#                                       with emcc and $(ZIPPY_EM_LDFLAGS)
#                                       (emscripten/link.mk)
#
# Two things differ from the other cross overlays, and both follow from the
# target rather than from taste:
#
#   - Every dep builds in a private copy under $(BUILDDIR). The native build
#     configures Tcl and the TEA packages in-tree, and autoconf refuses a second
#     configure of a tree that already has one (`source directory already
#     configured`), so sharing $(DEPSDIR)'s trees the way android.mk does would
#     make the two builds mutually exclusive in one checkout.
#   - The script zip is a C array, not `ld -b binary`: wasm-ld has no binary
#     input mode and clang's wasm assembler crashes on .incbin. The one visible
#     consequence is that the symbols are _binary_scripts_zip_{start,len}, with
#     no _end (emscripten/blob2c.tcl says why), so a shim written for both the
#     native and the wasm archive takes a length rather than an end pointer.
#
# Nothing here uses Tcl's own tclsh output: emcc emits it as JavaScript, and
# Tcl's install step appends the zipfs image to that, which nothing can run.
# libtcl9.0.a is the product; $(TCLSH) is a stamp.

EM_CC     := emcc
EM_CXX    := em++
EM_AR     := emar
EM_RANLIB := emranlib
EM_TC     := CC=$(EM_CC) CXX=$(EM_CXX) AR=$(EM_AR) RANLIB=$(EM_RANLIB)

# -sUSE_ZLIB=1 at compile time as well as link: Tcl's configure only puts its
# bundled zlib on tclZlib.c's include path, so tclEvent.c fails with "zlib.h
# not found" the moment configure picks the internal copy. Emscripten's zlib
# port supplies a header configure can find, so it takes the system path and
# the question goes away.
EM_CFLAGS := -O2 -sUSE_ZLIB=1

include $(ZIPPYDIR)/emscripten/link.mk

# No ELF to strip, and objcopy would not know what to do with a .mjs.
STRIP := 0

# ==== The host interpreter ====
# The bundling step (zipfs mkzip) and the TEA packages' install steps need a
# Tcl 9 that runs on the build host, and the wasm one cannot. Unless the caller
# names one, zippy builds its own native tclsh into the native tree beside this
# one - the same $(BASEDIR)/_build the native build uses, so a checkout that
# has already built natively pays nothing. The recursive make must name the
# host's TARGET_OS explicitly: the command-line TARGET_OS=emscripten would
# otherwise ride MAKEFLAGS into it.
NATIVE_HOST_OS  := $(if $(filter Darwin,$(shell uname -s)),macos,linux)
NATIVE_TCLSH    := $(BASEDIR)/_build/local/bin/tclsh$(TCL_BVER)
HOST_TCLSH      ?= $(NATIVE_TCLSH)
ifeq ($(HOST_TCLSH),$(NATIVE_TCLSH))
$(HOST_TCLSH):
	$(MAKE) -f $(ZIPPYDIR)/zippy.mk TARGET_OS=$(NATIVE_HOST_OS) \
	    BASEDIR=$(BASEDIR) DEPSDIR=$(DEPSDIR) SHELL_TYPE=tclsh $@
endif

# ==== Private source copies ====
# $(1) source tree, $(2) copy, $(3) subdir holding the Makefile to distclean,
# $(4) anything else configure generated, relative to the copy.
#
# The shared source tree carries the native build's in-tree configure output and
# its objects, and the copy has to look like pristine source or the wasm build
# reuses them - a stale .o is newer than its .c, so make never recompiles it and
# an x86-64 object lands in a wasm archive.
#
# distclean is tried first because it knows the tree, but it cannot be relied
# on: it runs through the copied Makefile, whose srcdir configure wrote as an
# absolute path. That path exists when the build is on the same machine and does
# not when it is in a container, where the failure is silent and the leftovers
# survive. So the scrub is the part that has to be enough: every Makefile
# configure generated beside its Makefile.in, the caches, anything compiled, and
# $(4) for what none of those catch - a build directory configure made up, which
# has no Makefile.in of its own to find it by.
#
# The .tmp-then-mv keeps an interrupted copy from passing as a finished one.
define em-private-copy
rm -rf $(2) $(2).tmp
mkdir -p $(dir $(2))
$(CP_TREE) $(1) $(2).tmp
if [ -f $(2).tmp/$(3)/Makefile ]; then $(MAKE) -C $(2).tmp/$(3) distclean >/dev/null 2>&1 || true; fi
$(if $(4),rm -rf $(addprefix $(2).tmp/,$(4)))
find $(2).tmp -name Makefile.in -execdir rm -f Makefile \;
find $(2).tmp \( -name config.status -o -name config.cache -o -name config.log \
    -o -name '*.o' -o -name '*.a' \) -delete
mv $(2).tmp $(2)
endef

EM_TCL_SRC        := $(BUILDDIR)/tcl$(TCL_VER)
EM_TDOM_SRC       := $(BUILDDIR)/tdom-$(TDOM_VER)-src
EM_LIBTOMCRYPT_SRC := $(BUILDDIR)/libtomcrypt

# Tcl's configure builds the bundled packages out of tree, in unix/pkgs8 (and
# unix/pkgs) with an absolute --srcdir into pkgs/ - the directories that make
# distclean unreliable here in the first place. libtcl.vfs and tclsh are the
# native build's own output.
$(EM_TCL_SRC): $(TCL_SRC)
	$(call em-private-copy,$(TCL_SRC),$@,unix,unix/pkgs unix/pkgs8 unix/libtcl.vfs unix/tclsh)
	touch $@

$(EM_TDOM_SRC): $(DEPSDIR)/.tdom_extracted
	$(call em-private-copy,$(TDOM_SRC),$@,.)
	touch $@

$(EM_LIBTOMCRYPT_SRC): $(LIBTOMCRYPT_SRC)
	$(call em-private-copy,$(LIBTOMCRYPT_SRC),$@,.)
	touch $@

# ==== Tcl ====
# The native recipe with --host and emconfigure, plus two settings found by
# running it:
#   --disable-load          there is nothing to dlopen in a wasm module; every
#                           package is linked in and `load {} <Name>` resolves
#                           it from the static table
#   ac_cv_header_sys_epoll_h=no
#                           emscripten ships sys/epoll.h, so configure picks
#                           the epoll notifier, which then wants sys/queue.h,
#                           which emscripten does not ship. The select notifier
#                           compiles, and either is replaced at runtime by
#                           emscripten/tclemnotify.c anyway.
# Threads: Tcl builds threaded (its default) against Emscripten's single-thread
# pthread stubs, and so does the Thread package. Neither can start a thread;
# nothing in a wasm build should try, and a `thread::create` that fails is a
# clearer failure than a Tcl configured without mutexes would give.
$(TCLSH): $(EM_TCL_SRC) $(HOST_TCLSH)
	cd $(EM_TCL_SRC)/unix && \
		CFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS)" LDFLAGS="-sUSE_ZLIB=1" \
		emconfigure ./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --enable-zipfs --disable-shared --disable-load \
			--with-system-libtommath=no ac_cv_header_sys_epoll_h=no && \
		sed $(SED_INPLACE_FLAG) 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		emmake $(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		emmake $(MAKE) install TCLSH_PROG=$(HOST_TCLSH) && \
		emmake $(MAKE) install-libraries TCLSH_PROG=$(HOST_TCLSH) && \
		cp $(EM_TCL_SRC)/pkgs/thread$(THREAD_VER)/lib/ttrace.tcl $(PREFIX)/lib/thread$(THREAD_VER)/
	cp $(ZIPPYDIR)/emscripten/tclemnotify.h $(ZIPPYDIR)/emscripten/opfsvfs.h \
	    $(ZIPPYDIR)/emscripten/wschan.h $(ZIPPYDIR)/emscripten/httpx.h \
	    $(ZIPPYDIR)/emscripten/emqueue.h $(PREFIX)/include/
	touch $@

# ==== sqlite3 (SQLCipher over libtomcrypt) ====
# Both are plain C. The cross recipe from android.mk with the emscripten
# toolchain; libtomcrypt in its private copy because its Makefile builds
# in-tree. Two accommodations, both local to the build copy:
#   - SQLCipher registers its shutdown hook by planting a pointer in a
#     .fini_array section, which wasm object files cannot carry (clang aborts
#     on it). The same file uses __attribute__((destructor)) for one Apple
#     configuration, and wasm supports that form, so the sed below rewrites
#     the one line to it - guarded, so a SQLCipher that moves it fails here
#     rather than in the compiler.
#   - -Wno-incompatible-pointer-types: SQLCipher's two `-key` sites hand
#     Tcl_GetByteArrayFromObj an int* where Tcl 9 declares Tcl_Size*; gcc
#     warns and clang errors, and on wasm32 the two are the same width.
$(PREFIX)/.libtomcrypt_installed: $(EM_LIBTOMCRYPT_SRC)
	$(MAKE) -C $(EM_LIBTOMCRYPT_SRC) $(EM_TC) CFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS)" -j$(NPROC)
	mkdir -p $(PREFIX)/include $(PREFIX)/lib
	cp -r $(EM_LIBTOMCRYPT_SRC)/src/headers/. $(PREFIX)/include/
	cp $(EM_LIBTOMCRYPT_SRC)/libtomcrypt.a $(PREFIX)/lib/
	touch $@

$(PREFIX)/lib/sqlite3.$(SQLITE3_DIR_SUFFIX)/libtcl9sqlite3.$(SQLITE3_DIR_SUFFIX).a: \
		$(TCL_SRC) $(SQLCIPHER_SRC)/tclsqlite3.c $(TCLSH) $(PREFIX)/.libtomcrypt_installed
	rm -rf $(SQLCIPHER_TCL_BUILD)
	mkdir -p $(SQLCIPHER_TCL_BUILD)
	cp -a $(SQLITE3_TCL_WRAPPER)/. $(SQLCIPHER_TCL_BUILD)/
	cp $(SQLCIPHER_SRC)/tclsqlite3.c $(SQLCIPHER_TCL_BUILD)/generic/tclsqlite3.c
	cp $(SQLCIPHER_SRC)/sqlite3.h $(SQLCIPHER_TCL_BUILD)/generic/sqlite3.h
	sed $(SED_INPLACE_FLAG) \
	    's|^static void (\*const sqlcipher_fini_func)(void) __attribute__((used, section("\.fini_array"))) = sqlcipher_fini;$$|static void sqlcipher_cleanup_destructor(void) __attribute__((destructor)); static void sqlcipher_cleanup_destructor(void) { sqlcipher_fini(); }|' \
	    $(SQLCIPHER_TCL_BUILD)/generic/tclsqlite3.c
	@grep -q 'sqlcipher_cleanup_destructor(void) __attribute__((destructor)); static' \
	    $(SQLCIPHER_TCL_BUILD)/generic/tclsqlite3.c || { \
	    echo "zippy: SQLCipher's .fini_array registration moved; update the sed in emscripten.mk" >&2; exit 1; }
	cd $(SQLCIPHER_TCL_BUILD) && \
		CFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS) -Wno-incompatible-pointer-types \
			-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_LIBTOMCRYPT \
			-DSQLITE_EXTRA_INIT=sqlcipher_extra_init \
			-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLITE_TEMP_STORE=2 \
			-DSQLCIPHER_LOG_LEVEL_DEFAULT=0" \
		CPPFLAGS="-I$(PREFIX)/include" \
		emconfigure ./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		emmake $(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		emmake $(MAKE) install TCLSH_PROG=$(HOST_TCLSH)

# ==== TEA deps ====
$(PREFIX)/.tdom_installed: $(EM_TDOM_SRC) $(TCLSH)
	cd $(EM_TDOM_SRC) && \
		CFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS)" CXXFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS)" \
		emconfigure ./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		emmake $(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		emmake $(MAKE) install TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# Pure-Tcl modules only (install-tcl); the critcl C accelerators cannot cross.
# In the shared tree, as android.mk does: configure only writes a Makefile
# there, and install-tcl only copies scripts out.
$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install-tcl TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# ==== omemo (picomemo-tcl, own Makefile) ====
# mbedtls comes from the shared cmake recipe through $(CMAKE_TOOLCHAIN), which
# the emscripten branch of zippy.mk points at Emscripten's toolchain file.
# OUTDIR keeps the objects out of the shared source tree.
$(PREFIX)/.omemo_installed: $(TCLSH) $(OMEMO_SRC) $(PREFIX)/.mbedtls_installed
	$(MAKE) -C $(OMEMO_SRC) OUTDIR=$(OMEMO_BUILD) \
		$(OMEMO_BUILD)/libtcl9omemo$(OMEMO_VER).a \
		$(EM_TC) TCL_PREFIX=$(PREFIX) MBED_PREFIX=$(PREFIX) \
		CFLAGS="$(EM_CFLAGS) $(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@

# Not ported here: mtls (a page's TLS is the browser's), rtc/rtcma/rtcmv (the
# page's WebRTC is the browser's), tclwuffs/tkwuffs, tkdnd, img. Naming any of
# them in DEPS fails at the dep stamp with no rule to make it, which is the
# honest answer until someone needs one under wasm.

# ==== The notifier ====
# Compiled once and folded into every launcher and into lib<name>.a (with
# compat.o beside it), so a project linking the archive gets
# TclEm_InstallNotifier without compiling anything of zippy's itself.
EM_NOTIFY_OBJ := $(BUILDDIR)/tclemnotify.o
$(EM_NOTIFY_OBJ): $(ZIPPYDIR)/emscripten/tclemnotify.c $(ZIPPYDIR)/emscripten/tclemnotify.h $(TCLSH)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -I$(PREFIX)/include -c $< -o $@

# libc calls the deps expect and Emscripten's musl lacks; see compat.c.
EM_COMPAT_OBJ := $(BUILDDIR)/compat.o
$(EM_COMPAT_OBJ): $(ZIPPYDIR)/emscripten/compat.c
	mkdir -p $(@D)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -c $< -o $@

# ==== The OPFS VFS ====
# SQLite's files in OPFS rather than in Emscripten's memory filesystem; see
# emscripten/opfsvfs.c and its JavaScript half, emscripten/opfs-pool.js. It
# needs the sqlite3.h the database engine was built from, which is SQLCipher's,
# in the build copy - nothing installs it.
EM_OPFSVFS_OBJ := $(BUILDDIR)/opfsvfs.o
$(EM_OPFSVFS_OBJ): $(ZIPPYDIR)/emscripten/opfsvfs.c $(ZIPPYDIR)/emscripten/opfsvfs.h \
		$(PREFIX)/lib/sqlite3.$(SQLITE3_DIR_SUFFIX)/libtcl9sqlite3.$(SQLITE3_DIR_SUFFIX).a
	mkdir -p $(@D)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -I$(PREFIX)/include \
	    -I$(ZIPPYDIR)/emscripten -I$(SQLCIPHER_TCL_BUILD)/generic -c $< -o $@

# ==== What a page hands the interpreter ====
# emqueue is the one way in: a JavaScript handler cannot call a suspended
# interpreter (see emqueue.c), so it parks the event and Tcl drains it from a
# timer. wschan and httpx are the two things that arrive that way - the
# network a page has, in its two forms.
EM_EMQUEUE_OBJ := $(BUILDDIR)/emqueue.o
$(EM_EMQUEUE_OBJ): $(ZIPPYDIR)/emscripten/emqueue.c $(ZIPPYDIR)/emscripten/emqueue.h $(TCLSH)
	mkdir -p $(@D)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -I$(PREFIX)/include \
	    -I$(ZIPPYDIR)/emscripten -c $< -o $@

EM_HTTPX_OBJ := $(BUILDDIR)/httpx.o
$(EM_HTTPX_OBJ): $(ZIPPYDIR)/emscripten/httpx.c $(ZIPPYDIR)/emscripten/httpx.h \
		$(ZIPPYDIR)/emscripten/emqueue.h $(TCLSH)
	mkdir -p $(@D)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -I$(PREFIX)/include \
	    -I$(ZIPPYDIR)/emscripten -c $< -o $@

# ==== WebSockets ====
# The only network a page has; see emscripten/wschan.c. Plain Tcl and
# emscripten headers, so it needs nothing the notifier does not.
EM_WSCHAN_OBJ := $(BUILDDIR)/wschan.o
$(EM_WSCHAN_OBJ): $(ZIPPYDIR)/emscripten/wschan.c $(ZIPPYDIR)/emscripten/wschan.h \
		$(ZIPPYDIR)/emscripten/emqueue.h $(TCLSH)
	mkdir -p $(@D)
	$(EM_CC) $(EM_CFLAGS) $(SIZE_CFLAGS) -I$(PREFIX)/include \
	    -I$(ZIPPYDIR)/emscripten -c $< -o $@

EM_EXTRA_OBJS  := $(EM_NOTIFY_OBJ) $(EM_COMPAT_OBJ) $(EM_OPFSVFS_OBJ) \
                  $(EM_EMQUEUE_OBJ) $(EM_WSCHAN_OBJ) $(EM_HTTPX_OBJ)
LIB_EXTRA_OBJS := $(EM_EXTRA_OBJS)

# zippy.mk's `lib` rule is read before this overlay is included, so the
# $(LIB_EXTRA_OBJS) in its prerequisites expanded to nothing while its recipe,
# expanded when it runs, names these objects. Say them again here, where they
# exist, or the archive merge fails on a member that was never built.
$(LIBOUT): $(EM_EXTRA_OBJS)

# ==== kitsh / lib link overrides ====
KITSH_LD          := $(EM_CC)
KITSH_CFLAGS      := -I$(PREFIX)/include -I$(ZIPPYDIR)/emscripten $(EM_CFLAGS)
KITSH_SYSLIBS     := -sUSE_ZLIB=1
KITSH_EXTRA_LDFLAGS := $(ZIPPY_EM_LDFLAGS)
# wasm-ld resolves archives to a fixed point on its own.
LINK_GROUP_START  :=
LINK_GROUP_END    :=
KIT_AR            := $(EM_AR)

# The script zip as a C array (see the header comment and blob2c.tcl).
# -O1: the object is data; the point is to keep clang's time on a multi-MB
# initialiser down, not to optimise it.
define em-blob-obj
$(HOST_TCLSH) $(ZIPPYDIR)/emscripten/blob2c.tcl $(1) $(basename $(2)).c _binary_scripts_zip
$(EM_CC) -O1 -c $(basename $(2)).c -o $(2)
endef

$(SCRIPTS_OBJ): $(SCRIPTS_ZIP) $(ZIPPYDIR)/emscripten/blob2c.tcl $(HOST_TCLSH)
	$(call em-blob-obj,$<,$@)

# ==== Launchers ====
# A bare zip (the script library, the static packages' pkgIndex, the deps'
# Tcl) for the standalone tclsh; the app zip (bare + SOURCES + ENTRY_SCRIPT)
# is $(SCRIPTS_ZIP), whose cross recipe in zippy.mk already bundles with
# HOST_TCLSH. Each becomes its own object because the symbol name is fixed.
EM_BARE_ZIP := $(BUILDDIR)/bare.zip
EM_BARE_OBJ := $(BUILDDIR)/bare.o

$(EM_BARE_ZIP): $(DEP_STAMPS) $(BUILD_TCL) $(HOST_TCLSH)
	mkdir -p $(@D)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP= \
	$(HOST_TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" "" \
		$(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)

$(EM_BARE_OBJ): $(EM_BARE_ZIP) $(ZIPPYDIR)/emscripten/blob2c.tcl $(HOST_TCLSH)
	$(call em-blob-obj,$<,$@)

# $(1) the scripts object, $(2) the factory's export name.
define em-link-launcher
$(EM_CC) $(KITSH_CFLAGS) $(SIZE_CFLAGS) $(KITSH_DEP_FLAGS) -I$(ZIPPYDIR) \
	-o $@ $(ZIPPYDIR)/emscripten/kitsh_em.c $(EM_EXTRA_OBJS) $(1) \
	$(KITSH_TCL_LIBS) $(KITSH_SYSLIBS) $(ZIPPY_EM_LDFLAGS) \
	-sEXPORT_NAME=$(2) $(SIZE_LDFLAGS)
endef

.PHONY: tclsh
tclsh: $(BASEDIR)/tclsh$(EXE_EXT)

$(BASEDIR)/tclsh$(EXE_EXT): $(ZIPPYDIR)/emscripten/kitsh_em.c $(ZIPPYDIR)/static_pkgs.h \
		$(EM_EXTRA_OBJS) $(EM_BARE_OBJ) $(DEP_STAMPS) $(TCLSH)
	$(call em-link-launcher,$(EM_BARE_OBJ),createTclsh)

ifdef BIN_NAME
.PHONY: app
app: $(BASEDIR)/$(BIN_NAME)$(EXE_EXT)

$(BASEDIR)/$(BIN_NAME)$(EXE_EXT): $(ZIPPYDIR)/emscripten/kitsh_em.c $(ZIPPYDIR)/static_pkgs.h \
		$(EM_EXTRA_OBJS) $(SCRIPTS_OBJ) $(DEP_STAMPS) $(TCLSH)
	$(call em-link-launcher,$(SCRIPTS_OBJ),create$(subst -,_,$(BIN_NAME)))
endif

# ==== Test ====
# The exit test for the whole overlay: the interpreter boots from the bundled
# zip, the static packages resolve through `load {}`, SQLite round-trips a row,
# and - the one that decides whether any of this is usable - `vwait` returns
# while JavaScript keeps running. Needs node.
.PHONY: emscripten-test
emscripten-test: $(BASEDIR)/tclsh$(EXE_EXT)
	node $(ZIPPYDIR)/tests/emscripten.mjs $<

# The OPFS VFS, over a mock directory because node has no OPFS: an encrypted
# database in WAL mode with two connections open, surviving a reopen of the
# pool. See tests/emscripten-opfs.mjs. Needs node.
.PHONY: emscripten-opfs-test
emscripten-opfs-test: $(BASEDIR)/tclsh$(EXE_EXT)
	node $(ZIPPYDIR)/tests/emscripten-opfs.mjs $<
