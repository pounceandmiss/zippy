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
#ifdef WITH_TK
    Tk_Main(argc, argv, AppInit);
#else
    Tcl_Main(argc, argv, AppInit);
#endif
    return 0;
}
