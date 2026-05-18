#include <tcl.h>
#ifdef WITH_TK
#  include <tk.h>
#endif

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

static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) == TCL_ERROR) return TCL_ERROR;
#ifdef WITH_TK
    if (Tk_Init(interp) == TCL_ERROR) return TCL_ERROR;
#endif
    return TCL_OK;
}

int main(int argc, char **argv) {
    Tcl_StaticPackage(0, "Thread",  Thread_Init,  NULL);
    Tcl_StaticPackage(0, "Sqlite3", Sqlite3_Init, NULL);
#ifdef WITH_TDOM
    Tcl_StaticPackage(0, "tdom",    Tdom_Init,    NULL);
#endif
#ifdef WITH_MTLS
    Tcl_StaticPackage(0, "Mtls",    Mtls_Init,    NULL);
#endif
#ifdef WITH_RTC
    Tcl_StaticPackage(0, "Rtc", Rtc_Init, NULL);
#endif
#ifdef WITH_RTCMA
    Tcl_StaticPackage(0, "Rtcma", Rtcma_Init, NULL);
#endif
#ifdef WITH_IMG_TKIMG
    Tcl_StaticPackage(0, "Tkimg",       Tkimg_Init,       NULL);
#endif
#ifdef WITH_IMG_ZLIBTCL
    Tcl_StaticPackage(0, "Zlibtcl",     Zlibtcl_Init,     NULL);
#endif
#ifdef WITH_IMG_PNGTCL
    Tcl_StaticPackage(0, "Pngtcl",      Pngtcl_Init,      NULL);
#endif
#ifdef WITH_IMG_JPEGTCL
    Tcl_StaticPackage(0, "Jpegtcl",     Jpegtcl_Init,     NULL);
#endif
#ifdef WITH_IMG_TIFFTCL
    Tcl_StaticPackage(0, "Tifftcl",     Tifftcl_Init,     NULL);
#endif
#ifdef WITH_IMG_BMP
    Tcl_StaticPackage(0, "Tkimgbmp",    Tkimgbmp_Init,    NULL);
#endif
#ifdef WITH_IMG_DTED
    Tcl_StaticPackage(0, "Tkimgdted",   Tkimgdted_Init,   NULL);
#endif
#ifdef WITH_IMG_FLIR
    Tcl_StaticPackage(0, "Tkimgflir",   Tkimgflir_Init,   NULL);
#endif
#ifdef WITH_IMG_GIF
    Tcl_StaticPackage(0, "Tkimggif",    Tkimggif_Init,    NULL);
#endif
#ifdef WITH_IMG_ICO
    Tcl_StaticPackage(0, "Tkimgico",    Tkimgico_Init,    NULL);
#endif
#ifdef WITH_IMG_JPEG
    Tcl_StaticPackage(0, "Tkimgjpeg",   Tkimgjpeg_Init,   NULL);
#endif
#ifdef WITH_IMG_PCX
    Tcl_StaticPackage(0, "Tkimgpcx",    Tkimgpcx_Init,    NULL);
#endif
#ifdef WITH_IMG_PIXMAP
    Tcl_StaticPackage(0, "Tkimgpixmap", Tkimgpixmap_Init, NULL);
#endif
#ifdef WITH_IMG_PNG
    Tcl_StaticPackage(0, "Tkimgpng",    Tkimgpng_Init,    NULL);
#endif
#ifdef WITH_IMG_PPM
    Tcl_StaticPackage(0, "Tkimgppm",    Tkimgppm_Init,    NULL);
#endif
#ifdef WITH_IMG_PS
    Tcl_StaticPackage(0, "Tkimgps",     Tkimgps_Init,     NULL);
#endif
#ifdef WITH_IMG_RAW
    Tcl_StaticPackage(0, "Tkimgraw",    Tkimgraw_Init,    NULL);
#endif
#ifdef WITH_IMG_SGI
    Tcl_StaticPackage(0, "Tkimgsgi",    Tkimgsgi_Init,    NULL);
#endif
#ifdef WITH_IMG_SUN
    Tcl_StaticPackage(0, "Tkimgsun",    Tkimgsun_Init,    NULL);
#endif
#ifdef WITH_IMG_TGA
    Tcl_StaticPackage(0, "Tkimgtga",    Tkimgtga_Init,    NULL);
#endif
#ifdef WITH_IMG_TIFF
    Tcl_StaticPackage(0, "Tkimgtiff",   Tkimgtiff_Init,   NULL);
#endif
#ifdef WITH_IMG_WINDOW
    Tcl_StaticPackage(0, "Tkimgwindow", Tkimgwindow_Init, NULL);
#endif
#ifdef WITH_IMG_XBM
    Tcl_StaticPackage(0, "Tkimgxbm",    Tkimgxbm_Init,    NULL);
#endif
#ifdef WITH_IMG_XPM
    Tcl_StaticPackage(0, "Tkimgxpm",    Tkimgxpm_Init,    NULL);
#endif
#ifdef WITH_TK
    Tk_Main(argc, argv, AppInit);
#else
    Tcl_Main(argc, argv, AppInit);
#endif
    return 0;
}
