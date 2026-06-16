# android.mk - Android NDK cross-build overlay, included by zippy.mk when
# TARGET_OS=android. Builds Tcl + the TEA deps for arm64-v8a / API 30 (bionic)
# with the NDK clang. Closer to the native unix build than windows.mk: same unix/
# tree and ELF link, just the NDK compiler/sysroot/syslibs. The per-profile docker
# cache keeps DEPSDIR android-only, so the in-place builds need no isolated copies.
#
# Output: a bionic arm64 executable, shipped in an APK as lib*.so and exec'd from
# nativeLibraryDir. Build with: make TARGET_OS=android android-tclsh, or
# android-jnilibs to stage the renamed binary + libc++_shared.so as a jniLibs tree.

# arm64-v8a / API 30 (bionic). Exported for android-toolchain.cmake to read; can't
# come via -D, as the bundled-dep cmake ExternalProjects wouldn't inherit it.
ANDROID_API  ?= 30
ANDROID_ABI  ?= arm64-v8a
ANDROID_PLATFORM := android-$(ANDROID_API)
export ANDROID_ABI
export ANDROID_PLATFORM

# API-versioned NDK clang wrappers (aarch64-linux-android30-clang/-clang++) and
# the unified llvm binutils; all on PATH in the ndk image.
ANDROID_CC     := $(CROSS)$(ANDROID_API)-clang
ANDROID_CXX    := $(CROSS)$(ANDROID_API)-clang++
ANDROID_AR     := llvm-ar
ANDROID_RANLIB := llvm-ranlib
ANDROID_TC     := CC=$(ANDROID_CC) CXX=$(ANDROID_CXX) AR=$(ANDROID_AR) RANLIB=$(ANDROID_RANLIB)

# Strip the kitsh launcher with the NDK's llvm tools; the host objcopy/strip
# don't recognise the aarch64 ELF.
OBJCOPY   := llvm-objcopy
STRIP_BIN := llvm-strip

# Native tcl9.0 for the bundling step (HOST_TCLSH) and the cross install steps
# that run a native interp (install-tzdata, bundled-pkg zipfs). Shipped in the
# ndk image as tclsh9.0.
HOST_TCLSH ?= tclsh$(TCL_BVER)

# ==== Tcl (unix/ cross-build) ====
# Same as the native recipe plus --host and the NDK toolchain; install steps run
# the native interp (TCL_EXE), so the host never executes the aarch64 tclsh.
$(TCLSH): $(TCL_SRC)
	cd $(TCL_SRC)/unix && \
		$(ANDROID_TC) CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --enable-zipfs --disable-shared --with-system-libtommath=no && \
		sed -i 's/--enable-shared; ) || exit/--disable-shared; ) || exit/g' Makefile && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install TCL_EXE=$(HOST_TCLSH) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install-libraries TCL_EXE=$(HOST_TCLSH) TCLSH_PROG=$(HOST_TCLSH) && \
		cp $(TCL_SRC)/pkgs/thread$(THREAD_VER)/lib/ttrace.tcl $(PREFIX)/lib/thread$(THREAD_VER)/

# ==== TEA deps ====
$(PREFIX)/.tdom_installed: $(DEPSDIR)/.tdom_extracted $(TCLSH)
	cd $$(ls -d $(DEPSDIR)/tdom-*/) && \
		$(ANDROID_TC) CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		./configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# Pure-Tcl modules only (install-tcl); the critcl C accelerators can't cross.
$(PREFIX)/.tcllib_installed: $(TCLLIB_SRC) $(TCLSH)
	cd $(TCLLIB_SRC) && \
		./configure --prefix=$(PREFIX) && \
		$(MAKE) install-tcl TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# Links against zippy's shared mbedtls (built by the shared .mbedtls_installed
# cmake recipe via $(CMAKE_TOOLCHAIN) = the NDK toolchain file).
$(PREFIX)/.mtls_installed: $(MTLS_SRC) $(TCLSH) $(PREFIX)/.mbedtls_installed
	mkdir -p $(MTLS_SRC)/build
	cd $(MTLS_SRC)/build && \
		$(ANDROID_TC) CFLAGS="$(SIZE_CFLAGS)" CXXFLAGS="$(SIZE_CFLAGS)" \
		../configure --host=$(CROSS) --build=$(CROSS_BUILD) \
			--prefix=$(PREFIX) --with-tcl=$(PREFIX)/lib --disable-shared \
			--with-mbedtls=$(PREFIX) \
			CPPFLAGS='-DMBEDTLS_USER_CONFIG_FILE=\"$(MBEDTLS_USER_CFG)\"' && \
		$(MAKE) -j$(NPROC) TCLSH_PROG=$(HOST_TCLSH) && \
		$(MAKE) install TCLSH_PROG=$(HOST_TCLSH)
	touch $@

# ==== rtc/rtcma (shared cmake recipe + the NDK toolchain via CMAKE_TOOLCHAIN) ====
# Build only the static archives the kit links, as windows.mk does; the default
# also builds shared rtc/rtcma modules that aren't needed. The native cmake C
# flags ($(SIZE_CFLAGS)) carry over - no Windows STATIC_BUILD/dllimport defines.
RTC_BUILD_TARGETS   := --target rtc_tcl_static
RTCMA_BUILD_TARGETS := --target rtcma rtcma_tcl_static

