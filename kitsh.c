#include <tcl.h>
#ifdef WITH_TK
#  include <tk.h>
#endif

/* The static-package extern decls + Zippy_RegisterStaticPackages() live in a
 * shared header so a `lib`-target shim can register the exact same set. */
#include "static_pkgs.h"

static int AppInit(Tcl_Interp *interp) {
    if (Tcl_Init(interp) == TCL_ERROR) return TCL_ERROR;
#ifdef WITH_TK
    if (Tk_Init(interp) == TCL_ERROR) return TCL_ERROR;
#endif
    return TCL_OK;
}

/* Wide-char entrypoint on Windows, plain 8-bit main elsewhere; the aliases
 * keep the body shared. The Windows build must pass -municode — it provides
 * wmain and defines UNICODE, which tcl.h needs to expose the wide-argv
 * TclZipfs_AppHook/Tcl_MainExW signatures wmain expects. */
#ifdef _WIN32
#  define KITSH_CHAR wchar_t
#  define KITSH_MAIN wmain
#else
#  define KITSH_CHAR char
#  define KITSH_MAIN main
#endif

int KITSH_MAIN(int argc, KITSH_CHAR **argv) {
    /* Mounts the appended zip at //zipfs:/app and, if //zipfs:/app/main.tcl
     * exists, registers it as the startup script. Without this the launcher
     * falls through to Tk_Main's default REPL + empty toplevel. */
    TclZipfs_AppHook(&argc, &argv);

    /* NULL interp => register for every interpreter in the process. */
    Zippy_RegisterStaticPackages(NULL);
#ifdef WITH_TK
    Tk_Main(argc, argv, AppInit);
#else
    Tcl_Main(argc, argv, AppInit);
#endif
    return 0;
}
