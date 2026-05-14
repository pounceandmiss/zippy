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
#ifdef WITH_IMG
extern int Tkimg_Init(Tcl_Interp *);
extern int Zlibtcl_Init(Tcl_Interp *);
extern int Pngtcl_Init(Tcl_Interp *);
extern int Jpegtcl_Init(Tcl_Interp *);
extern int Tifftcl_Init(Tcl_Interp *);
extern int Tkimgbmp_Init(Tcl_Interp *);
extern int Tkimgdted_Init(Tcl_Interp *);
extern int Tkimgflir_Init(Tcl_Interp *);
extern int Tkimggif_Init(Tcl_Interp *);
extern int Tkimgico_Init(Tcl_Interp *);
extern int Tkimgjpeg_Init(Tcl_Interp *);
extern int Tkimgpcx_Init(Tcl_Interp *);
extern int Tkimgpixmap_Init(Tcl_Interp *);
extern int Tkimgpng_Init(Tcl_Interp *);
extern int Tkimgppm_Init(Tcl_Interp *);
extern int Tkimgps_Init(Tcl_Interp *);
extern int Tkimgraw_Init(Tcl_Interp *);
extern int Tkimgsgi_Init(Tcl_Interp *);
extern int Tkimgsun_Init(Tcl_Interp *);
extern int Tkimgtga_Init(Tcl_Interp *);
extern int Tkimgtiff_Init(Tcl_Interp *);
extern int Tkimgwindow_Init(Tcl_Interp *);
extern int Tkimgxbm_Init(Tcl_Interp *);
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
#ifdef WITH_IMG
    Tcl_StaticPackage(0, "Tkimg",       Tkimg_Init,       NULL);
    Tcl_StaticPackage(0, "Zlibtcl",     Zlibtcl_Init,     NULL);
    Tcl_StaticPackage(0, "Pngtcl",      Pngtcl_Init,      NULL);
    Tcl_StaticPackage(0, "Jpegtcl",     Jpegtcl_Init,     NULL);
    Tcl_StaticPackage(0, "Tifftcl",     Tifftcl_Init,     NULL);
    Tcl_StaticPackage(0, "Tkimgbmp",    Tkimgbmp_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgdted",   Tkimgdted_Init,   NULL);
    Tcl_StaticPackage(0, "Tkimgflir",   Tkimgflir_Init,   NULL);
    Tcl_StaticPackage(0, "Tkimggif",    Tkimggif_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgico",    Tkimgico_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgjpeg",   Tkimgjpeg_Init,   NULL);
    Tcl_StaticPackage(0, "Tkimgpcx",    Tkimgpcx_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgpixmap", Tkimgpixmap_Init, NULL);
    Tcl_StaticPackage(0, "Tkimgpng",    Tkimgpng_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgppm",    Tkimgppm_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgps",     Tkimgps_Init,     NULL);
    Tcl_StaticPackage(0, "Tkimgraw",    Tkimgraw_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgsgi",    Tkimgsgi_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgsun",    Tkimgsun_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgtga",    Tkimgtga_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgtiff",   Tkimgtiff_Init,   NULL);
    Tcl_StaticPackage(0, "Tkimgwindow", Tkimgwindow_Init, NULL);
    Tcl_StaticPackage(0, "Tkimgxbm",    Tkimgxbm_Init,    NULL);
    Tcl_StaticPackage(0, "Tkimgxpm",    Tkimgxpm_Init,    NULL);
#endif
#ifdef WITH_TK
    Tk_Main(argc, argv, AppInit);
#else
    Tcl_Main(argc, argv, AppInit);
#endif
    return 0;
}
