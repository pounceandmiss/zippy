/*
 * static_pkgs.h - the one list of statically-linked Tcl packages zippy bundles.
 * Used by the kitsh launcher (kitsh.c) and exposed as the embedder API for the
 * `lib` target: a project's shim source includes this header (zippy is on its
 * include path) and calls Zippy_RegisterStaticPackages() so the packages it
 * registers exactly match what got compiled into the archive.
 *
 * Each entry is gated by the same -DWITH_* flag zippy.mk passes at compile
 * time, and mirrors the pkg:loadname:version triples in STATIC_PKGS (which
 * build.tcl turns into `load {} <loadname>` pkgIndex entries).
 *
 * Include <tcl.h> before this header. Pass NULL to register for every
 * interpreter in the process (lazy `load {} <Name>` resolution); a non-NULL
 * interp would run each init proc immediately, which callers rarely want.
 */
#ifndef ZIPPY_STATIC_PKGS_H
#define ZIPPY_STATIC_PKGS_H

#include <tcl.h>

extern int Thread_Init(Tcl_Interp *);
extern int Sqlite3_Init(Tcl_Interp *);
#ifdef WITH_TDOM
extern int Tdom_Init(Tcl_Interp *);
#endif
#ifdef WITH_MTLS
extern int Mtls_Init(Tcl_Interp *);
#endif
#ifdef WITH_RTC
extern int Rtc_Init(Tcl_Interp *);
#endif
#ifdef WITH_RTCMA
extern int Rtcma_Init(Tcl_Interp *);
#endif
#ifdef WITH_OMEMO
extern int Omemo_Init(Tcl_Interp *);
#endif
#ifdef WITH_TCLWUFFS
extern int Tclwuffs_Init(Tcl_Interp *);
#endif
#ifdef WITH_TKWUFFS
extern int Tkwuffs_Init(Tcl_Interp *);
#endif
#ifdef WITH_TKDND
extern int Tkdnd_Init(Tcl_Interp *);
#endif
/* Img/tkimg modules are gated individually so IMG_INCLUDE in zippy.mk can
 * drop unused format readers (and the libpng/libjpeg/libtiff/zlib that some
 * of them pull in) from the link. WITH_IMG_TKIMG is always defined when img
 * is in DEPS; bases and format readers below come and go per-whitelist. */
#ifdef WITH_IMG_TKIMG
extern int Tkimg_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_ZLIBTCL
extern int Zlibtcl_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PNGTCL
extern int Pngtcl_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_JPEGTCL
extern int Jpegtcl_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_TIFFTCL
extern int Tifftcl_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_BMP
extern int Tkimgbmp_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_DTED
extern int Tkimgdted_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_FLIR
extern int Tkimgflir_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_GIF
extern int Tkimggif_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_ICO
extern int Tkimgico_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_JPEG
extern int Tkimgjpeg_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PCX
extern int Tkimgpcx_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PIXMAP
extern int Tkimgpixmap_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PNG
extern int Tkimgpng_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PPM
extern int Tkimgppm_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_PS
extern int Tkimgps_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_RAW
extern int Tkimgraw_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_SGI
extern int Tkimgsgi_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_SUN
extern int Tkimgsun_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_TGA
extern int Tkimgtga_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_TIFF
extern int Tkimgtiff_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_WINDOW
extern int Tkimgwindow_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_XBM
extern int Tkimgxbm_Init(Tcl_Interp *);
#endif
#ifdef WITH_IMG_XPM
extern int Tkimgxpm_Init(Tcl_Interp *);
#endif