# ==== omemo / tclwuffs (own Makefiles) ====
# In-place builds (the docker cache keeps DEPSDIR android-only) with the NDK
# clang. -fPIC overrides their STATIC_CF default for the PIE kitsh link.
$(PREFIX)/.omemo_installed: $(TCLSH) $(OMEMO_SRC) $(PREFIX)/.mbedtls_installed
	$(MAKE) -C $(OMEMO_SRC) libtcl9omemo$(OMEMO_VER).a \
		$(ANDROID_TC) TCL_PREFIX=$(PREFIX) MBED_PREFIX=$(PREFIX) \
		CFLAGS="-fPIC $(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@

$(PREFIX)/.tclwuffs_installed: $(TCLSH) $(TCLWUFFS_SRC) $(TCLWUFFS_EXTRA_DEPS)
	$(MAKE) -C $(TCLWUFFS_SRC) $(TCLWUFFS_MAKE_TARGETS) \
		$(ANDROID_TC) TCLCONFIG=$(PREFIX)/lib/tclConfig.sh \
		TKCONFIG=$(PREFIX)/lib/tkConfig.sh \
		CFLAGS="-fPIC $(SIZE_CFLAGS)"
	mkdir -p $(PREFIX)
	touch $@

# ==== kitsh link overrides ====
# The shared kitsh recipe + native KITSH_TCL_LIBS/DEP_LIBS carry over. bionic folds
# pthread/dl into libc, so only libz/libm are named. rtc/rtcma add libdatachannel's
# C++: link with clang++ (libc++_shared, since STATIC_LIBSTDCXX=0); zippy.mk's
# rtc/rtcma block already set -xc to keep kitsh.c compiled as C.
ifneq (,$(filter rtc rtcma,$(DEPS)))
  KITSH_LD := $(ANDROID_CXX)
else
  KITSH_LD := $(ANDROID_CC)
endif
KITSH_SYSLIBS := -lz -lm

# ==== bundle the script library onto the launcher ====
# Mirrors the native tclsh target but bundles with HOST_TCLSH (the host can't run
# the aarch64 launcher). zipfs mkimg only manipulates files, so a native interp
# bundles for the android target. Output: ./tclsh (an arm64 ELF).
.PHONY: android-tclsh
android-tclsh: $(BASEDIR)/tclsh

$(BASEDIR)/tclsh: $(KITSH_TCLSH) $(DEP_STAMPS) $(BUILD_TCL)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP=$(KITSH_TCLSH) \
	$(HOST_TCLSH) $(BUILD_TCL) tclsh $(BASEDIR) $@ "" "" "" \
		$(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
	$(call maybe_copy_debug,$(KITSH_TCLSH),$@)

# ==== app (the actual daemon, e.g. tackyd-json) ====
# Bundles BIN_NAME's SOURCES/ENTRY_SCRIPT onto the SHELL_TYPE launcher with
# HOST_TCLSH, like win-app. Output: ./$(BIN_NAME) (an arm64 ELF), shipped in the
# APK as lib$(BIN_NAME).so.
ifdef BIN_NAME
.PHONY: android-app
android-app: $(BASEDIR)/$(BIN_NAME)

$(BASEDIR)/$(BIN_NAME): $(BASE_INTERP) $(DEP_STAMPS) $(BUILD_TCL) $(APP_SRC_FILES)
	ZIPPY_BUILDDIR=$(BUILDDIR) ZIPPY_EXE_EXT=$(EXE_EXT) ZIPPY_BASE_INTERP=$(BASE_INTERP) \
	$(HOST_TCLSH) $(BUILD_TCL) $(SHELL_TYPE) $(BASEDIR) $@ \
		$(_SOURCES_CSV) $(ENTRY_SCRIPT) $(_EXCLUDES_CSV) $(_STATIC_PKGS_CSV) $(DEP_LIBS) $(TCL_PKG_LIBS)
	$(call maybe_copy_debug,$(BASE_INTERP),$@)

# ==== jniLibs-ready bundle ====
# Stage android-app's output as an Android jniLibs/<abi>/ subtree: the executable
# renamed to lib*.so (the only name the APK packager ships into the executable
# nativeLibraryDir) plus the NDK's libc++_shared.so, which the C++ deps need at
# runtime. Hyphens in BIN_NAME become underscores (tackyd-json -> libtackyd_json.so).
ANDROID_LIB_NAME    ?= lib$(subst -,_,$(BIN_NAME)).so
ANDROID_JNILIBS_DIR ?= $(BASEDIR)/jniLibs/$(ANDROID_ABI)
ANDROID_LIBCXX      := $(ANDROID_NDK)/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/$(CROSS)/libc++_shared.so

# libc++_shared.so is only NEEDED when the C++ deps are linked in (same filter as
# the KITSH_LD gating above).
ifneq (,$(filter rtc rtcma,$(DEPS)))
  ANDROID_RUNTIME_LIBS := $(ANDROID_LIBCXX)
endif

.PHONY: android-jnilibs
android-jnilibs: $(BASEDIR)/$(BIN_NAME)
	mkdir -p $(ANDROID_JNILIBS_DIR)
	cp $(BASEDIR)/$(BIN_NAME) $(ANDROID_JNILIBS_DIR)/$(ANDROID_LIB_NAME)
	$(if $(ANDROID_RUNTIME_LIBS),cp $(ANDROID_RUNTIME_LIBS) $(ANDROID_JNILIBS_DIR)/,)
endif