static inline void Zippy_RegisterStaticPackages(Tcl_Interp *interp) {
    Tcl_StaticPackage(interp, "Thread",  Thread_Init,  NULL);
    Tcl_StaticPackage(interp, "Sqlite3", Sqlite3_Init, NULL);
#ifdef WITH_TDOM
    Tcl_StaticPackage(interp, "tdom",    Tdom_Init,    NULL);
#endif
#ifdef WITH_MTLS
    Tcl_StaticPackage(interp, "Mtls",    Mtls_Init,    NULL);
#endif
#ifdef WITH_RTC
    Tcl_StaticPackage(interp, "Rtc", Rtc_Init, NULL);
#endif
#ifdef WITH_RTCMA
    Tcl_StaticPackage(interp, "Rtcma", Rtcma_Init, NULL);
#endif
#ifdef WITH_OMEMO
    Tcl_StaticPackage(interp, "Omemo", Omemo_Init, NULL);
#endif
#ifdef WITH_TCLWUFFS
    Tcl_StaticPackage(interp, "Tclwuffs", Tclwuffs_Init, NULL);
#endif
#ifdef WITH_TKWUFFS
    Tcl_StaticPackage(interp, "Tkwuffs", Tkwuffs_Init, NULL);
#endif
#ifdef WITH_TKDND
    Tcl_StaticPackage(interp, "Tkdnd", Tkdnd_Init, NULL);
#endif
#ifdef WITH_IMG_TKIMG
    Tcl_StaticPackage(interp, "Tkimg",       Tkimg_Init,       NULL);
#endif
#ifdef WITH_IMG_ZLIBTCL
    Tcl_StaticPackage(interp, "Zlibtcl",     Zlibtcl_Init,     NULL);
#endif
#ifdef WITH_IMG_PNGTCL
    Tcl_StaticPackage(interp, "Pngtcl",      Pngtcl_Init,      NULL);
#endif
#ifdef WITH_IMG_JPEGTCL
    Tcl_StaticPackage(interp, "Jpegtcl",     Jpegtcl_Init,     NULL);
#endif
#ifdef WITH_IMG_TIFFTCL
    Tcl_StaticPackage(interp, "Tifftcl",     Tifftcl_Init,     NULL);
#endif
#ifdef WITH_IMG_BMP
    Tcl_StaticPackage(interp, "Tkimgbmp",    Tkimgbmp_Init,    NULL);
#endif
#ifdef WITH_IMG_DTED
    Tcl_StaticPackage(interp, "Tkimgdted",   Tkimgdted_Init,   NULL);
#endif
#ifdef WITH_IMG_FLIR
    Tcl_StaticPackage(interp, "Tkimgflir",   Tkimgflir_Init,   NULL);
#endif
#ifdef WITH_IMG_GIF
    Tcl_StaticPackage(interp, "Tkimggif",    Tkimggif_Init,    NULL);
#endif
#ifdef WITH_IMG_ICO
    Tcl_StaticPackage(interp, "Tkimgico",    Tkimgico_Init,    NULL);
#endif
#ifdef WITH_IMG_JPEG
    Tcl_StaticPackage(interp, "Tkimgjpeg",   Tkimgjpeg_Init,   NULL);
#endif
#ifdef WITH_IMG_PCX
    Tcl_StaticPackage(interp, "Tkimgpcx",    Tkimgpcx_Init,    NULL);
#endif
#ifdef WITH_IMG_PIXMAP
    Tcl_StaticPackage(interp, "Tkimgpixmap", Tkimgpixmap_Init, NULL);
#endif
#ifdef WITH_IMG_PNG
    Tcl_StaticPackage(interp, "Tkimgpng",    Tkimgpng_Init,    NULL);
#endif
#ifdef WITH_IMG_PPM
    Tcl_StaticPackage(interp, "Tkimgppm",    Tkimgppm_Init,    NULL);
#endif
#ifdef WITH_IMG_PS
    Tcl_StaticPackage(interp, "Tkimgps",     Tkimgps_Init,     NULL);
#endif
#ifdef WITH_IMG_RAW
    Tcl_StaticPackage(interp, "Tkimgraw",    Tkimgraw_Init,    NULL);
#endif
#ifdef WITH_IMG_SGI
    Tcl_StaticPackage(interp, "Tkimgsgi",    Tkimgsgi_Init,    NULL);
#endif
#ifdef WITH_IMG_SUN
    Tcl_StaticPackage(interp, "Tkimgsun",    Tkimgsun_Init,    NULL);
#endif
#ifdef WITH_IMG_TGA
    Tcl_StaticPackage(interp, "Tkimgtga",    Tkimgtga_Init,    NULL);
#endif
#ifdef WITH_IMG_TIFF
    Tcl_StaticPackage(interp, "Tkimgtiff",   Tkimgtiff_Init,   NULL);
#endif
#ifdef WITH_IMG_WINDOW
    Tcl_StaticPackage(interp, "Tkimgwindow", Tkimgwindow_Init, NULL);
#endif
#ifdef WITH_IMG_XBM
    Tcl_StaticPackage(interp, "Tkimgxbm",    Tkimgxbm_Init,    NULL);
#endif
#ifdef WITH_IMG_XPM
    Tcl_StaticPackage(interp, "Tkimgxpm",    Tkimgxpm_Init,    NULL);
#endif
}

#endif /* ZIPPY_STATIC_PKGS_H */
